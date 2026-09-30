// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Daptastic",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DaptasticCore", targets: ["DaptasticCore"]),
        .executable(name: "daptastic", targets: ["daptastic"]),
    ],
    targets: [
        .target(name: "DaptasticCore"),
        .executableTarget(name: "daptastic", dependencies: ["DaptasticCore"]),
        .testTarget(name: "DaptasticCoreTests", dependencies: ["DaptasticCore"]),
    ]
)
