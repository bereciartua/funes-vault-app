# Plans

| Document | What it covers |
|---|---|
| [Phase 0: Spikes](phase-0-spikes.md) | Three risky questions answered with throwaway code: companion transport, search quality, agent approval wait |
| [Phase 1: FunesCore](phase-1-core.md) | Vault logic package: store, policy engine, disclosure, suggestions, search, import/export |
| [Phase 2: BridgeKit and MCP](phase-2-bridgekit-and-mcp.md) | Extract BridgeKitCore (shared with EK Bridge, which adopts it first), copy UI pieces, tool contract, handlers, launcher, first panels, Python harness |
| [Phase 3: Mac app](phase-3-mac-app.md) | Menu bar, Vault, Inbox, Agents, Activity, capture, onboarding, settings |
| [Phase 4b: Remote Access](phase-4b-remote-access.md) | Extract BridgeKitRemote (EK Bridge adopts it first), then cloud agents (ChatGPT, claude.ai, …) through the user's tunnel, with the same policy as local agents. Before the launch |
| [Phase 4: Ship v0.1](phase-4-ship-mac-preview.md) | Release pipeline, Homebrew, MCP Registry, docs, live matrix, launch (4.4 and 4.5 wait for Phase 4b) |
| [Phase 5: iPhone companion](phase-5-iphone-companion.md) | Companion server, pairing, iPhone app, approvals from the iPhone, App Store |
| [Project setup](project-setup.md) | Repo, targets, bundle IDs, platforms, dependencies, signing, conventions |
| [Testing strategy](testing-strategy.md) | Test layers, privacy assertions, fixtures, definition of done |
| [Release and distribution](release-and-distribution.md) | Versioning, channels, release checklist, support |
| [Open questions](open-questions.md) | 24 decisions with recommendations and deadlines (Q1, Q3, Q4, Q5, Q8, Q9, Q14, Q15, Q16, Q17, Q23 and others decided) |

**Where to start:**
1. ~~Decide name, repo, domain, license, minimum macOS and project style~~ (done 2026-10-16: Funes Vault, `bereciartua/funes-vault-app`, funesvault.com, Apache-2.0, macOS 15, plain Xcode project).
2. ~~Do the [project setup](project-setup.md)~~ (done 2026-10-16: packages, Xcode project, CI).
3. Run spikes 2 and 3.
4. Record the results in `spike-results.md` (create it in this folder).
