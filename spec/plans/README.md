# Plans

| Document | What it covers |
|---|---|
| [Phase 0: Spikes](phase-0-spikes.md) | Three risky questions answered with throwaway code: companion transport, search quality, agent approval wait |
| [Phase 1: FunesCore](phase-1-core.md) | Vault logic package: store, policy engine, disclosure, suggestions, search, import/export |
| [Phase 2: BridgeKit and MCP](phase-2-bridgekit-and-mcp.md) | Extract BridgeKitCore (shared with EK Bridge, which adopts it first), copy UI pieces, tool contract, handlers, launcher, first panels, Python harness |
| [Phase 3: Mac app](phase-3-mac-app.md) | Menu bar, Vault, Inbox, Agents, Activity, capture, onboarding, settings |
| [Phase 4b: Remote Access](phase-4b-remote-access.md) | Extract BridgeKitRemote (EK Bridge adopts it first), then cloud agents (ChatGPT, claude.ai, …) through the user's tunnel, with the same policy as local agents. Before the launch |
| [Phase 4b follow-up: Funnel ports](phase-4b-funnel-ports.md) | Funes and EK Bridge share Tailscale Funnel on one Mac: each uses the first free public port (443, 8443, 10000) and never replaces another app's entry. BridgeKit 0.3.0, Funes 0.1.1. Superseded by the next row |
| [Phase 4b follow-up 2: Funnel paths](phase-4b-funnel-paths.md) | claude.ai and ChatGPT only connect to port 443, so every app shares Funnel's 443 by adding only its own paths. BridgeKit 0.4.0, Funes 0.1.2, EK Bridge 0.11.4. Before the launch |
| [Phase 4: Ship v0.1](phase-4-ship-mac-preview.md) | Release pipeline, Homebrew, MCP Registry, docs, live matrix, launch (4.4 and 4.5 wait for Phase 4b) |
| [Phase 5: iPhone companion](phase-5-iphone-companion.md) | Companion server, pairing, iPhone app, approvals from the iPhone, App Store |
| [Phase 6.0: Spike E](phase-6-0-spike-e.md) | Measure extraction, linking and tidy-up quality per provider (Apple on-device included) on synthetic fixtures, before building Phase 6 |
| [Phase 6.1: Foundations](phase-6-1-foundations.md) | Per-action apply, version-checked targets, schema v4, a durable processing queue, the multi-item cloud guard and daily cap, the undo log, iPhone and export changes |
| [Phase 6a: New memories](phase-6a-new-memories.md) | Split every new input into atomic pieces, classify and link them, auto-apply with undo ([ADR-0020](../architecture/decisions/0020-atomic-extraction-for-every-source.md)) |
| [Phase 6b: Daily tidy-up](phase-6b-daily-tidy-up.md) | Daily update, merge, split, archive and conflict proposals, with optional auto-apply ([ADR-0021](../architecture/decisions/0021-daily-tidy-up.md)) |
| [Phase 6c: Provider embeddings](phase-6c-provider-embeddings.md) | A provider embedding model as a second index next to bge-small, gated on a benchmark gain ([ADR-0023](../architecture/decisions/0023-provider-embeddings-second-index.md)) |
| [Phase 7: Home and widgets](phase-7-home.md) | The iPhone's status bar, a vault overview of counts only, Home on the Mac and the iPhone, and iPhone widgets ([ADR-0025](../architecture/decisions/0025-vault-overview-and-iphone-cache.md)) |
| [Phase 8: About you](phase-8-about-you.md) | A small profile in Settings: Home greets you by name on both apps, and each agent gets the profile fields you tick for it with its answers ([ADR-0026](../architecture/decisions/0026-about-you-profile.md)) |
| [Project setup](project-setup.md) | Repo, targets, bundle IDs, platforms, dependencies, signing, conventions |
| [Testing strategy](testing-strategy.md) | Test layers, privacy assertions, fixtures, definition of done |
| [Release and distribution](release-and-distribution.md) | Versioning, channels, release checklist, support |
| [Open questions](open-questions.md) | 24 decisions with recommendations and deadlines (Q1, Q3, Q4, Q5, Q8, Q9, Q14, Q15, Q16, Q17, Q23 and others decided) |

**Where to start:**
1. ~~Decide name, repo, domain, license, minimum macOS and project style~~ (done 2026-10-16: Funes Vault, `bereciartua/funes-vault-app`, funesvault.com, Apache-2.0, macOS 15, plain Xcode project).
2. ~~Do the [project setup](project-setup.md)~~ (done 2026-10-16: packages, Xcode project, CI).
3. Run spikes 2 and 3.
4. Record the results in `spike-results.md` (create it in this folder).
