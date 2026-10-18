# Reusing EK Bridge

*Based on reading `bereciartua/ek-bridge` v0.11.1 (build 18): about 40.9K lines of Swift in `Sources/` and 16.5K in `Tests/`.*

**Strategy:** share code in **three tiers** ([ADR-0013](decisions/0013-shared-bridgekit-core.md), which supersedes ADR-0008):
1. **Extract the protocol and security core now** into a shared library, `bereciartua/bridgekit` (product `BridgeKitCore`). EK Bridge adopts it first.
2. **Copy the UI and workflow pieces** into Funes (`Packages/BridgeUI`) and extract them after Funes v0.1.
3. **Extract Remote Access now** as a second product, `BridgeKitRemote` (BridgeKit 0.2.0), for Funes v0.1. EK Bridge adopts it first ([ADR-0018](decisions/0018-remote-access-in-v0.1.md)).

## 1. Tier 1: BridgeKitCore (shared library, extracted in Funes Phase 2)
| Area | EK Bridge files | ~Lines | Generalization needed |
|---|---|---|---|
| HTTP | `MCP/HTTPMessage`, `MCP/LoopbackHTTPServer`, `MCP/MCPService`, `MCP/MCPEndpointFile` | 900 | Port, endpoint-file path and limits come from a `BridgeConfiguration` |
| MCP protocol | `MCP/JSONRPC`, `MCP/MCPServer` (dispatch, protocol versions, `server/discover`, Host and Origin checks), the JSON Schema validator from `MCP/MCPToolCatalog` | 1,000 | Tools come from an injected `ToolRegistry` (the contract JSON plus `BridgeHandler`s) instead of `BridgeCommand` |
| Limits | `MCP/RateLimiter` | 200 | Limits are configured per app |
| Keys and auth | Key issue, digest and constant-time verify from `ClientRegistry`; `ClientCredentialFiles` (key-file write, 0600 and 0700) | 450 | Key prefix (`ekb_mcp_v1_` / `fns_mcp_v1_`) and folder are parameters. Where agents are stored stays in each app (JSON for EK Bridge, SQLite for Funes) |
| Safe file loading | The owner, mode, `O_NOFOLLOW` and size checks plus the atomic-write helpers used by `ClientRegistry`, `ActivityStore` and the other stores | 250 | None, beyond moving it |
| Launcher | `MCPLauncher`, `SafePath`, `AppIdentity` | 1,260 | Bundle ID, support folder, endpoint file, key folder, server key and launcher name come from configuration. The executable target stays in each app, as a thin `main.swift` calling `BridgeLauncher.run(config)` |
| Agent config writing | `AgentConfigWriter` (JSON text insertion with verification, TOML append, backup, atomic write), `ExecutableLocator` | 700 | Backup suffix and server key are parameters |

**Total:** about 4.5–5K lines.

**The seam between BridgeKitCore and the apps** (as built in BridgeKit 0.1.0):
```swift
public struct BridgeConfiguration: Sendable {
    public var identity: BridgeIdentity          // display name, bundle ID, data folder, version
    public var mcpPort: Int                      // 47615 EK Bridge · 47625 Funes
    public var keyPrefix: String                 // "ekb_mcp_v1_" · "fns_mcp_v1_"
    public var serverKey: String                 // "ek-bridge" · "funes"
    public var launcherName: String              // "bridge-mcp" · "funes-mcp"
    public var serverDescription, agentMetaKey: String
    public var limits: RateLimiter.Policy
    public var http: HTTPLimits; public var maxConnections: Int; public var toolCallTimeout: TimeInterval
    public var allowedOrigins: Set<String>; public var forwardedHeaders, forwardedHeaderPrefixes: [String]
    public var stringLength: JSONSchemaValidator.StringLength   // UTF-8 bytes (EK Bridge) · Unicode scalars (Funes)
    public var texts: BridgeTexts                // 401, 403 and 503 wording in the app's terms
}
public protocol BridgeOperation: Sendable { var name: String { get }; var isWrite: Bool { get }; var needsApproval: Bool { get } }
public protocol AgentAuthenticator: Sendable {   // app-owned storage, core-owned crypto
    func authenticate(_ key: PresentedKey) async -> AuthenticationOutcome   // .authenticated(agent) · .rejected · .unavailable
}
@MainActor public protocol ToolRegistry: AnyObject {   // the app's contract and visibility
    var serverInstructions: String { get }
    func tool(named: String) -> ToolDefinition?
    func visibleTools(for agent: AuthenticatedAgent) -> [ToolDefinition]
    func failureResult(_ failure: ToolFailure, tool: String, arguments: [String: Any]?) -> ToolResult
}
public protocol BridgeHandler: Sendable {
    func handle(_ call: ToolCall) async -> ToolResult   // call.context: cancellation, the app's timeout answer
}
```
- The core validates arguments against the contract (`ToolContract`, `JSONSchemaValidator`) before the handler runs, and answers a timeout itself after `toolCallTimeout`, without cancelling the call.
- The app's `RequestPipeline` (which handles pause, approvals, policy and activity) is its `BridgeHandler`.
- BridgeKitCore never sees a calendar or a memory.
- The launcher takes a `LauncherConfiguration` (names, key folder and suffix, the `--agent`/`--client` option, the probe tool for `check`, wording, a test mode), and each app's launcher target is a `main.swift` calling `BridgeLauncher.run(_:)`.

## 2. Tier 2: copied into Funes `Packages/BridgeUI` (extracted as `BridgeKitUI` after Funes v0.1)
| Area | EK Bridge files | ~Lines | Funes changes |
|---|---|---|---|
| Approvals | `ApprovalCenter`, `AccessRequests`, `ApprovalPanel` | 780 | A generic panel view model (title, rows with optional checkboxes, badges); "Share N" subset selection; the Save panel is non-blocking |
| Activity | `ActivityStore` (generic `ItemRef`), `ActivityView` via an adapter | 1,000 | New event kinds; retention of 400 days / 20K rows for important rows |
| Agent setup UI | `AgentDetection`, `AgentSetup`, `ConnectAgentView`, `OneClickSetup` | 2,350 | Funes snippets and goldens; uses BridgeKitCore's `AgentConfigWriter` |
| App shell | `Updates`, `SparkleUpdater`, `AppMover`, `InstallLocation`, `Notifications`, `UIComponents`, `StatusMenuController` and `MainWindowController` skeletons | 1,500 | Funes branding; the update relaunch gate also waits for pending disclosures |

**Total:** about 5.5–6K lines (5,843 at EK Bridge 9c726f2).
- `Packages/BridgeUI/Upstream/` keeps the copies unchanged; `Packages/BridgeUI/Sources/BridgeUI/` holds the adapted ones, adapted as each phase needs them (Phase 2: the approval queue and panel, and the Activity store).
- `Packages/BridgeUI/PROVENANCE.md` lists the EK Bridge commit for every copied file. Diff it against EK Bridge before each Funes release.
- After Funes v0.1, the common shape of both apps' versions becomes `BridgeKitUI`.

## 3. Tier 3: BridgeKitRemote (extracted now, for Funes v0.1)
*Amended by [ADR-0018](decisions/0018-remote-access-in-v0.1.md): this tier was to stay in EK Bridge until Funes v0.3. Line counts at EK Bridge `e753b22` (0.11.2 plus BridgeKit 0.1.1). Plan: [Phase 4b](../plans/phase-4b-remote-access.md).*

| Area | EK Bridge files | ~Lines | Generalization needed |
|---|---|---|---|
| Remote listener | `MCP/RemoteMCPService` (`RemoteConfiguration`, `RemoteHTTPGate`, `RemoteNonces`, the service) | 440 | Authenticates through a new `RemoteAuthenticator` protocol instead of `ClientRegistry`, and returns an agent id for BridgeKitCore's `MCPAuthentication(remote: true)`. The 401 wording comes from the app's texts |
| OAuth | `MCP/OAuthServer`, `OAuthStore`, `OAuthPages`, `OAuthTypes` | 1,360 | The scope (`calendar` → `memory`), the token prefixes (`ekb_oat_v1_`, `ekb_ort_v1_`, `ekb_ocs_v1_` → `fns_…`), the display name on the sign-in pages, and the store's folder are parameters. A connection's `clientID` is the app's agent id. The store stays a 0600 JSON file (`remote-connections.json`) that fails closed |
| Client metadata | `MCP/CIMDFetcher` | 580 | The `User-Agent` name and version come from `BridgeIdentity` |
| Tunnels | `TunnelHealth`, `TunnelChecks`, `TunnelSwitch` | 910 | The port is a parameter; the status lines become typed results that the app words (as `BridgeTexts` does for BridgeKitCore), because the kit has no String Catalog |
| Support | `RemoteAccessSupport` (`KeepAwake`, `RemoteProbe`) | 100 | The assertion's reason text is a parameter |

**Total:** about 3,400 lines. EK Bridge's tests for them move too: `OAuthServerTests`, `CIMDFetcherTests`, `TunnelHealthTests` with the `Tests/tunnel-health` fixtures, `TunnelSwitchTests`, the remote checks of `MCPGateTests`, and `mcp_test.py`'s `run_remote` and `run_oauth`, generalized to run against the reference server.

**Already in BridgeKitCore 0.1.x**, so tier 3 sits on top of it: `MCPAuthentication(remote:)`, `ToolCall.remote` and `MCPServer.Connection.remote`, and `RateLimiter`'s remote buckets and per-address failed-auth lockout. Funes's pipeline counts a remote call in the agent's own buckets, shared by both listeners, and also in the stricter remote buckets, as EK Bridge does, as network hygiene ([ADR-0018](decisions/0018-remote-access-in-v0.1.md) decision 2). The remote buckets and the per-address lockout are the only remote-specific limits.

**Stays app-side:**
- **The views,** `RemoteAccessView` and `TunnelSwitchView` (about 1,300 lines), and the cloud sections of `AgentSetup` (cloud agent setups, tunnel commands, goldens `Tests/agent-setup/cloud-*.txt` and `tunnel-*.txt`). They're bound to each app's model (EK Bridge's `BridgeAppModel` and connections; Funes's agents) and its String Catalog. Funes copies them into `Packages/BridgeUI` (`Upstream/` and `PROVENANCE.md`, as for tier 2), and they become part of BridgeKitUI after v0.1.
- **Which agent a credential belongs to,** where the remote-token digest is stored (EK Bridge's JSON registry, Funes's SQLite), and the "Allow cloud access" switch. Policy stays in each app (rule 1).

**Funes v0.2's public-tunnel mode for the iPhone** uses BridgeKitRemote's gate pieces (secret path, `Host` check) and tunnel checks, instead of copying them into the companion server.

## 4. Scripts and CI (copied as files in both repos, not shared code)
- `release.sh`, `scripts/make_dmg.sh`, `scripts/dmg_window.swift`, `scripts/appcast.py`, `scripts/release_notes.py`, `scripts/verify_update_signature.swift`, `scripts/sparkle.sh`, and workflows `ci.yml`, `release.yml` and `mcp-registry.yml`. About 2,200 lines.
- Funes switches from `swiftc` to `xcodebuild archive`/`-exportArchive`. Keep the notarize → staple → DMG → zip → sign → appcast → draft-release sequence.

## 5. Stays EventKit-specific (never shared)
- The tool catalog and mapping (`MCPToolCatalog` JSON, `MCPToolMapping`).
- `EventKitCommands`, `EventCommands`, `ReminderCommands`, the field types, `Recurrence*`, `ItemAlarms`, `ReminderDue` and others.
- `CommandPolicy`, `MutationPolicy`, `ApprovalSummaries`, `CollectionLabels`, `WriteJournal`.
- `BridgeProtocol`, `LocalBridge`, `BridgeClient` (the signed `/tmp` CLI transport). It could become a BridgeKit tier later if Funes gets a CLI.
- Synthetic and live-test scaffolding.

## 6. The BridgeKit repository
```
bridgekit/
├── Package.swift                 # products: BridgeKitCore, BridgeKitRemote (0.2.0); later BridgeKitUI
├── Sources/BridgeKitCore/
├── Sources/BridgeKitRemote/       # depends on BridgeKitCore; no UI
├── Tests/BridgeKitCoreTests/     # Swift Testing; moved from EK Bridge's test executables
├── Tests/BridgeKitRemoteTests/   # 0.2.0: OAuth, CIMD, tunnel parsers, remote gate
├── Tests/harness/                # reference server + mcp_test.py / launcher_test.py (moved from EK Bridge)
├── PROVENANCE.md                 # EK Bridge commit each file came from
├── CHANGELOG.md
└── LICENSE                       # Apache-2.0
```
- **Platforms:** macOS 14+ (EK Bridge's minimum). No dependencies.
- **Versions:** `0.1.0` is the first tag. Both apps pin an exact version (`.exact("0.1.0")`). `0.2.0` adds the `BridgeKitRemote` product; BridgeKitCore only gains additions in it (most of what tier 3 uses is already public).
- **Release order:** change BridgeKit, then tag it, then bump EK Bridge (its tests and fixtures must stay byte-for-byte green), then bump Funes.

## 7. EK Bridge's adoption (the proof step)
1. **Build:** `scripts/bridgekit.sh` runs `swift build -c release --product BridgeKitCore --arch …` once for all the app's architectures (a universal static library), and `build.sh` passes the module path (`-I`) and `-L … -lBridgeKitCore` to the existing `swiftc` calls for the app, `bridge-mcp` and `bridge-client`. Verified first in a [Phase 0 quick check](../plans/phase-0-spikes.md#also-verify-in-phase-0-quick-checks-under-1-hour-each), [passed](../plans/spike-results.md#phase-0-quick-check-ek-bridges-swiftc-build-linking-a-swift-package).
2. **Code:**
   - Delete the moved files from EK Bridge; one file re-exports `BridgeKitCore` (`@_exported import`), so the rest of EK Bridge, and its tests, compile unchanged.
   - Wrap EK Bridge's `RequestPipeline` in `BridgeHandler`, and `MCPToolCatalog` and `MCPToolMapping` in `ToolRegistry` (`Sources/MCP/MCPAdapters.swift`).
   - Keep `ClientRegistry`'s JSON storage, now behind `AgentAuthenticator`; `ClientCredentialFiles` and `AgentConfigWriter` keep their API over BridgeKitCore's.
3. **Proof:** EK Bridge's tool fixture, `mcp_test.py`, `launcher_test.py`, `cli_test.py`, the UI test scripts and a live check with Claude Code must all pass, unchanged.
4. **Ship:** EK Bridge releases a patch version (for example 0.11.2 or 0.12.0) on BridgeKit with no user-visible change. Its CHANGELOG says "internal: uses BridgeKit".
