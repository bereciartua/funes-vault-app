# Project setup

## Repository
- **New repo** (decided, [Q4](open-questions.md)): **`bereciartua/funes-vault-app`**. `funes-vault` stays untouched as a historical artifact. License Apache-2.0, matching EK Bridge and Funes Vault.
- **Layout:** see [architecture overview: repository layout](../architecture/overview.md#repository-layout-proposed).
- **Branching:** `main` is always releasable. Feature branches are merged with squash. Releases are tags `vX.Y.Z`.
- **Agent instructions:** `CLAUDE.md` and `AGENTS.md` at the root, with build and test commands, conventions, "never log memory text", and pointers to these docs.

## Apple Developer account
- **Team:** Martin Bereciartua (individual), Team ID `JVNJ326L7B`, the same team that signs EK Bridge.
- **Registered on 2026-10-16:**
  - App IDs: `com.funesvault.ios`, `com.funesvault.mac`, `com.funesvault.ios.share`, `com.funesvault.ios.intents`.
  - App Group: `group.com.funesvault`.
  - App Store Connect record: "Funes Vault" (iOS).
- **Seller name:** on an individual account, the App Store shows the developer's legal name as the seller. Showing a company name needs an organization account (legal entity and D-U-N-S); optional, revisit at 1.0.

## Targets and identifiers
| Target | Type | Bundle ID | Notes |
|---|---|---|---|
| FunesMac | macOS app | `com.funesvault.mac` | `LSUIElement`; hardened runtime; not sandboxed; Developer ID |
| funes-mcp | command-line tool, embedded in `Contents/MacOS` | `com.funesvault.mac.mcp` | Signed with the app's team |
| FunesiOS | iOS app | `com.funesvault.ios` | App Store; App Group `group.com.funesvault` |
| FunesShareExtension | iOS share extension | `com.funesvault.ios.share` | App Group |
| FunesIntents | App Intents / Control extension | `com.funesvault.ios.intents` | App Group |
| FunesNotifications | Notification service extension | `com.funesvault.ios.notifications` | App Group; words approval alerts on the phone ([ADR-0019](../architecture/decisions/0019-cloudkit-doorbell-for-iphone-approvals.md)). App ID to register |
| FunesCore | Swift package (macOS) | — | GRDB dependency |
| FunesProtocol | Swift package (macOS + iOS) | — | No dependencies (CryptoKit, Foundation) |
| FunesPhone | Local Swift package (iOS + macOS) | — | The iPhone's side of the companion: device keys, pairing record, `CompanionClient`. FunesProtocol only; builds for macOS so its tests run with `swift test` (task 5.3) |
| BridgeUI | Local Swift package (macOS) | — | UI and workflow pieces copied from EK Bridge (approvals, activity, agent setup UI, app shell); Sparkle via the app target only. Becomes BridgeKitUI after v0.1 |
| BridgeKit (`BridgeKitCore`) | **External** Swift package, repo `bereciartua/bridgekit` | — | Shared with EK Bridge: HTTP, MCP protocol, keys, limits, launcher, safe files, config writer ([ADR-0013](../architecture/decisions/0013-shared-bridgekit-core.md)) |

**Decided identifiers** (domain **funesvault.com**, bought 2026-10-16):
| Identifier | Value |
|---|---|
| App name (store, website, `CFBundleDisplayName`) | **Funes Vault** |
| Mac bundle file | `FunesVault.app` |
| Mac support folder | `~/Library/Application Support/FunesVault/` |
| Logger subsystem | `com.funesvault.mac` / `com.funesvault.ios` |
| Keychain service (provider keys) | `com.funesvault.provider` |
| Keychain service (Mac companion identity) | `com.funesvault.companion` (`.dev` for a development vault) |
| Keychain service (iPhone device keys and pairing record) | `com.funesvault.ios.companion`, access group `JVNJ326L7B.com.funesvault.shared` (Keychain Sharing, `$(AppIdentifierPrefix)com.funesvault.shared`), shared by the app and its extensions |
| Background task (iOS) | `com.funesvault.ios.deliver` |
| MCP server key / launcher / key prefix | `funes` / `funes-mcp` / `fns_mcp_v1_` (kept short on purpose) |
| Bonjour service | `_funes._tcp` |
| iCloud container (approvals doorbell only, [ADR-0019](../architecture/decisions/0019-cloudkit-doorbell-for-iphone-approvals.md)) | `iCloud.com.funesvault`, record type `Doorbell` |
| Homebrew cask | `funes-vault` (`brew install --cask bereciartua/tap/funes-vault`) |
| MCP Registry name | `com.funesvault/funes`, with the namespace verified via a DNS TXT record on funesvault.com |
| Website, privacy policy, support | `https://funesvault.com`, `/privacy`, `/support` |

**Bundle IDs are final from the first public release.** Changing them later breaks Sparkle updates, Keychain items, the data folder and the App Store record.

## Platforms
- **macOS:** minimum **15.0** (decided, [Q5](open-questions.md)). Universal (arm64 + x86_64).
  - Foundation Models features: macOS 26+ with Apple Intelligence.
  - NaturalLanguage embeddings: available from macOS 14.
- **iOS:** proposed minimum **18.0** (needed for Controls). SpeechAnalyzer dictation on iOS 26+, otherwise system dictation.
- **Swift:** 6 language mode with strict concurrency, using the current Xcode (27.x).

## Dependencies (keep this list short)
| Package | Why | Pinned how |
|---|---|---|
| BridgeKit (own) | Shared protocol and security core with EK Bridge | SwiftPM **exact** version tag |
| GRDB.swift | SQLite, migrations, FTS5, backups | SwiftPM exact version |
| Sparkle 2.x | Updates (Mac app only) | SwiftPM exact version + checksum: **2.10.0** (EK Bridge's version), revision `eef1a53`, binary checksum `17e28312…4fd959` verified by SwiftPM; Mac app target only |
| bge-small-en-v1.5 (BAAI, MIT): bundled model asset, not a package | The on-device embedding model ([ADR-0016](../architecture/decisions/0016-bundled-bge-small-embeddings.md)) | Pinned Hugging Face revision + SHA-256, converted to Core ML by `scripts/fetch_embedding_model.sh`; not committed |

**Nothing else.** CryptoKit, NaturalLanguage, FoundationModels, Network, VisionKit, CoreImage, AppIntents and BackgroundTasks are system frameworks.

The OpenAI-compatible and Anthropic model clients are small `URLSession` code in FunesCore: no provider SDKs ([ADR-0014](../architecture/decisions/0014-user-selectable-models.md)).

## Signing and secrets
- **Apple Developer Program team:** the same as EK Bridge.
- **Mac:** a Developer ID Application certificate and a notary profile (on the maintainer's Mac, the existing `ekbridge` profile of the same team: `FUNES_NOTARY_PROFILE=ekbridge`), or an App Store Connect API key in CI. Archives are signed manually with the Developer ID identity and exported with method `developer-id` ([MAINTAINING](../../docs/MAINTAINING.md#releasing)).
- **iOS:** automatic signing for development; App Store distribution via Xcode Cloud or `xcodebuild -exportArchive` with an API key.
- **Sparkle EdDSA key pair:** a new pair for Funes, not EK Bridge's: `generate_keys --account funes-vault` (EK Bridge's is the default account, `ed25519`). The private key lives in the login keychain under that account and in a CI secret; the public key goes in `Info.plist` (`SUPublicEDKey`).
- **CI secrets** (GitHub `release` environment):
  - the p12 and its password;
  - the notary API key;
  - the Sparkle private key;
  - the App Store Connect API key.

## Info.plist highlights (Mac)
- `LSUIElement = YES`, `LSMinimumSystemVersion = 15.0`.
- `NSServices`: "Remember in Funes" (`NSStringPboardType` / `public.utf8-plain-text`). Keys Xcode can't generate from build settings live in `Apps/FunesMac-Info.plist`, merged into the generated Info.plist.
- `SUFeedURL = https://github.com/bereciartua/funes-vault-app/releases/latest/download/appcast.xml`, `SUPublicEDKey`.
- `NSLocalNetworkUsageDescription` (v0.2, for Bonjour advertising if prompted).

## Info.plist highlights (iOS)
- `NSLocalNetworkUsageDescription`: "Funes connects to your Mac on your local network to send captures and search your vault."
- `NSBonjourServices = ["_funes._tcp"]`.
- `NSCameraUsageDescription`: "Scan the pairing code shown by Funes on your Mac."
- `NSSpeechRecognitionUsageDescription` and `NSMicrophoneUsageDescription`, for dictation.
- ATS: `NSAllowsLocalNetworking = YES`.
- `BGTaskSchedulerPermittedIdentifiers = ["com.funesvault.ios.deliver"]` (task 5.4).
- `FunesKeychainGroup = $(AppIdentifierPrefix)com.funesvault.shared`, in the app's and each extension's Info.plist, so the code knows the shared Keychain access group with its team prefix.
- The files: `Apps/FunesiOS-Info.plist`, `Apps/FunesShareExtension-Info.plist`, `Apps/FunesIntents-Info.plist`, and an `Apps/<target>.entitlements` for each (App Group and Keychain Sharing). The iOS targets inherit the project's `MARKETING_VERSION` (one version for the whole project, which `scripts/check_version.sh` requires) until the App Store release (task 5.7) decides otherwise.

## Developer environment
- Xcode 27.x and Python 3 (for the MCP harness and appcast scripts).
- `gh` CLI for releases.
- Tailscale on a test Mac and iPhone, for Phase 5.
- A second macOS user account, for first-run testing.

## Conventions
- **Logging:** `Logger(subsystem: "com.funesvault.mac", category: …)`. User content always uses `privacy: .private`. There's a CI check (`grep`) that no `print(` or `.public` interpolation touches memory fields.
- **Errors:** typed enums with user-facing messages in String Catalogs, plus reason codes for agents.
- **Tests:** Swift Testing (`@Test`, `#expect`) in packages, XCTest only for UI tests, Python for protocol harnesses. Golden files under `Tests/**/fixtures`, regenerated with `UPDATE_GOLDENS=1`.
- **Docs:** update `CHANGELOG.md` with every user-visible change. Record design changes as new ADRs.
