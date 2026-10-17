// swift-tools-version: 6.0
import PackageDescription

// Vault logic, Mac only. No AppKit, SwiftUI, MCP or networking UI.
let package = Package(
    name: "FunesCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "FunesCore", targets: ["FunesCore"]),
    ],
    dependencies: [
        .package(path: "../FunesProtocol"),
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1"),
    ],
    targets: [
        .target(
            name: "FunesCore",
            dependencies: [
                "FunesProtocol",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .testTarget(
            name: "FunesCoreTests",
            dependencies: ["FunesCore"],
            resources: [.copy("fixtures")]
        ),
    ]
)
