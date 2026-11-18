// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "WylaCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "WylaCore", targets: ["WylaCore"]),
    ],
    targets: [
        .target(name: "WylaCore"),
        .testTarget(name: "WylaCoreTests", dependencies: ["WylaCore"]),
    ]
)
