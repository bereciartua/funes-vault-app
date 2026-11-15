// swift-tools-version: 6.0
import PackageDescription

// Spike H (People, search and answers): throwaway. Runs FunesCore's real vault search over an invented fixture vault
// and writes the raw scores the people ranking in search.py builds on. Not part of any shipping target.
let package = Package(
    name: "PeopleSearchSpike",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(path: "../../../Packages/FunesCore"),
    ],
    targets: [
        .executableTarget(
            name: "search-scores",
            dependencies: [.product(name: "FunesCore", package: "FunesCore")]
        ),
    ]
)
