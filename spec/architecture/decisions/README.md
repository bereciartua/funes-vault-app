# Architecture decision records

Short records of significant decisions. Format: Status · Context · Decision · Consequences · Alternatives considered.

| # | Decision | Status |
|---|---|---|
| 0001 | [Native macOS menu bar app](0001-native-menu-bar-app.md) | Accepted; amended by 0029 |
| 0002 | [Local MCP server over loopback HTTP with a stdio launcher](0002-local-mcp-server.md) | Accepted; amended by 0018 |
| 0003 | [The Mac is the only source of truth; the iPhone is a thin client (no CloudKit)](0003-mac-is-the-only-source-of-truth.md) | Accepted; amended by 0019 |
| 0004 | [SQLite through GRDB for storage](0004-sqlite-grdb.md) | Accepted |
| 0005 | [On-device intelligence only (NaturalLanguage embeddings, Foundation Models)](0005-on-device-intelligence.md) | Superseded by 0014 |
| 0006 | [Xcode project with local Swift packages](0006-xcode-project-and-packages.md) | Accepted |
| 0007 | [Developer ID distribution, not sandboxed (Mac); App Store (iPhone)](0007-developer-id-not-sandboxed.md) | Accepted |
| 0008 | [Copy EK Bridge components now, extract BridgeKit later](0008-copy-then-extract-bridgekit.md) | Superseded by 0013 |
| 0009 | [Fail-closed agent access; owner devices skip approvals](0009-fail-closed-owner-device.md) | Accepted |
| 0010 | [Start from scratch; Funes Vault (web) is reference only](0010-start-from-scratch.md) | Accepted |
| 0011 | [App-layer end-to-end encryption for companion traffic (HPKE + P-256 Secure Enclave signing)](0011-app-layer-encryption-for-companion.md) | Proposed (validate in Spike 1) |
| 0012 | [Denials report withheld counts, not memory ids](0012-withheld-counts-not-ids.md) | Accepted |
| 0013 | [Share code with EK Bridge in tiers, extracting BridgeKitCore now](0013-shared-bridgekit-core.md) | Accepted; amended by 0018 |
| 0014 | [User-selectable AI models, on-device by default](0014-user-selectable-models.md) | Accepted; amended by 0016, 0020, 0021, 0022, 0023 and 0024 |
| 0015 | [Keyword search in v0.1; semantic search later, as an embedding model the user chooses](0015-keyword-search-first.md) | Superseded by 0016 |
| 0016 | [Bundled bge-small embeddings (Core ML) and agent keywords in v0.1](0016-bundled-bge-small-embeddings.md) | Accepted; amended by 0023 |
| 0017 | [Funes's MCP adapter is a local package, FunesMCP](0017-funes-mcp-package.md) | Accepted |
| 0018 | [Remote Access for cloud agents in v0.1, with the same policy on every channel](0018-remote-access-in-v0.1.md) | Accepted |
| 0019 | [A CloudKit "doorbell" wakes the iPhone for approvals (no data in iCloud)](0019-cloudkit-doorbell-for-iphone-approvals.md) | Accepted |
| 0020 | [Every new memory is split into atomic pieces and linked to the vault](0020-atomic-extraction-for-every-source.md) | Accepted |
| 0021 | [A daily tidy-up updates, merges, splits and archives, with optional auto-apply](0021-daily-tidy-up.md) | Accepted |
| 0022 | [The user sets the cloud limit, up to everything; one limit for every task; a daily request cap](0022-cloud-limit-and-daily-cap.md) | Accepted |
| 0023 | [Provider embeddings are a second index next to the bundled one](0023-provider-embeddings-second-index.md) | Accepted |
| 0024 | [Claude and ChatGPT subscriptions as model providers, through the user's own Claude Code and Codex](0024-subscription-providers.md) | Accepted |
| 0025 | [A vault overview of counts only, served to the iPhone, which caches it for Home and widgets](0025-vault-overview-and-iphone-cache.md) | Accepted; amended by 0029 |
| 0026 | [A small "About you" profile beside the vault, shared per agent and per field with memory requests](0026-about-you-profile.md) | Accepted |
| 0027 | [Keep each memory's earlier versions for 90 days, so every change can show what it replaced](0027-memory-revisions.md) | Accepted |
| 0028 | [Search answers: snippets that show the matching sentence, and an Ask that quotes your memories, on the Mac and the iPhone](0028-search-answers.md) | Accepted |
| 0029 | [The menu bar icon opens a panel: Review cards, two switches, a field and the last 24 hours](0029-menu-bar-panel.md) | Accepted |
| 0030 | [Settings gets a sidebar; AI splits into features, accounts and limits; an account offers several models](0030-settings-window.md) | Accepted |
