// swift-tools-version: 6.0
import PackageDescription

// Funes's MCP server on BridgeKitCore: the tool contract, the request pipeline
// and the five tool handlers, plus the FUNES_MCP_TEST server the Python harness
// drives. No AppKit or SwiftUI: the app supplies the panels through
// `FunesPresenter` (ADR-0017).
let package = Package(
    name: "FunesMCP",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "FunesMCP", targets: ["FunesMCP"]),
        .executable(name: "funes-mcp-test-server", targets: ["funes-mcp-test-server"]),
    ],
    dependencies: [
        .package(path: "../FunesCore"),
        .package(path: "../FunesProtocol"),
        // BridgeKit by local path until bereciartua/bridgekit 0.1.0 is published; then
        // .package(url: "https://github.com/bereciartua/bridgekit", exact: "0.1.0").
        .package(path: "../../../bridgekit"),
    ],
    targets: [
        .target(
            name: "FunesMCP",
            dependencies: [
                "FunesCore",
                "FunesProtocol",
                .product(name: "BridgeKitCore", package: "bridgekit"),
            ],
            resources: [.copy("Resources/mcp-tools.json")]
        ),
        .executableTarget(
            name: "funes-mcp-test-server",
            dependencies: ["FunesMCP"]
        ),
        .testTarget(
            name: "FunesMCPTests",
            dependencies: ["FunesMCP", "FunesCore", "FunesProtocol"]
        ),
    ]
)
