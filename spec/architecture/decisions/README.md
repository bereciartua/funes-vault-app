# Architecture decision records

Short records of significant decisions. Format: Status · Context · Decision · Consequences · Alternatives considered.

| # | Decision | Status |
|---|---|---|
| 0001 | [Native macOS menu bar app](0001-native-menu-bar-app.md) | Accepted |
| 0002 | [Local MCP server over loopback HTTP with a stdio launcher](0002-local-mcp-server.md) | Accepted; amended by 0018 |
| 0003 | [The Mac is the only source of truth; the iPhone is a thin client (no CloudKit)](0003-mac-is-the-only-source-of-truth.md) | Accepted |
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
| 0014 | [User-selectable AI models, on-device by default](0014-user-selectable-models.md) | Accepted; amended by 0016 |
| 0015 | [Keyword search in v0.1; semantic search later, as an embedding model the user chooses](0015-keyword-search-first.md) | Superseded by 0016 |
| 0016 | [Bundled bge-small embeddings (Core ML) and agent keywords in v0.1](0016-bundled-bge-small-embeddings.md) | Accepted |
| 0017 | [Funes's MCP adapter is a local package, FunesMCP](0017-funes-mcp-package.md) | Accepted |
| 0018 | [Remote Access for cloud agents in v0.1, with the same policy on every channel](0018-remote-access-in-v0.1.md) | Accepted |
