# Phase 2: BridgeKit and the MCP server

**Goal:**
- Extract the shared protocol and security core into **BridgeKitCore**, with EK Bridge adopting it first as the proof.
- Then connect agents to the real Funes vault over MCP, with keys, limits and the first approval panels.

**Duration:** 3 weekends (one more than before, for the extraction; see [ADR-0013](../architecture/decisions/0013-shared-bridgekit-core.md)). **Depends on:** Phase 1, and the Phase 0 quick check that EK Bridge's `swiftc` build can link a Swift package.

## Part A: BridgeKitCore (weekend 1)

### 2.1 Create the BridgeKit repo · 1 h
- [ ] `bereciartua/bridgekit`, Apache-2.0, `Package.swift` with product `BridgeKitCore`, macOS 14+, no dependencies.
- [ ] CI: `swift test` on macOS, and the reference harness (2.4).

### 2.2 Move the tier-1 code · 4 h
- [ ] Move the files listed in [EK Bridge reuse §1](../architecture/ek-bridge-reuse.md#1-tier-1-bridgekitcore-shared-library-extracted-in-funes-phase-2) and record their source commit in `PROVENANCE.md`.
- [ ] Introduce `BridgeConfiguration`, `BridgeOperation`, `AgentAuthenticator`, `BridgeHandler` and `ToolRegistry`.
- [ ] Remove every reference to `BridgeCommand`, EventKit and `ekb_` constants.
- [ ] Make public only what the apps need. Keep everything else internal.

### 2.3 Move the tests · 2 h
- [ ] Convert EK Bridge's `@main` test executables for these files to Swift Testing in `Tests/BridgeKitCoreTests` (HTTP parsing, JSON-RPC, schema validator, rate limiter, key digest and verify, safe file loading, config writer, launcher listener verification).

### 2.4 Reference harness · 1 h
- [ ] A tiny reference server in `Tests/harness` (an echo tool plus a write tool) built on BridgeKitCore. Run EK Bridge's `mcp_test.py` and `launcher_test.py`, generalized, against it.
- [ ] Tag **`0.1.0`**.

## Part B: EK Bridge adopts BridgeKitCore (weekend 2, first half)

### 2.5 Switch EK Bridge · 4 h
- [ ] `build.sh`: build `BridgeKitCore` (universal) and link it into the app and `bridge-mcp` ([reuse §7](../architecture/ek-bridge-reuse.md#7-ek-bridges-adoption-the-proof-step)).
- [ ] Delete the moved sources and `import BridgeKitCore`. Adapt `ClientRegistry` behind `AgentAuthenticator` and the pipeline behind `BridgeHandler`.
- [ ] **Proof:** these must all pass, unchanged:
  - the golden `tools.json`;
  - `mcp_test.py`, `launcher_test.py`, `cli_test.py`;
  - `ui_test.sh`;
  - a live Claude Code check.
- [ ] Release EK Bridge as a patch version ("internal: uses BridgeKit"). Users see no change.

## Part C: Funes MCP (weekend 2, second half, and weekend 3)

### 2.6 Funes packages and copies · 2 h
- [ ] Add `BridgeKit` as a package dependency, pinned exactly to `0.1.0`. *(By local path, `../bridgekit`, until the repository and tag are published.)*
- [x] Create `Packages/BridgeUI` and copy the tier-2 files ([reuse §2](../architecture/ek-bridge-reuse.md#2-tier-2-copied-into-funes-packagesbridgeui-extracted-as-bridgekitui-after-funes-v01)), recording their source commits in `PROVENANCE.md`.

### 2.7 Tool contract · 2 h
*The contract, pipeline, handlers and the `FUNES_MCP_TEST` server live in `Packages/FunesMCP` ([ADR-0017](../architecture/decisions/0017-funes-mcp-package.md)); the contract is `Packages/FunesMCP/Sources/FunesMCP/Resources/mcp-tools.json`.*
- [x] `Resources/mcp-tools.json`: server instructions, the 5 tools, schemas, annotations ([MCP spec](../architecture/mcp-server.md#6-tools)), including the optional `keywords` on `request_memory` and the description asking for them ([ADR-0016](../architecture/decisions/0016-bundled-bge-small-embeddings.md)).
- [ ] Live check: record whether Claude Code, Claude Desktop, Cursor and Codex send `keywords`, and sample what they send; tune the description from that.
- [x] Golden fixture and a byte-for-byte test. Implement `visibleTools(access:)`.

### 2.8 Handlers and pipeline · 5 h
- [x] `BridgeConfiguration` for Funes: port 47625, prefix `fns_mcp_v1_`, server key `funes`, launcher `funes-mcp`.
- [x] `AgentAuthenticator` backed by `AgentService` (SQLite).
- [x] `RequestPipeline`: Funes on? → agent state → rate limits (calls, writes, in-flight, pending) → handler → Activity.
- [x] Handlers: `request_memory` (with the 45 s approval wait), `get_memory_request`, `suggest_memory` (non-blocking Save panel), `list_memory_categories`, `open_in_funes`.
- [x] `mcp-endpoint.json` lifecycle.

### 2.9 Approval panels v1 · 3 h
- [x] Adapt the copied `ApprovalPanel`:
  - **Share with…** (checkbox rows, sensitivity badges, task, purpose "as reported", retention, withheld line, countdown);
  - **Save this memory?**.
- [x] Arming delay, queue limits, VoiceOver announcement.

### 2.10 Launcher · 0.5 h
- [x] `FunesMCPLauncher` target: a `main.swift` calling `BridgeLauncher.run(funesConfig)`, supporting `--agent`, `headers` and `check`.

### 2.11 Python MCP harness for Funes · 2 h
- [x] A `FUNES_MCP_TEST` build with a temporary vault and a fake approval responder.
- [x] `Tests/mcp/mcp_test.py`: Funes tool paths. The generic protocol checks live in BridgeKit's harness.

## Exit criteria
- **BridgeKit `0.1.0`** is tagged, with tests and the reference harness green.
- **EK Bridge** is released on BridgeKitCore with all its existing tests, fixtures and its live check unchanged and green.
- **Claude Code connects to Funes via `funes-mcp`** and can:
  - list categories;
  - request memory (panel approve, panel deny, timeout then get);
  - suggest a memory into the Inbox.
- **Funes's golden tool fixture and Python harness** are green in CI.

## If extraction runs long
- The fallback is to copy tier 1 into Funes as well, as in ADR-0008, and finish the extraction after Funes v0.1.
- The time box: if EK Bridge's switch isn't green after **2 extra evenings**, take the fallback. Record that in `spike-results.md` and in ADR-0013's status.
