// swift-tools-version: 6.0
import PackageDescription

// Shared by the Mac and iPhone apps. System frameworks only: no dependencies.
let package = Package(
    name: "FunesProtocol",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "FunesProtocol", targets: ["FunesProtocol"]),
    ],
    targets: [
        .target(name: "FunesProtocol"),
        .testTarget(name: "FunesProtocolTests", dependencies: ["FunesProtocol"]),
    ]
)
