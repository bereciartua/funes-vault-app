// swift-tools-version: 6.0
import PackageDescription

// Spike G (Phase 9.2): throwaway. Runs FunesCore's real vault search and answer passages over the fixtures and
// writes each question's top results as the answer prompt would carry them. Not part of any shipping target.
let package = Package(
    name: "SearchAnswersSpike",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(path: "../../../Packages/FunesCore"),
    ],
    targets: [
        .executableTarget(
            name: "answer-input",
            dependencies: [.product(name: "FunesCore", package: "FunesCore")]
        ),
    ]
)
