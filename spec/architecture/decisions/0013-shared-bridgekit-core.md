# ADR-0013: Share code with EK Bridge in tiers, extracting BridgeKitCore now

**Status:** Accepted · 2026-10-16 · **Supersedes** [ADR-0008](0008-copy-then-extract-bridgekit.md) · **Amended by** [ADR-0018](0018-remote-access-in-v0.1.md) (tier 3 is extracted now, as `BridgeKitRemote` in 0.2.0)

**Progress (2026-10-17):** the Phase 0 quick check passed ([results](../../plans/spike-results.md#phase-0-quick-check-ek-bridges-swiftc-build-linking-a-swift-package)), so no fallback was needed. BridgeKit 0.1.0 is published (https://github.com/bereciartua/bridgekit, tag at 6fcf18e) with its tests and reference harness green. EK Bridge runs on it, on its branch `bridgekit-adoption`, with every existing test unchanged and green. Funes pins it exactly at 0.1.0. Still open: EK Bridge's live check and release.

**Context.**
- **What's shared:** Funes and EK Bridge share about 14K lines of Swift. Not all of it is equally settled:
  - **Protocol and security core (about 4–5K lines):** the loopback HTTP server, MCP protocol handling, keys and authentication, rate limiting, the launcher's listener check, safe file loading and agent config writing. This code is already stable, generic and security-critical.
  - **UI and workflow pieces (about 5–6K):** approvals, activity, agent setup screens and the app shell. Funes needs different things here: per-memory checkboxes with partial approval, different activity events, and an agent registry in SQLite.
  - **Remote Access and OAuth (about 4.3K):** not needed by Funes until v0.3. Its live cloud test matrix hasn't been run yet.
- **What ADR-0008 planned:** copying everything and extracting later. That would leave two copies of the security-critical core, so every hardening fix and MCP protocol change would have to be applied twice. Meanwhile MCP keeps moving (EK Bridge already handles four protocol versions), and a third "bridge" app is plausible.
- **Constraints:**
  - EK Bridge is shipped and stable, and it builds with plain `swiftc`, with no Swift package support.
  - Sparkle's update feed, Homebrew and the MCP Registry are each set up per repo.

**Decision.** Share code in three tiers:

| Tier | What | When | Where |
|---|---|---|---|
| **1: BridgeKitCore** | `HTTPMessage`, `LoopbackHTTPServer`, `MCPService`, `MCPEndpointFile`, `JSONRPC`, `MCPServer` (generic dispatch), JSON Schema validator, `RateLimiter`, key issue/digest/verify and key-file storage, safe file loading (owner, mode, `O_NOFOLLOW`, size), `MCPLauncher` + `SafePath` + `AppIdentity` (parameterized), `AgentConfigWriter`, `ExecutableLocator` | **Now** (Funes Phase 2) | New repo `bereciartua/bridgekit`, Swift package `BridgeKit`, product `BridgeKitCore` |
| **2: UI and workflow** | `ApprovalCenter`, `ApprovalPanel`, `AccessRequests`, `ActivityStore` + `ActivityView`, `AgentDetection`, `AgentSetup` + `ConnectAgentView`, `OneClickSetup`, updates (Sparkle wrapper), `AppMover`, `InstallLocation`, `Notifications`, `UIComponents`, menu and window skeletons | **Copy now** into Funes `Packages/BridgeUI`; extract as product `BridgeKitUI` **after Funes v0.1** | Funes repo for now; then `bridgekit` |
| **3: Remote** | `RemoteMCPService`, `OAuthServer`/`Store`/`Pages`/`Types`, `CIMDFetcher`, `TunnelHealth`/`Checks`/`Switch` | **Extract now, for Funes v0.1** (was v0.3; [ADR-0018](0018-remote-access-in-v0.1.md), [Phase 4b](../../plans/phase-4b-remote-access.md)). EK Bridge adopts it first | Product `BridgeKitRemote` |

**Rules for BridgeKit:**
1. **No domain types.** Nothing about calendars, reminders or memories. Apps plug in through small protocols: `BridgeOperation` (name, `isWrite`, `needsApproval`) and `BridgeHandler`. Policy stays in each app.
2. **Its own repo, a Swift package, semantic version tags.** Both apps pin an **exact** version.
   - Not a monorepo: Sparkle's `releases/latest/download/appcast.xml`, Homebrew casks and MCP Registry publishing are per repo.
3. **The tests move with the code.** EK Bridge's existing unit tests for these files move into BridgeKit. Its Python protocol and launcher harnesses run against a reference server in the BridgeKit repo.
4. **EK Bridge adopts it first, as the proof.** EK Bridge switches to BridgeKitCore with its golden tool fixtures, `mcp_test.py`, `launcher_test.py` and live matrix unchanged and green. Only then does Funes build on it.
5. **Changes are driven by the apps.** A change lands in BridgeKit only when an app needs it, with a test. Breaking changes bump the minor version while in 0.x.

**Consequences.**
- **Fixed once:** MCP protocol updates and security fixes to the core land in both apps with one change and two version bumps.
- **EK Bridge's build changes.** `build.sh` must build and link a Swift package, either with `swift build` for the `BridgeKitCore` product and the resulting module and object files passed to `swiftc`, or with a small Xcode project. That's about half a weekend, verified first in a Phase 0 quick check.
- **Phase 2 grows by about one weekend:** extraction plus EK Bridge's switch.
- **Tier 2 stays duplicated until after Funes v0.1.** That's accepted, because Funes's needs there are still changing. `Packages/BridgeUI/PROVENANCE.md` records the EK Bridge commit of every copied file.
- **Two repos to release in order:** BridgeKit, then the app.

**Alternatives considered.**
- **Copy everything, extract later (ADR-0008):** duplicates the security-critical core during the riskiest period.
- **Extract everything now:** guesses the shared design for UI pieces that Funes hasn't shaped yet, and puts more risk on EK Bridge.
- **A monorepo with both apps:** breaks the per-repo release mechanics (Sparkle's latest-release feed, Homebrew, MCP Registry).
- **A git submodule or subtree compiled into each app's own module:** avoids package tooling, but loses the module boundary and versioning discipline.
