# Architecture overview

## System context

```mermaid
flowchart LR
    subgraph Mac["User's Mac"]
        Agents["AI agents<br/>Claude Code · Claude Desktop · Cursor · Codex · …"]
        Launcher["funes-mcp<br/>(stdio launcher)"]
        App["FunesVault.app<br/>menu bar app"]
        DB[("Vault<br/>SQLite + FTS5<br/>+ embeddings")]
        KeyFiles["Agent key files<br/>0600"]
        Act["Activity log<br/>JSONL"]
    end
    subgraph Phone["User's iPhone"]
        iOS["Funes Vault for iPhone"]
        Ext["Share extension<br/>App Intent · Control"]
        Q[("Capture queue")]
    end
    Agents -- "stdio (MCP)" --> Launcher
    Agents -- "HTTP 127.0.0.1:47625/mcp" --> App
    Launcher -- "HTTP loopback" --> App
    Launcher -. reads .-> KeyFiles
    App --> DB
    App --> Act
    Ext --> Q
    iOS --> Q
    iOS -- "Companion API :47626<br/>signed + HPKE-encrypted<br/>LAN · Tailscale · tunnel" --> App
    App -. "Sparkle update check" .-> GitHub[(GitHub Releases)]
    App -. "optional, user-chosen: classification (other embedding models later)<br/>(guardrails: secret scan, cloud sensitivity limit)" .-> Providers[(AI model providers<br/>local server or cloud)]
```

**Trust boundaries:**
- **Agents** are untrusted parties with scoped access. Their keys separate them from each other.
- **The iPhone** is trusted as the owner once paired, but every message is authenticated and encrypted.
- **AI model providers** the user chose (local servers or cloud) receive only what the guardrails allow ([model providers §5](model-providers.md#5-guardrails-all-non-local-providers)). By default there are none: Apple's on-device models.
- **Everything else** on the network is untrusted.
- **Other software running as the user** is out of scope (see [security](security-and-privacy.md)).

## Components

### FunesVault.app (macOS, one process)
| Layer | Contents | Origin |
|---|---|---|
| **UI** (SwiftUI in AppKit) | Menu bar controller, main window (Vault, Inbox, Agents, Activity, iPhone, Settings), capture box, panels | New, with EK Bridge shells |
| **App services** | `RequestPipeline` (gate → rate limit → handler → approvals → activity), `ApprovalCenter`, `AccessRequests`, `ActivityStore`, `AgentSetup`/`AgentConfigWriter`, `Updater` (Sparkle), `AppMover`, `LoginItem`, `HotKey`, `ServicesProvider`, `Notifications` | **BridgeUI** (copied from EK Bridge) on top of **BridgeKitCore** |
| **MCP adapter** | `LoopbackHTTPServer`, `MCPServer` (JSON-RPC, protocol versions) from **BridgeKitCore**; the tool contract, `RequestPipeline` and handlers in **FunesMCP** ([ADR-0017](decisions/0017-funes-mcp-package.md)) | **BridgeKitCore** (shared library) + **FunesMCP** (package) |
| **Companion adapter** (v0.2) | `CompanionServer` (HTTP listener on 47626), `PairingService`, `DeviceRegistry`, `EnvelopeCrypto` (HPKE + P-256 signatures), `BonjourAdvertiser` | New, with BridgeKitCore HTTP parts |
| **FunesCore** (package) | `VaultStore` (GRDB), `PolicyEngine`, `Retrieval`, `BundleCompiler`, `DisclosureService`, `SuggestionService`, `CaptureService`, `ImportExport`, `Embeddings` (bundled bge-small Core ML, WordPiece tokenizer, vector index), `Classifier`, `Provenance`, **`Models`** (`ModelRouter`, Apple, OpenAI-compatible and Anthropic providers; see [model providers](model-providers.md)) | New, porting the web version's rules |
| **FunesProtocol** (package, shared with iOS) | Companion request and response types, envelope format, `SecretScanner`, input limits, enums | New |

### funes-mcp (launcher, inside `FunesVault.app/Contents/MacOS/`)
- Relays stdio JSON-RPC lines to `POST http://127.0.0.1:<port>/mcp`.
- Reads the agent's key from `~/Library/Application Support/FunesVault/agent-keys/<agentId>.key`.
- Before sending the key, it verifies that the listener in `mcp-endpoint.json`:
  - belongs to the same user;
  - comes from a process with Funes's bundle ID;
  - holds the socket.

  This uses `libproc`, as in EK Bridge's `MCPLauncher`.
- Has `headers` and `check` subcommands (Claude Code's `headersHelper` and a self-test).

### Funes Vault for iPhone
| Part | Contents |
|---|---|
| **App** (SwiftUI) | Capture, Search, Inbox, Settings, Pairing (VisionKit scanner), Demo vault |
| **CompanionClient** | Discovery (Bonjour `NWBrowser`, saved Tailscale address and tunnel URL), envelope crypto, request retries, `NWPathMonitor` |
| **CaptureQueue** | SQLite or file store in the App Group container, shared with the extensions |
| **Share extension, App Intent, Control** | Append to `CaptureQueue` only. No networking in extensions |
| **FunesProtocol** | Shared package |

## Concurrency model (Mac)
- **Main actor:** UI, `ApprovalCenter`, panels and `RequestPipeline` decisions that touch approvals. This mirrors EK Bridge, where requests hop from the listener queue to the main actor.
- **Network queues:** each listener (`mcp.http`, `companion.http`) parses on its own queue, then hops to the main actor for the pipeline. Bodies are limited to 64 KiB for MCP and 256 KiB for the companion API.
- **`VaultStore`:** a GRDB `DatabasePool` (WAL), so reads run concurrently and writes are serialized. Disclosure, suggestion-apply and import flows each run in one `write { }` transaction.
- **Background work** (Swift concurrency `Task` with low priority): embedding updates, classification, activity compaction, purging deleted memories, backups and suggestion expiry. Each is idempotent and cancellable.
- **Timeouts:**
  - MCP call: 55 s overall;
  - approval panel: 45 s;
  - pending approvals: 15 min;
  - the iPhone uses a 10 s request timeout.

## Key flows

### Request with approval
```mermaid
sequenceDiagram
    participant A as Agent
    participant L as funes-mcp
    participant S as MCP server
    participant P as RequestPipeline
    participant C as FunesCore
    participant U as Approval panel
    A->>L: tools/call request_memory {task, purpose,…}
    L->>S: POST /mcp (Bearer key)
    S->>P: authenticated agent + call
    P->>P: Funes paused? rate limit?
    P->>C: evaluate(agent, request)
    C->>C: gate → retrieval → eligibility → decision
    C-->>P: NEEDS_APPROVAL (snapshot persisted)
    P->>U: show panel (fresh text from vault)
    alt user shares subset within 45 s
        U-->>P: approve(revision, ids)
        P->>C: deliver(requestId) in one transaction
        C-->>P: bundle
        P-->>A: {status: delivered, items, instructions}
    else timeout
        P-->>A: {status: needs_approval, request_id}
        Note over U: moves to Pending requests (≤15 min)
        A->>S: later: get_memory_request {request_id}
        S->>C: deliver if approved & still valid
    end
    P->>P: Activity rows (ids only)
```

### Suggestion
```mermaid
sequenceDiagram
    participant A as Agent
    participant P as RequestPipeline
    participant C as FunesCore
    participant U as Save panel
    A->>P: suggest_memory {title, body, categories,…}
    P->>C: validate + secret scan + gate + scope check
    alt write & ask-before-saving off
        C-->>P: memory created
        P-->>A: {status: saved, memory_id}
    else suggest
        C-->>P: suggestion created
        P-->>A: {status: queued, suggestion_id}
        P->>U: Save this memory? (non-blocking)
    end
```

### iPhone capture delivery
```mermaid
sequenceDiagram
    participant Ph as iPhone app
    participant Q as Capture queue
    participant M as Companion server (Mac)
    participant C as FunesCore
    Ph->>Q: append {captureId, text, createdAt}
    Ph->>Ph: path change / app open / BG refresh
    Ph->>M: POST /c/v1/captures (signed, HPKE-sealed batch)
    M->>M: verify device, signature, replay window, decrypt
    M->>C: for each capture: receipt exists? → skip : create suggestion + receipt (1 txn)
    M-->>Ph: {accepted: [captureId…]} (sealed to device)
    Ph->>Q: delete accepted
```

## Lifecycle
- **Launch:**
  1. Open the database, running migrations with a backup first.
  2. Load agents and devices.
  3. Start the MCP listener if enabled, and write `mcp-endpoint.json`.
  4. Start the companion listener and Bonjour if iPhone access is on.
  5. Schedule background maintenance.
- **Sleep and wake:** listeners survive sleep. On wake, the app re-advertises Bonjour and expires pending approvals whose 15 minutes have passed.
- **Quit:** answer calls in progress (a call waiting for the user gets `denied`, `funes_quit`, and its request stays pending), withdraw open panels, then stop the listeners and remove `mcp-endpoint.json`.
- **Update:** Sparkle's relaunch waits while panels or pending approvals exist (EK Bridge's `UpdateRelaunchGate`).

## Repository layout (proposed)
```
funes-vault-app/
├── FunesVault.xcodeproj
├── Apps/
│   ├── FunesMac/            # app target (AppKit + SwiftUI), Info.plist, entitlements
│   ├── FunesMCPLauncher/    # funes-mcp command-line target
│   ├── FunesiOS/            # iPhone app target
│   ├── FunesShareExtension/
│   └── FunesIntents/        # App Intents / Control extension
├── Packages/                # each package keeps its own Tests/ (SwiftPM needs them inside the package)
│   ├── FunesCore/           # vault logic (Mac only); Tests/FunesCoreTests: policy vectors, store, search
│   ├── FunesProtocol/       # shared Mac + iOS; Tests/FunesProtocolTests
│   ├── FunesMCP/            # MCP contract, pipeline, handlers, FUNES_MCP_TEST server (ADR-0017)
│   └── BridgeUI/            # UI pieces copied from EK Bridge (→ BridgeKitUI after v0.1)
│   (BridgeKit/BridgeKitCore is an external package: github.com/bereciartua/bridgekit)
├── Resources/               # icons, seed data
├── Tests/                   # cross-cutting harnesses outside SwiftPM
│   ├── mcp/                 # Python loopback harness + golden fixtures
│   └── companion/           # protocol tests, fuzzing
├── scripts/                 # release.sh, make_dmg.sh, appcast.py, … (from EK Bridge)
├── docs/                    # ARCHITECTURE, MCP, COMPANION, TESTING, MAINTAINING, SECURITY
└── server.json              # MCP Registry
```
See [project setup](../plans/project-setup.md) for targets, bundle IDs and signing.
