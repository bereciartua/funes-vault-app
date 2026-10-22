// swift-tools-version: 6.0
import PackageDescription

// The iPhone's side of the companion (spec/architecture/companion-protocol.md): the device keys,
// the pairing record and `CompanionClient`. Shared by the iPhone app and its extensions. Builds
// for macOS too, so its tests run with `swift test`. FunesProtocol and system frameworks only.
let package = Package(
    name: "FunesPhone",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "FunesPhone", targets: ["FunesPhone"]),
    ],
    dependencies: [
        .package(path: "../FunesProtocol"),
    ],
    targets: [
        .target(name: "FunesPhone", dependencies: ["FunesProtocol"], resources: [.process("Resources")]),
        .testTarget(name: "FunesPhoneTests", dependencies: ["FunesPhone", "FunesProtocol"]),
    ]
)
