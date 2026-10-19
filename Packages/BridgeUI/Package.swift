// swift-tools-version: 6.0
import PackageDescription

// UI and workflow pieces copied from EK Bridge (tier 2, ADR-0013): the approval queue and panel,
// the Activity log, agent setup and detection, one-click setup and Move to Applications.
// `Upstream/` keeps the copies as they were (not compiled); `Sources/BridgeUI` holds the adapted
// ones. Extracted into BridgeKit as BridgeKitUI after Funes v0.1. No Funes or EventKit types.
let package = Package(
    name: "BridgeUI",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "BridgeUI", targets: ["BridgeUI"]),
    ],
    dependencies: [
        // Exactly the version FunesMCP and the Xcode project pin (AGENTS.md).
        .package(url: "https://github.com/bereciartua/bridgekit.git", revision: "6011ef86f98ec9325505009533f9ff2567a81178"),
    ],
    targets: [
        .target(name: "BridgeUI", dependencies: [.product(name: "BridgeKitCore", package: "bridgekit"),
                                                 .product(name: "BridgeKitRemote", package: "bridgekit")]),
        .testTarget(name: "BridgeUITests", dependencies: ["BridgeUI"], resources: [.copy("fixtures")]),
    ]
)
