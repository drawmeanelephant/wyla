// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "WylaCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "WylaCore", targets: ["WylaCore"])
    ],
    dependencies: [
        // SQLite wrapper for the event store. Pinned exactly; Dependabot proposes updates.
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.12.0")
    ],
    targets: [
        .target(name: "WylaCore", dependencies: [.product(name: "GRDB", package: "GRDB.swift")]),
        .testTarget(
            name: "WylaCoreTests",
            dependencies: ["WylaCore", .product(name: "GRDB", package: "GRDB.swift")],
            resources: [.copy("Fixtures")])
    ]
)
