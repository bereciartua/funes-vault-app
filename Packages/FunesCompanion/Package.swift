// swift-tools-version: 6.0
import PackageDescription

// The Mac's side of the iPhone companion (spec/architecture/companion-protocol.md): the listener
// on 47626, pairing, the device registry and the method handlers, which call FunesCore as the
// owner. No AppKit or SwiftUI: the app supplies the Allow prompt and the Settings pane. BridgeKit
// only for its HTTP/1.1 parser.
let package = Package(
    name: "FunesCompanion",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "FunesCompanion", targets: ["FunesCompanion"]),
    ],
    dependencies: [
        .package(path: "../FunesCore"),
        .package(path: "../FunesProtocol"),
        // Tests only: the iPhone's CompanionClient against the real router.
        .package(path: "../FunesPhone"),
        .package(url: "https://github.com/bereciartua/bridgekit.git", exact: "0.4.1"),
    ],
    targets: [
        .target(
            name: "FunesCompanion",
            dependencies: [
                "FunesCore",
                "FunesProtocol",
                .product(name: "BridgeKitCore", package: "bridgekit"),
            ]
        ),
        .testTarget(
            name: "FunesCompanionTests",
            dependencies: ["FunesCompanion", "FunesCore", "FunesProtocol", "FunesPhone"]
        ),
    ]
)
