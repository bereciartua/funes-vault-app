// swift-tools-version: 6.0
import PackageDescription

// Phase 0, Spike 2: throwaway search benchmark. Not part of any shipping target.
// Results: spec/plans/spike-results.md.
let package = Package(
    name: "SearchSpike",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1"),
    ],
    targets: [
        .executableTarget(
            name: "search-spike",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),
    ]
)
