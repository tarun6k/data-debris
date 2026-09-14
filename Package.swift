// swift-tools-version:5.10
// SPM manifest exists for `swift run debris-scan` (debug CLI) and fast
// `swift test`-style iteration; the shipped app builds via XcodeGen.
import PackageDescription

let package = Package(
    name: "DataDebris",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
    ],
    targets: [
        .target(
            name: "DebrisCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
            resources: [.copy("Resources/catalogue.json")]),
        .executableTarget(
            name: "debris-scan",
            dependencies: ["DebrisCore"],
            path: "Sources/DebrisCLI"),
    ])
