# Maintaining

This guide is for maintainers: how a change is made, checked and released, and which secrets and accounts the project depends on. Contributors start with [CONTRIBUTING](../CONTRIBUTING.md). The product definition is in [`spec/`](../spec/README.md); release notes live in the [changelog](../CHANGELOG.md). The project is licensed under Apache-2.0.

## Repository map

| Path | Responsibility |
| --- | --- |
| `spec/` | The source of truth: requirements, access policy and its test vectors, architecture and ADRs, phase plans |
| `Apps/FunesMac/` | The Mac app (AppKit + SwiftUI): menu bar, windows, panels, settings, Sparkle; `Assets.xcassets` holds the app icon |
| `Apps/FunesMCPLauncher/` | `funes-mcp`, the stdio launcher agents run, embedded in `Contents/MacOS` and signed as `com.funesvault.mac.mcp` |
| `Apps/FunesMac-Info.plist` | Info.plist keys Xcode can't generate: Sparkle's feed and public key, the Services menu item |
| `Packages/FunesProtocol`, `FunesCore`, `FunesMCP`, `BridgeUI` | Shared types; the vault logic; the MCP adapter; UI pieces from EK Bridge ([Architecture](ARCHITECTURE.md)) |
| `FunesVault.xcodeproj` | Two targets, FunesMac and FunesMCPLauncher. The version lives here, once, at project level: `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` |
| `Licenses/` | Third-party license texts (GRDB, Sparkle, the bge-small model) that ship in the app with `LICENSE` and `NOTICE` |
| `scripts/test.sh` | Everything offline: package tests, the MCP harness, the log-privacy check, both Debug builds, the String Catalog check |
| `scripts/fetch_embedding_model.sh`, `scripts/embedding_model/` | The bundled model: fetched at a pinned revision, checksummed, converted to Core ML, cached in `~/Library/Caches/com.funesvault.dev/` ([ADR-0016](../spec/architecture/decisions/0016-bundled-bge-small-embeddings.md)) |
| `scripts/embed_resources.sh` | The FunesMac build phase **Embed Resources**: copies the model (checked against the pinned checksums) and the license files into the app. A Release build fails without the model; a Debug build warns and falls back to the cache folder |
| `scripts/app_icon.swift` | Draws the app icon in code and writes `AppIcon.appiconset` |
| `scripts/release.sh` and its helpers | The release ([Releasing](#releasing)): `check_version.sh`, `check_bundle.sh`, `check_notarized.sh`, `make_dmg.sh` + `dmg_window.swift`, `release_assets.sh`, `release_notes.py`, `appcast.py`, `verify_update_signature.swift` |
| `scripts/ui_snapshots.sh` | PNGs of every screen, light and dark, from the UI-review build (needs Screen Recording permission for the terminal) |
| `server.json`, `.github/workflows/mcp-registry.yml` | The MCP Registry entry `com.funesvault/funes` and the workflow that publishes it |
| `packaging/homebrew/` | The draft cask and the patch for [`bereciartua/homebrew-tap`](https://github.com/bereciartua/homebrew-tap) |
| `site/` | The website, funesvault.com, deployed to GitHub Pages |
| `.github/workflows/` | `ci.yml` (pull requests that touch code, and manual runs), `release.yml` (a `v*` tag), `mcp-registry.yml`, `pages.yml` |

## Working on a change

1. Read the relevant part of `spec/` first. When a design changes, update the spec in the same change, with an ADR for architectural decisions.
2. Run `sh scripts/test.sh`. Without the model (`sh scripts/fetch_embedding_model.sh` once) the model-dependent tests skip; CI and releases set `FUNES_REQUIRE_EMBEDDING_MODEL=1` so they fail instead.
3. For UI changes, run `sh scripts/ui_snapshots.sh` and look at the light and dark PNGs; update the README's screenshots in `docs/images/` when a pictured screen changes.
4. Never use the real vault for development: Debug builds honour `FUNES_DATA_DIR`, and `--dev-seed` fills an empty one with sample data. Keep app data, keys, logs and personal memories out of commits, issues and pull requests.
5. Add a `CHANGELOG.md` entry for every user-visible change, under `## [Unreleased]`.

CI is kept cheap while macOS minutes are scarce: it runs on pull requests that touch code and by hand (`gh workflow run CI`, with `all_toolchains` before a release to add Xcode 26.6). It can be paused with `gh workflow disable CI`. When it's paused, run `sh scripts/test.sh` locally before merging.

## Before every release

- [ ] `sh scripts/test.sh` passes with `FUNES_REQUIRE_EMBEDDING_MODEL=1`, and CI (both toolchains) is green on `main` or paused with a local run recorded.
- [ ] A higher `CURRENT_PROJECT_VERSION` and the new `MARKETING_VERSION` in the project (project level only; `scripts/check_version.sh` rejects a target override), `version` in `server.json`, and a `## [x.y.z]` section in the changelog.
- [ ] Docs match the behaviour: README, [MCP](MCP.md), [Testing](TESTING.md), [Privacy](../PRIVACY.md), the website.
- [ ] No personal data in the tree or the new commits: `gitleaks git` over the new commits is clean.
- [ ] UI snapshots reviewed, light and dark.
- [ ] The [live matrix](TESTING.md) ran for the four agents, and the results are recorded.
- [ ] A rehearsal, `sh scripts/release.sh --untagged --no-release`, produced a notarized DMG and zip from the release commit, so the workflow run is a formality.
- [ ] Before the first release and after changes to the bundle layout or the updater: the release install test and the fresh-account install test in [Testing](TESTING.md).

## Releasing

The Xcode project is the one source of the version. A release is a tag `v<MARKETING_VERSION>` on `main`, built by `scripts/release.sh`: in GitHub Actions when the tag is pushed (`.github/workflows/release.yml`, in the protected `release` environment), or by hand on a Mac with the Developer ID identity and notary credentials. Both produce a **draft** GitHub release to review and publish. Publishing is what installed copies see: their feed is the latest release's `appcast.xml` ([Updates](#updates)).

### What `release.sh` does

1. Refuses a tree with uncommitted changes, or a `HEAD` that isn't tagged `v<version>` (`--untagged` for a rehearsal), and runs `scripts/check_version.sh`: one `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in the project, a build number higher than the previous `v*` tag's, a changelog section, the same version in `server.json`. A release (not a rehearsal) also needs `SUFeedURL`, `SUPublicEDKey` and a Sparkle key.
2. Fetches the model (cached after the first run) and runs `scripts/test.sh` with the model required (`--skip-tests` only for repeated rehearsals).
3. Archives the universal app (`arm64 x86_64`) with `xcodebuild archive`, signed manually with the Developer ID identity, so neither a development certificate nor a provisioning profile is needed. The Release configuration never injects `get-task-allow`. The **Embed Resources** phase puts the model and the license files inside; without the model the archive fails. Packages resolve into `build/source-packages/`, which outlives a run, so Sparkle's tools stay at `build/source-packages/artifacts/sparkle/Sparkle/bin/`.
4. Exports it with `xcodebuild -exportArchive` (method `developer-id`, manual signing), which re-signs every piece inside out with the hardened runtime and a secure timestamp, then runs `scripts/check_bundle.sh`. That script checks: both architectures and the minimum macOS; `funes-mcp`'s identifier; the team, hardened runtime and no `get-task-allow` on every piece of code; a Release build; Sparkle; the feed and key; the model's checksums; the icon; and the license files.
5. Notarizes the app (`notarytool submit --wait`; anything but Accepted prints Apple's log), staples the ticket, and checks Gatekeeper's verdict with `scripts/check_notarized.sh` (`source=Notarized Developer ID` and a valid staple).
6. Builds `FunesVault-<version>.dmg` with `scripts/make_dmg.sh`: LZFSE, HFS+, an Applications link, the app icon as the volume icon, and a fixed window whose background `scripts/dmg_window.swift` draws (the icon's cream, a dotted ink arc from the app to Applications with one amber dot) and whose `.DS_Store` it writes itself, so nothing scripts Finder and it builds the same in CI. The DMG is signed, notarized, stapled and checked like the app. To see a change: `sh scripts/make_dmg.sh /Applications/FunesVault.app "Funes Vault" /tmp/test.dmg`.
7. Builds `FunesVault-<version>.zip` from the stapled app (Sparkle installs from the zip; people download the DMG). `scripts/release_assets.sh` copies the DMG to `FunesVault.dmg`, the same name in every release, so `https://github.com/bereciartua/funes-vault-app/releases/latest/download/FunesVault.dmg` always downloads the newest published version, and writes `SHA256SUMS`.
8. With a Sparkle key, signs the zip with `sign_update`, checks the signature against the app's `SUPublicEDKey` as installed copies will (`scripts/verify_update_signature.swift`), and writes `appcast.xml` (`scripts/appcast.py`) with the changelog section as HTML.
9. Creates the draft release `v<version>` with both DMG names, the zip, `SHA256SUMS`, `appcast.xml` and notes: the changelog section (`scripts/release_notes.py`) followed by Install and Checksums.

Everything goes to `dist/` (ignored). `sh scripts/release.sh --help` lists the options and environment variables.

### Cutting a release

1. On a branch: raise the version (see the checklist), turn `## [Unreleased]` into `## [x.y.z] - YYYY-MM-DD` in the changelog (keep an empty Unreleased above it), and merge.
2. Rehearse on `main`: `FUNES_NOTARY_PROFILE=ekbridge FUNES_SPARKLE_KEYCHAIN=1 sh scripts/release.sh --untagged --no-release` (the `ekbridge` notary profile on the maintainer's Mac belongs to the same team). It archives, notarizes and checks the DMG, the zip and the appcast signature without touching GitHub.
3. `git tag v<x.y.z> && git push origin v<x.y.z>`, then approve the run in Actions.
4. Open the draft: check the notes and the five assets, download the DMG and run `shasum -a 256 -c SHA256SUMS --ignore-missing`, and install it on a clean user account.
5. Publish. Then check that `https://github.com/bereciartua/funes-vault-app/releases/latest/download/appcast.xml` and `…/FunesVault.dmg` resolve to this version (`curl -sIL <url> | grep -i '^location'`), that the previous version offers the update, and that the **MCP Registry** workflow published `server.json`.
6. Update the Homebrew cask: `gh workflow run update.yml --repo bereciartua/homebrew-tap`. It bumps `funes-vault` only if the DMG's build attestation shows this repository's release workflow built it from the tag and its SHA-256 matches `SHA256SUMS`.

### The `release` environment

Create it under Settings ▸ Environments with yourself as a required reviewer, and add the secrets below. On GitHub Free, required reviewers, tag rulesets and build attestations need a **public** repository, so make it public before the first tag. Add a tag ruleset that lets only you create `v*` tags.

| Secret | Value |
| --- | --- |
| `DEVELOPER_ID_P12` | The Developer ID Application certificate with its private key, exported from Keychain Access as a `.p12`, base64 encoded (`base64 -i certificate.p12 \| pbcopy`). The same certificate as EK Bridge's |
| `DEVELOPER_ID_P12_PASSWORD` | The `.p12` password |
| `NOTARY_KEY` | An App Store Connect API key (`.p8`, Developer role), base64 encoded |
| `NOTARY_KEY_ID`, `NOTARY_ISSUER_ID` | The key's ID and issuer ID |
| `SPARKLE_PRIVATE_KEY` | Funes's EdDSA private key, `generate_keys --account funes-vault -x <file>`, as the file's text. Required |

The MCP Registry workflow needs `MCP_REGISTRY_DNS_KEY` too (see the workflow's header). The release workflow imports the certificate into a temporary keychain, writes the keys to files under `RUNNER_TEMP`, runs `scripts/release.sh`, attests the DMGs and the zip (`gh attestation verify FunesVault-<version>.dmg --repo bereciartua/funes-vault-app`) and deletes the keychain and keys. Keep the `.p12` and the Sparkle key backed up outside GitHub.

### By hand

`release.sh` finds the one `Developer ID Application` identity in the keychain (or takes `FUNES_SIGN_IDENTITY`). `FUNES_SPARKLE_KEYCHAIN=1` signs the appcast with the key in the login keychain (account `funes-vault`, `FUNES_SPARKLE_ACCOUNT` to change it), so it never has to be exported on the maintainer's Mac. For notarization, `FUNES_NOTARY_PROFILE=<profile>` uses a `notarytool store-credentials` profile; `FUNES_NOTARY_KEY`, `FUNES_NOTARY_KEY_ID` and `FUNES_NOTARY_ISSUER` use an API key file. The draft needs `gh` signed in. A full run from a tagged commit behaves like the workflow, minus the attestations.

## Updates

The app updates itself with [Sparkle](https://sparkle-project.org) 2.10.0 (`Apps/FunesMac/Updates/SparkleUpdater.swift`). The feed (`SUFeedURL`) is `https://github.com/bereciartua/funes-vault-app/releases/latest/download/appcast.xml`, which GitHub redirects to the newest published, non-prerelease release, so drafts and prereleases are never offered and there's no server. Checks run once a day while automatic checks are on, and from **Check for Updates…**; installing always takes a click.

**The key** is Funes's own, not EK Bridge's. It was created once with:

```bash
build/source-packages/artifacts/sparkle/Sparkle/bin/generate_keys --account funes-vault
```

That stores the private key in the login keychain under the account `funes-vault` (EK Bridge's is the default account, `ed25519`) and prints the public key, which is `SUPublicEDKey` in `Apps/FunesMac-Info.plist`. `generate_keys --account funes-vault -x <file>` exports the private key for the `SPARKLE_PRIVATE_KEY` secret and a backup; delete the exported file afterwards. **Never change `SUPublicEDKey` in a release:** installed copies only accept updates signed with the key they shipped with, and a lost key means every user downloads the next version by hand.

**Updating Sparkle:** change the exact version in the Xcode project's package reference, read Sparkle's changelog, run the update test in [Testing](TESTING.md), and note it in the changelog and `Licenses/Sparkle.txt`.

## The bundled model

`scripts/fetch_embedding_model.sh` pins the Hugging Face revision and the SHA-256 of every downloaded file and of the converted weights. `scripts/embed_resources.sh` and `scripts/check_bundle.sh` read those pins from it, so changing the model means changing that one script (and the cache folder name in `Apps/FunesMac/App/VaultEnvironment.swift` and the CI cache key), re-running the search regression, and writing an ADR.

## The app icon

`scripts/app_icon.swift` draws it: a vault door whose face is made of rings like a tree's growth rings (a memory that keeps every year), with one short stretch lit in amber, the one memory an agent gets. Sizes of 64 pixels and below use a simpler drawing with three thicker rings. After a change:

```bash
xcrun swiftc -O scripts/app_icon.swift -o build/app_icon
build/app_icon iconset Apps/FunesMac/Assets.xcassets/AppIcon.appiconset
build/app_icon png site/assets/icon-512.png 512
```

## Upgrade notes

What changed in each version is in the [changelog](../CHANGELOG.md).
