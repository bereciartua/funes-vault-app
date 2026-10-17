# ADR-0006: Xcode project with local Swift packages

**Status:** Accepted · 2026-10-16

**Context.** EK Bridge builds with plain `swiftc` scripts (no Xcode project). Funes adds an iOS app, a share extension and an App Intents extension, and uses SwiftUI macros. All of that needs Xcode's toolchain and targets.

**Decision.**

Use one **Xcode project** (`FunesVault.xcodeproj`) with app targets (Mac, launcher, iOS, extensions) and **local Swift packages** `FunesCore`, `FunesProtocol`, `FunesMCP` (the MCP adapter; [ADR-0017](0017-funes-mcp-package.md)) and `BridgeUI` (copied EK Bridge UI pieces), plus the external package **`BridgeKit`** (product `BridgeKitCore`, pinned to an exact version; see [ADR-0013](0013-shared-bridgekit-core.md)). Release scripts use `xcodebuild archive`/`-exportArchive` and keep EK Bridge's notarize, DMG, Sparkle and appcast steps.

**Consequences.**

- Standard tooling for iOS, App Store Connect and TestFlight.
- Packages keep core logic UI-free and testable with `swift test`.
- Release scripts differ from EK Bridge's. Accepted.

**Alternatives considered.**

- **swiftc scripts like EK Bridge:** impractical for iOS targets.
- **Tuist or XcodeGen:** worth considering if project-file merge conflicts become painful (open question).
