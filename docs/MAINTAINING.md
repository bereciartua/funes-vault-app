# Maintaining

This guide is for maintainers: how a change is made, checked and released, and which secrets and accounts the project depends on. Contributors start with [CONTRIBUTING](../CONTRIBUTING.md). The product definition is in [`spec/`](../spec/README.md); release notes live in the [changelog](../CHANGELOG.md). The project is licensed under Apache-2.0.

## Repository map

| Path | Responsibility |
| --- | --- |
| `spec/` | The source of truth: requirements, access policy and its test vectors, architecture and ADRs, phase plans |
| `Apps/FunesMac/` | The Mac app (AppKit + SwiftUI): menu bar, windows, panels, settings, Sparkle; `Assets.xcassets` holds the app icon |
| `Apps/FunesMCPLauncher/` | `funes-mcp`, the stdio launcher agents run, embedded in `Contents/MacOS` and signed as `com.funesvault.mac.mcp` |
| `Apps/FunesMac-Info.plist` | Info.plist keys Xcode can't generate: Sparkle's feed, public key and check settings, the Services menu item |
| `Packages/FunesProtocol`, `FunesCore`, `FunesMCP`, `BridgeUI` | Shared types; the vault logic; the MCP adapter; UI pieces from EK Bridge ([Architecture](ARCHITECTURE.md)) |
| `FunesVault.xcodeproj` | Two targets, FunesMac and FunesMCPLauncher. The version lives here, once, at project level: `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` |
| `Licenses/` | Third-party license texts (GRDB, Sparkle, the bge-small model) that ship in the app with `LICENSE` and `NOTICE` |
| `scripts/test.sh` | Everything offline: package tests, the MCP and Remote Access harnesses, the log-privacy and model-call checks, both Debug builds, the String Catalog check |
| `scripts/fetch_embedding_model.sh`, `scripts/embedding_model/` | The bundled model: fetched at a pinned revision, checksummed, converted to Core ML, cached in `~/Library/Caches/com.funesvault.dev/` ([ADR-0016](../spec/architecture/decisions/0016-bundled-bge-small-embeddings.md)) |
| `scripts/embed_resources.sh` | The FunesMac build phase **Embed Resources**: copies the model (checked against the pinned checksums) and the license files into the app. A Release build fails without the model; a Debug build warns and falls back to the cache folder |
| `scripts/app_icon.swift` | Draws the app icon in code and writes `AppIcon.appiconset` and the website's icons |
| `scripts/release.sh` and its helpers | The release ([Releasing](#releasing)): `check_version.sh`, `check_bundle.sh`, `check_notarized.sh`, `make_dmg.sh` + `dmg_window.swift`, `release_assets.sh`, `release_notes.py`, `appcast.py`, `verify_update_signature.swift` |
| `scripts/ui_snapshots.sh` | PNGs of every screen, light and dark, from the UI-review build (needs Screen Recording permission for the terminal) |
| `server.json`, `.github/workflows/mcp-registry.yml` | The MCP Registry entry `com.funesvault/funes` and the workflow that publishes it |
| `packaging/homebrew/` | The cask and the patch that added it to [`bereciartua/homebrew-tap`](https://github.com/bereciartua/homebrew-tap), kept for reference |
| `site/` | The website, funesvault.com, deployed to GitHub Pages |
| `.github/workflows/` | `ci.yml` (pull requests and manual runs; macOS only when code changed), `release.yml` (a `v*` tag), `mcp-registry.yml`, `pages.yml` |

## Working on a change

1. Read the relevant part of `spec/` first. When a design changes, update the spec in the same change, with an ADR for architectural decisions.
2. Run `sh scripts/test.sh`. Without the model (`sh scripts/fetch_embedding_model.sh` once) the model-dependent tests skip; CI and releases set `FUNES_REQUIRE_EMBEDDING_MODEL=1` so they fail instead.
3. For UI changes, run `sh scripts/ui_snapshots.sh` and look at the light and dark PNGs; update the README's screenshots in `docs/images/` when a pictured screen changes.
4. Never use the real vault for development: Debug builds honour `FUNES_DATA_DIR`, and `--dev-seed` fills an empty one with sample data. Keep app data, keys, logs and personal memories out of commits, issues and pull requests.
5. Add a `CHANGELOG.md` entry for every user-visible change, under `## [Unreleased]`.

CI is kept cheap while macOS minutes are scarce: it runs the tests on pull requests that touch code and by hand (`gh workflow run CI`, with `all_toolchains` before a release to add Xcode 26.6). A pull request that only touches `spec/**`, `spikes/**` or Markdown gets the required `Test and build (Xcode 27.0)` check from a stub on Ubuntu, so it merges without an admin bypass and without a macOS run; the `Changes` job decides which from the pull request's file list. It can be paused with `gh workflow disable CI`. When it's paused, run `sh scripts/test.sh` locally before merging.

## Before every release

- [ ] `sh scripts/test.sh` passes with `FUNES_REQUIRE_EMBEDDING_MODEL=1`, and CI (both toolchains) is green on `main` or paused with a local run recorded.
- [ ] A higher `CURRENT_PROJECT_VERSION` and the new `MARKETING_VERSION` in the project (project level only; `scripts/check_version.sh` rejects a second, different value, such as a target override), `version` in `server.json`, and a `## [x.y.z]` section in the changelog.
- [ ] The [provisioning profile](#the-provisioning-profile) "Funes Vault Mac Developer ID" is installed and the `DEVELOPER_ID_PROFILE` secret holds the same one, not near its expiry (`release.sh` prints it).
- [ ] Docs match the behaviour: README, [MCP](MCP.md), [Testing](TESTING.md), [Privacy](../PRIVACY.md), the website.
- [ ] No personal data in the tree or the new commits: `gitleaks git` over the new commits is clean.
- [ ] UI snapshots reviewed, light and dark.
- [ ] The [live matrix](TESTING.md#live-agent-matrix) ran for the four agents, and the results are recorded.
- [ ] A rehearsal, `sh scripts/release.sh --untagged --no-release`, produced a notarized DMG and zip from the release commit, so the workflow run is a formality.
- [ ] Before the first release and after changes to the bundle layout or the updater: the [release install test](TESTING.md#release-install-test) and the [fresh-account test](TESTING.md#fresh-account-test) in Testing.

## Releasing

The Xcode project is the one source of the version. A release is a tag `v<MARKETING_VERSION>` on `main`, built by `scripts/release.sh`: in GitHub Actions when the tag is pushed (`.github/workflows/release.yml`, in the protected `release` environment), or by hand on a Mac with the Developer ID identity and notary credentials. Both produce a **draft** GitHub release to review and publish. Publishing is what installed copies see: their feed is the latest release's `appcast.xml` ([Updates](#updates)).

### What `release.sh` does

1. Refuses a tree with uncommitted changes, or a `HEAD` that isn't tagged `v<version>` (`--untagged` for a rehearsal), and runs `scripts/check_version.sh`: one `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in the project, a build number higher than the previous `v*` tag's, a changelog section, the same version in `server.json`. A release (not a rehearsal) also needs `SUFeedURL`, `SUPublicEDKey` and a Sparkle key.
2. Fetches the model (cached after the first run) and runs `scripts/test.sh` with the model required (`--skip-tests` only for repeated rehearsals).
3. Archives the universal app (`arm64 x86_64`) with `xcodebuild archive`, signed manually with the Developer ID identity and the Developer ID provisioning profile, so no development certificate is needed. The profile gives the app iCloud with the container `iCloud.com.funesvault`, for the iPhone's doorbell ([ADR-0019](../spec/architecture/decisions/0019-cloudkit-doorbell-for-iphone-approvals.md)); see [The provisioning profile](#the-provisioning-profile). The Release configuration never injects `get-task-allow`. The **Embed Resources** phase puts the model and the license files inside; without the model the archive fails. Packages resolve into `build/source-packages/`, which outlives a run, so Sparkle's tools stay at `build/source-packages/artifacts/sparkle/Sparkle/bin/`.
4. Exports it with `xcodebuild -exportArchive` (method `developer-id`, manual signing, the profile, iCloud environment Production), which re-signs every piece inside out with the hardened runtime and a secure timestamp, then runs `scripts/check_bundle.sh`. That script checks: both architectures and the minimum macOS; `funes-mcp`'s identifier; the team, hardened runtime and no `get-task-allow` on every piece of code; the embedded profile, iCloud with CloudKit in Production, and no iCloud in `funes-mcp`; a Release build; Sparkle; the feed and key; the model's checksums; the icon; and the license files.
5. Notarizes the app (`notarytool submit --wait`; anything but Accepted prints Apple's log), staples the ticket, and checks Gatekeeper's verdict with `scripts/check_notarized.sh` (`source=Notarized Developer ID` and a valid staple).
6. Builds `FunesVault-<version>.dmg` with `scripts/make_dmg.sh`: LZFSE, HFS+, an Applications link, the app icon as the volume icon, and a fixed window whose background `scripts/dmg_window.swift` draws (in the app icon's colours: warm white, a dotted black arc from the app to Applications with one orange dot) and whose `.DS_Store` it writes itself, so nothing scripts Finder and it builds the same in CI. The DMG is signed, notarized, stapled and checked like the app. To see a change: `sh scripts/make_dmg.sh /Applications/FunesVault.app "Funes Vault" /tmp/test.dmg`.
7. Builds `FunesVault-<version>.zip` from the stapled app (Sparkle installs from the zip; people download the DMG). `scripts/release_assets.sh` copies the DMG to `FunesVault.dmg`, the same name in every release, so `https://github.com/bereciartua/funes-vault-app/releases/latest/download/FunesVault.dmg` always downloads the newest published version, and writes `SHA256SUMS`.
8. With a Sparkle key, signs the zip with `sign_update`, checks the signature against the app's `SUPublicEDKey` as installed copies will (`scripts/verify_update_signature.swift`), and writes `appcast.xml` (`scripts/appcast.py`) with the changelog section as HTML.
9. Creates the draft release `v<version>` with both DMG names, the zip, `SHA256SUMS`, `appcast.xml` and notes: the changelog section (`scripts/release_notes.py`) followed by Install and Checksums.

Everything goes to `dist/` (ignored). `sh scripts/release.sh --help` lists the options and environment variables.

### Cutting a release

1. On a branch: raise the version (see the checklist), turn `## [Unreleased]` into `## [x.y.z] - YYYY-MM-DD` in the changelog (keep an empty Unreleased above it, and update the compare links at the bottom), and merge.
2. Rehearse on `main`, with the [provisioning profile](#the-provisioning-profile) installed: `FUNES_NOTARY_PROFILE=ekbridge FUNES_SPARKLE_KEYCHAIN=1 sh scripts/release.sh --untagged --no-release` (the `ekbridge` notary profile on the maintainer's Mac belongs to the same team). It archives, notarizes and checks the DMG, the zip and the appcast signature without touching GitHub.
3. `git tag v<x.y.z> && git push origin v<x.y.z>`, then approve the run in Actions.
4. Open the draft: check the notes and the five assets, download the DMG and run `shasum -a 256 -c SHA256SUMS --ignore-missing`, and install it on a clean user account.
5. Publish. Then check that `https://github.com/bereciartua/funes-vault-app/releases/latest/download/appcast.xml` and `…/FunesVault.dmg` resolve to this version (`curl -sIL <url> | grep -i '^location'`), that the previous version offers the update, and that the **MCP Registry** workflow published `server.json`.
6. Update the Homebrew cask in [`bereciartua/homebrew-tap`](https://github.com/bereciartua/homebrew-tap) ([packaging/homebrew](../packaging/homebrew/README.md)): `gh workflow run update.yml --repo bereciartua/homebrew-tap -f cask=funes-vault` (it also runs every six hours). It bumps `funes-vault` only if the DMG's build attestation shows this repository's release workflow built it from the tag and its SHA-256 matches `SHA256SUMS`.

### The `release` environment

Create it under Settings ▸ Environments with yourself as a required reviewer, and add the secrets below. On GitHub Free, required reviewers, tag rulesets and build attestations need a **public** repository, so make it public before the first tag. Add a tag ruleset that lets only you create `v*` tags.

| Secret | Value |
| --- | --- |
| `DEVELOPER_ID_P12` | The Developer ID Application certificate with its private key, exported from Keychain Access as a `.p12`, base64 encoded (`base64 -i certificate.p12 \| pbcopy`). The same certificate as EK Bridge's |
| `DEVELOPER_ID_P12_PASSWORD` | The `.p12` password |
| `DEVELOPER_ID_PROFILE` | The Developer ID provisioning profile "Funes Vault Mac Developer ID", base64 encoded (`base64 -i Funes_Vault_Mac_Developer_ID.provisionprofile \| pbcopy`). Replace it whenever the profile is renewed |
| `NOTARY_KEY` | An App Store Connect API key (`.p8`, Developer role), base64 encoded |
| `NOTARY_KEY_ID`, `NOTARY_ISSUER_ID` | The key's ID and issuer ID |
| `SPARKLE_PRIVATE_KEY` | Funes's EdDSA private key, `generate_keys --account funes-vault -x <file>`, as the file's text. Required |

The MCP Registry workflow needs `MCP_REGISTRY_DNS_KEY` in its own `registry` environment (see the workflow's header). The release workflow imports the certificate into a temporary keychain, installs the profile in `~/Library/Developer/Xcode/UserData/Provisioning Profiles`, writes the keys to files under `RUNNER_TEMP`, runs `scripts/release.sh`, attests the DMGs and the zip (`gh attestation verify FunesVault-<version>.dmg --repo bereciartua/funes-vault-app`) and deletes the keychain, the profile and the keys. Keep the `.p12` and the Sparkle key backed up outside GitHub.

### The provisioning profile

Since v0.2 the app uses CloudKit, only to ring the iPhone's doorbell for approvals ([ADR-0019](../spec/architecture/decisions/0019-cloudkit-doorbell-for-iphone-approvals.md)). A Developer ID-signed app with the iCloud entitlement launches only with a Developer ID provisioning profile that allows it, embedded as `Contents/embedded.provisionprofile`. The profile is **"Funes Vault Mac Developer ID"** (developer.apple.com ▸ Profiles): Developer ID, App ID `com.funesvault.mac` with iCloud (CloudKit) and the container `iCloud.com.funesvault`, the team's Developer ID Application certificate. The `Doorbell` record type is deployed to CloudKit Production, the environment both the released Mac app and the App Store iPhone app use; Debug builds and Xcode runs use CloudKit Development.

- **On the Mac:** Xcode ▸ Settings ▸ Accounts ▸ the team ▸ **Download Manual Profiles**, or double-click the file downloaded from the developer site. `release.sh` uses the newest valid installed profile of that name (`FUNES_MAC_PROFILE` for another name) and prints its UUID and expiry. It refuses one that isn't Developer ID, is for another team or identifier, lacks the container or Production, or has expired.
- **In CI:** the `DEVELOPER_ID_PROFILE` secret ([The release environment](#the-release-environment)).
- **Renewing:** regenerate it in the developer site when it nears its expiry or the Developer ID certificate changes, keep the same name, and replace the secret. The profile isn't confidential (it ships inside every copy of the app), but it's kept out of the repository so a renewal never needs a commit.
- Only the FunesMac target's Release configuration reads `FUNES_RELEASE_ENTITLEMENTS` and `FUNES_RELEASE_PROFILE`, and only `release.sh` sets them. Builds from source, `funes-mcp` and `scripts/test.sh`'s Debug builds stay unchanged.

### By hand

`release.sh` finds the one `Developer ID Application` identity in the keychain (or takes `FUNES_SIGN_IDENTITY`) and the installed [provisioning profile](#the-provisioning-profile). `FUNES_SPARKLE_KEYCHAIN=1` signs the appcast with the key in the login keychain (account `funes-vault`, `FUNES_SPARKLE_ACCOUNT` to change it), so it never has to be exported on the maintainer's Mac. For notarization, `FUNES_NOTARY_PROFILE=<profile>` uses a `notarytool store-credentials` profile; `FUNES_NOTARY_KEY`, `FUNES_NOTARY_KEY_ID` and `FUNES_NOTARY_ISSUER` use an API key file. The draft needs `gh` signed in. A full run from a tagged commit behaves like the workflow, minus the attestations.

### The iPhone app

The iPhone app ships through App Store Connect, not GitHub. `sh scripts/ios_release.sh` archives it (Release, automatic signing for team JVNJ326L7B) and checks the archive; `--export` signs an `.ipa` for App Store Connect into `dist/ios/`, and `--upload` sends it to TestFlight. `FUNES_IOS_BUILD` sets a higher build number for another upload of the same version. The texts, privacy answers, screenshots plan, App Review notes and the steps in App Store Connect are in [spec/release/app-store](../spec/release/app-store/README.md).

## Updates

The app updates itself with [Sparkle](https://sparkle-project.org) 2.10.0 (`Apps/FunesMac/Updates/SparkleUpdater.swift`). The feed (`SUFeedURL`) is `https://github.com/bereciartua/funes-vault-app/releases/latest/download/appcast.xml`, which GitHub redirects to the newest published, non-prerelease release, so drafts and prereleases are never offered and there's no server. Checks run once a day while automatic checks are on, and from **Check for Updates…**; installing always takes a click. Only a copy signed with the Developer ID of team `JVNJ326L7B` checks (`SparkleUpdater.isConfigured`, the team `scripts/release.sh` requires): builds from source, Xcode runs and `scripts/test.sh`'s Debug build never check, and hide **Check for Updates…**. A release rehearsal signed with the Developer ID does check.

**The key** is Funes's own, not EK Bridge's. It was created once with:

```bash
build/source-packages/artifacts/sparkle/Sparkle/bin/generate_keys --account funes-vault
```

That stores the private key in the login keychain under the account `funes-vault` (EK Bridge's is the default account, `ed25519`) and prints the public key, which is `SUPublicEDKey` in `Apps/FunesMac-Info.plist`. `generate_keys --account funes-vault -x <file>` exports the private key for the `SPARKLE_PRIVATE_KEY` secret and a backup; delete the exported file afterwards. **Never change `SUPublicEDKey` in a release:** installed copies only accept updates signed with the key they shipped with, and a lost key means every user downloads the next version by hand.

**Updating Sparkle:** change the exact version in the Xcode project's package reference, read Sparkle's changelog, run the [update test](TESTING.md#update-test), and note it in the changelog and `Licenses/Sparkle.txt`.

## The bundled model

`scripts/fetch_embedding_model.sh` pins the Hugging Face revision and the SHA-256 of every downloaded file and of the converted weights. `scripts/embed_resources.sh` and `scripts/check_bundle.sh` read those pins from it, so changing the model means changing that one script (and the cache folder name in `Apps/FunesMac/App/VaultEnvironment.swift`, FunesCore's test `Fixtures.swift`, the cache paths in `ci.yml` and `release.yml`, and `Licenses/bge-small-en-v1.5.txt`), re-running the search regression, and writing an ADR.

## The app icon

`scripts/app_icon.swift` draws it: an open eye, white with a black outline and a black iris, on an orange ground, for Funes, Borges' man who remembers everything he has seen. Sizes of 64 pixels and below use a bolder drawing of the same eye, with a heavier outline, a larger iris and no sheen, shadows or catchlight. After a change, regenerate the app's icon set and the website's icons:

```bash
xcrun swiftc -O scripts/app_icon.swift -o build/app_icon
build/app_icon iconset Apps/FunesMac/Assets.xcassets/AppIcon.appiconset
build/app_icon png site/assets/icon-512.png 512
build/app_icon png site/assets/favicon-64.png 64
build/app_icon png site/assets/apple-touch-icon.png 180
build/app_icon png build/favicon-32.png 32   # then wrap it as site/favicon.ico (a single 32-pixel PNG entry)
```

The website's big eye (the inline SVG in `site/index.html` and `site/404.html`) is the same large drawing, in the icon's 1024-point coordinates: the almond's corners at 196 and 828 with control points 21% in, lids at 250 and 774, a 44-point outline, a 138-point iris with its catchlight and orange rim, and the soft shadow. The page animates only its iris and a blink. If the drawing changes, change the SVG to match.

## Upgrade notes

What changed in each version is in the [changelog](../CHANGELOG.md).
