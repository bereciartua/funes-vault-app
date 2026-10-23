// swift-tools-version: 6.0
import PackageDescription

// Phase 6.0, Spike E: throwaway helpers for the Python harness. Not part of any shipping target.
// fm-runner: Apple Foundation Models (on-device) over JSON lines. bge-embed: FunesCore's bundled bge-small.
// Results: spec/plans/spike-results.md.
let package = Package(
    name: "SpikeEHelpers",
    platforms: [.macOS("26.4")],
    dependencies: [.package(path: "../../../Packages/FunesCore")],
    targets: [
        .executableTarget(name: "fm-runner"),
        .executableTarget(name: "bge-embed", dependencies: [.product(name: "FunesCore", package: "FunesCore")]),
    ]
)
