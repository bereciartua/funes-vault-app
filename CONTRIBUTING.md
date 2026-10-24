# Contributing

Thanks for helping with Funes Vault. This is a personal project maintained on a best-effort basis, so open an issue to discuss anything bigger than a small fix before you start. Issues are for bugs and concrete changes.

Report security problems privately, as described in [SECURITY.md](SECURITY.md), never in a public issue.

## The spec comes first

The product is defined in [`spec/`](spec/README.md), and it's the source of truth: requirements with ids such as `FR-D-12`, the [access policy](spec/domain/access-policy.md) with its test vectors T1–T35, the architecture, and the decision records. Read the relevant part before you change behaviour.

- When a design changes, update the spec in the same change, and add an ADR in `spec/architecture/decisions/` for an architectural decision.
- Cite requirement ids and test vectors in commits and tests where they apply.
- [AGENTS.md](AGENTS.md) has the layout, the commands and the conventions, for people and coding agents alike.

## Build and test

You need Xcode 27 (which runs on macOS 26.6 or later) and Python 3.11 for fetching the embedding model. The app itself runs on macOS 15 or later.

```sh
sh scripts/fetch_embedding_model.sh   # once: the bundled embedding model, cached in ~/Library/Caches/com.funesvault.dev
sh scripts/test.sh                    # everything: package tests, the MCP harness, goldens, checks and builds
```

`test.sh` runs the log-privacy check, a check that models are called only through `ModelRouter.send`, the tests of the four packages, the Python MCP and Remote Access harnesses against `funes-mcp-test-server`, an unsigned Debug build, the UI-review build and the string catalog check. Without the model, the model-dependent tests skip; CI requires it. [Testing](docs/TESTING.md) lists what each part covers. To run one package:

```sh
swift test --package-path Packages/FunesCore
```

To work on the app, open `FunesVault.xcodeproj` and run the **FunesMac** scheme. Debug builds of the app and `funes-mcp` honour `FUNES_DATA_DIR`, so a development vault never touches your real one, and `--dev-seed` fills an empty one with sample memories and a Claude Code agent. One-click setup from a development vault writes into a scratch home next to it, never your real agents' configs.

## Working on a change

1. Make the smallest change that works, and test the policy and data shape offline. Add or update a test: Swift Testing (`@Test`, `#expect`) in the packages, Python for protocol harnesses.
2. **Swift 6 language mode, strict concurrency.** Keep FunesCore free of AppKit, SwiftUI, MCP and networking UI, and FunesProtocol free of dependencies.
3. **Never log memory text, task text or keys.** Use `Logger(subsystem: "com.funesvault.mac", category: …)` and interpolate user content only with `privacy: .private`. No `print(` in app or package sources. A line that genuinely needs `.public` carries a `// log-safe: <reason>` comment. `scripts/check_log_privacy.sh` enforces this.
4. **Fail closed.** Any doubt in an access decision is a refusal. Refusals report withheld counts, never ids.
5. **Errors** are typed enums, with user-facing text in the String Catalog and reason codes for agents.
6. A change to a tool's arguments, description or output starts in `Packages/FunesMCP/Sources/FunesMCP/Resources/mcp-tools.json`, which agents see, and needs the matching change in [MCP](docs/MCP.md) and the spec's [MCP server](spec/architecture/mcp-server.md).
7. Golden files (`Tests/mcp/fixtures/`, `Packages/BridgeUI/Tests/BridgeUITests/fixtures/agent-setup/`) are compared byte for byte. After an intended change, regenerate them and review the diff:

   ```sh
   UPDATE_GOLDENS=1 sh scripts/test.sh
   git diff Tests/mcp/fixtures Packages/BridgeUI/Tests/BridgeUITests/fixtures
   ```

8. **UI text** lives in `Apps/FunesMac/Localizable.xcstrings`. After changing it, build the app (`test.sh` does) and update the catalog with `sh scripts/sync_strings.sh`; `test.sh` fails while it's out of date. UI changes come with light and dark screenshots from `sh scripts/ui_snapshots.sh` in the pull request.
9. Add a line under **Unreleased** in [CHANGELOG.md](CHANGELOG.md) for every user-visible change, written for users. Release notes are made from it.
10. **Ask before adding a dependency.** The app uses only BridgeKit, GRDB and Sparkle, each pinned to an exact version, plus the bundled bge-small model, fetched at a pinned revision and checksum and never committed.

Identifiers are final from the first public release: the bundle IDs `com.funesvault.*`, the support folder `~/Library/Application Support/FunesVault/` and the Keychain service `com.funesvault.provider`. Don't change them.

## Pull requests

`main` is always releasable. Work on a branch; pull requests are merged with a merge commit, so the branch's commits stay in the history; write each commit message to stand on its own. Continuous integration runs `sh scripts/test.sh` on pull requests that change code. Releases are tags `vX.Y.Z`; see [Maintaining](docs/MAINTAINING.md).

## Personal data

- **No personal data in commits, issues or pull requests:** no keys, provider API keys, vault files, backups, exports, Activity logs, memory text or screenshots of a real vault. Use the made-up data the tests and `SampleData` already use.
- Test against a development vault (`FUNES_DATA_DIR`), never `~/Library/Application Support/FunesVault`.
- Live agent tests use a throwaway agent entry and synthetic memories. Remove the agent, and Funes from the agent's config, afterwards.

## License

Funes Vault is licensed under the [Apache License 2.0](LICENSE). By contributing, you agree that your contribution is licensed under the same terms, as section 5 of the license describes. There's no separate contributor agreement.
