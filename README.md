# Funes Vault

> **Give AI agents your memory. Not all of it.**

Funes Vault is a native Mac menu bar app that keeps your personal context in a private vault on your Mac and serves it to AI agents (Claude Code, Claude Desktop, Cursor, Codex, …) through a local MCP server, only as you allow. An iPhone companion captures thoughts anywhere and searches the vault when your Mac is reachable.

**Status:** early development. Nothing is released yet; the first public preview (v0.1, Mac) is planned for early 2027.

## Repository
| Path | What |
|---|---|
| [`spec/`](spec/README.md) | The product definition: vision, requirements, UX, domain model, access policy, architecture, ADRs, phase plans and roadmap. **Start here.** |
| `Apps/FunesMac/` | The Mac menu bar app (AppKit + SwiftUI) |
| `Packages/FunesProtocol/` | Types and logic shared by the Mac and iPhone apps (no dependencies) |
| `Packages/FunesCore/` | Vault logic: store, access policy, disclosure, search (Mac only, GRDB) |
| `FunesVault.xcodeproj` | The Xcode project for the app targets |
| `scripts/` | Test and check scripts |

## Building
Requires macOS 15 or later and Xcode 27 (Xcode 26.6 also works).

```bash
sh scripts/test.sh
```

That runs the package tests, the log-privacy check and an unsigned build of the Mac app. To work on the app, open `FunesVault.xcodeproj` in Xcode and run the **FunesMac** scheme.

## License
[Apache-2.0](LICENSE). See [NOTICE](NOTICE).
