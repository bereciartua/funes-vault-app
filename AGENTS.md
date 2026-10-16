# Agent instructions: Funes Vault

Funes Vault is a native Mac menu bar app that keeps a personal memory vault on the Mac and serves it to AI agents over a local MCP server, only as the user allows. An iPhone companion (v0.2) is a thin client.

## The spec is the source of truth
Everything is defined in [`spec/`](spec/README.md). Read the relevant part before building a feature:
- **What to build next:** the phase plans in `spec/plans/` (tick their checklists as tasks land) and the [roadmap](spec/roadmap/roadmap.md).
- **Requirements:** `spec/product/03-requirements.md` (ids like `FR-D-12`; cite them in commits and tests).
- **The core rules:** `spec/domain/access-policy.md` (with test vectors T1–T35) and `spec/domain/domain-model.md`.
- **Architecture:** `spec/architecture/`; decisions in `spec/architecture/decisions/` (ADRs).

When a design changes, update the spec in the same change and add an ADR for architectural decisions. Record spike results in `spec/plans/spike-results.md`.

## Layout
- `Apps/FunesMac/`: the Mac app target (bundle `com.funesvault.mac`, `LSUIElement`, hardened runtime, not sandboxed, macOS 15+). Later: `FunesMCPLauncher/`, `FunesiOS/`, `FunesShareExtension/`, `FunesIntents/`.
- `Packages/FunesProtocol/`: shared Mac + iOS types and logic. **No dependencies** beyond system frameworks.
- `Packages/FunesCore/`: vault logic, Mac only. Depends on FunesProtocol and GRDB. **No AppKit, SwiftUI, MCP or networking UI** here.
- `FunesVault.xcodeproj`: plain Xcode project using folder-synchronized groups, so new source files in `Apps/*` need no project-file edits.
- BridgeKit (`BridgeKitCore`, repo `bereciartua/bridgekit`) is an external package, added in Phase 2.

## Commands
```bash
sh scripts/test.sh
```
Runs everything below. Individually:
```bash
swift test --package-path Packages/FunesProtocol
```
```bash
swift test --package-path Packages/FunesCore
```
```bash
sh scripts/check_log_privacy.sh
```
```bash
xcodebuild -project FunesVault.xcodeproj -scheme FunesMac -configuration Debug -destination 'generic/platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

## Conventions
- **Swift 6 language mode, strict concurrency.** Packages use `swift-tools-version: 6.0`.
- **Never log memory text, task text or keys.** Use `Logger(subsystem: "com.funesvault.mac", category: …)`, and interpolate user content only with `privacy: .private`. No `print(` in app or package sources. `scripts/check_log_privacy.sh` enforces this in CI; a line that genuinely needs `.public` must carry a `// log-safe: <reason>` comment.
- **Fail closed.** Any doubt in an access decision is a refusal ([ADR-0009](spec/architecture/decisions/0009-fail-closed-owner-device.md)). Denials report withheld counts, never ids ([ADR-0012](spec/architecture/decisions/0012-withheld-counts-not-ids.md)).
- **Tests:** Swift Testing (`@Test`, `#expect`) in packages; XCTest only for UI tests; Python for protocol harnesses. Golden files under `Tests/**/fixtures`, regenerated with `UPDATE_GOLDENS=1`.
- **Dependencies:** only BridgeKit, GRDB and Sparkle, each pinned to an **exact** version. Ask before adding anything else.
- **Errors:** typed enums; user-facing text in String Catalogs; reason codes for agents.
- **Identifiers are final** from the first public release: bundle IDs `com.funesvault.*`, support folder `~/Library/Application Support/FunesVault/`, Keychain service `com.funesvault.provider`. See `spec/plans/project-setup.md`.
- **Git:** `main` is always releasable; feature branches, squash-merged; releases are tags `vX.Y.Z`. Add a `CHANGELOG.md` entry for every user-visible change.
