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
- `Packages/FunesMCP/`: the MCP adapter: tool contract (`Sources/FunesMCP/Resources/mcp-tools.json`), `RequestPipeline`, handlers, key files, and the `funes-mcp-test-server` (FUNES_MCP_TEST) the Python harness drives. Depends on FunesCore and BridgeKit; no AppKit ([ADR-0017](spec/architecture/decisions/0017-funes-mcp-package.md)).
- `Packages/BridgeUI/`: UI pieces copied from EK Bridge (tier 2): `Upstream/` as copied, `Sources/BridgeUI/` adapted (approval queue and panel, Activity store). See its `PROVENANCE.md`.
- `Apps/FunesMCPLauncher/`: the `funes-mcp` launcher, embedded in `FunesVault.app/Contents/MacOS/`.
- `FunesVault.xcodeproj`: plain Xcode project using folder-synchronized groups, so new source files in `Apps/*` need no project-file edits.
- BridgeKit (`BridgeKitCore`, repo [`bereciartua/bridgekit`](https://github.com/bereciartua/bridgekit)) is an external package, pinned to exactly `0.1.1` in `Packages/FunesMCP/Package.swift`, `Packages/BridgeUI/Package.swift` and the Xcode project.

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
swift test --package-path Packages/FunesMCP
```
```bash
swift build --package-path Packages/FunesMCP --product funes-mcp-test-server
python3 Tests/mcp/mcp_test.py "$(swift build --package-path Packages/FunesMCP --show-bin-path)/funes-mcp-test-server" Tests/mcp/fixtures/tools.json
```
Debug builds of the app and `funes-mcp` honour `FUNES_DATA_DIR`, so a development vault never touches the real one; `--dev-seed` fills an empty one with sample memories and a Claude Code agent.
```bash
sh scripts/check_log_privacy.sh
```
User-facing text lives in `Apps/FunesMac/Localizable.xcstrings` (the app's and BridgeUI's strings). After changing UI text, build the app (test.sh does) and update the catalog; test.sh fails while it's out of date:
```bash
sh scripts/sync_strings.sh
```
The bundled embedding model isn't in git. Fetch and convert it once (Python 3.11; cached in `~/Library/Caches/com.funesvault.dev/`); without it the model-dependent tests skip:
```bash
sh scripts/fetch_embedding_model.sh
```
```bash
xcodebuild -project FunesVault.xcodeproj -scheme FunesMac -configuration Debug -destination 'generic/platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

## Conventions
- **Swift 6 language mode, strict concurrency.** Packages use `swift-tools-version: 6.0`.
- **Never log memory text, task text or keys.** Use `Logger(subsystem: "com.funesvault.mac", category: …)`, and interpolate user content only with `privacy: .private`. No `print(` in app or package sources. `scripts/check_log_privacy.sh` enforces this in CI; a line that genuinely needs `.public` must carry a `// log-safe: <reason>` comment.
- **Fail closed.** Any doubt in an access decision is a refusal ([ADR-0009](spec/architecture/decisions/0009-fail-closed-owner-device.md)). Denials report withheld counts, never ids ([ADR-0012](spec/architecture/decisions/0012-withheld-counts-not-ids.md)).
- **Tests:** Swift Testing (`@Test`, `#expect`) in packages; XCTest only for UI tests; Python for protocol harnesses. Golden files under `Tests/**/fixtures`, regenerated with `UPDATE_GOLDENS=1`.
- **Dependencies:** only BridgeKit, GRDB and Sparkle, each pinned to an **exact** version, plus one bundled model asset: `bge-small-en-v1.5` (BAAI, MIT) as Core ML, fetched at a pinned revision and checksum, never committed ([ADR-0016](spec/architecture/decisions/0016-bundled-bge-small-embeddings.md)). Ask before adding anything else.
- **Errors:** typed enums; user-facing text in String Catalogs; reason codes for agents.
- **Identifiers are final** from the first public release: bundle IDs `com.funesvault.*`, support folder `~/Library/Application Support/FunesVault/`, Keychain service `com.funesvault.provider`. See `spec/plans/project-setup.md`.
- **Git:** `main` is always releasable; feature branches, squash-merged; releases are tags `vX.Y.Z`. Add a `CHANGELOG.md` entry for every user-visible change.
