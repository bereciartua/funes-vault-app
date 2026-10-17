# ADR-0017: Funes's MCP adapter is a local package, FunesMCP

**Status:** Accepted · 2026-10-17

**Context.**
- The [overview](../overview.md) put the MCP adapter (tool contract, `RequestPipeline`, tool handlers) in the app target, on top of BridgeKitCore and next to the BridgeUI panels.
- Phase 2 needs a `FUNES_MCP_TEST` server with a temporary vault and a fake approval responder, which the Python harness drives in CI ([task 2.11](../../plans/phase-2-bridgekit-and-mcp.md)). Built from the app target, that would need a second app configuration, Xcode and a GUI-capable build in CI.
- FunesCore may not contain MCP code (AGENTS.md, ADR-0006).

**Decision.**
- A local Swift package, **`Packages/FunesMCP`**, holds everything about MCP that isn't UI:
  - the tool contract (`Sources/FunesMCP/Resources/mcp-tools.json`) and `FunesTools` (visibility);
  - Funes's `BridgeConfiguration` (port, key prefix, limits, wording) and the launcher's values;
  - `FunesAuthenticator`, `RequestPipeline` and the five handlers;
  - the key files (`AgentKeyFileStore`) and BridgeKitCore's key issuer for `AgentService`;
  - `FunesMCPServer`, which wires them to BridgeKitCore's listener and endpoint file;
  - the executable **`funes-mcp-test-server`** (the `FUNES_MCP_TEST` build).
- It depends on FunesCore, FunesProtocol and BridgeKit, and has no AppKit or SwiftUI. The app reaches the user through one protocol, `FunesPresenter` (show the Share panel, show the Save panel, open an item), implemented with BridgeUI panels.
- The launcher target (`Apps/FunesMCPLauncher`) links BridgeKitCore only, not FunesMCP, so it carries no vault code.

**Consequences.**
- `swift test` and `swift build` cover the whole MCP path; CI runs the Python harness without Xcode or a GUI.
- The app target stays thin: wiring, panels and lifecycle.
- One more package in the project. Accepted.

**Alternatives considered.**
- **MCP code in the app target** (the overview's first layout): the harness would need an app build per CI run.
- **MCP code in FunesCore:** breaks FunesCore's "no MCP" rule and drags BridgeKit into the iPhone's dependency graph through FunesProtocol consumers later.
