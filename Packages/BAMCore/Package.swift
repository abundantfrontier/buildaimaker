// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BAMCore",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "BAMCore", targets: ["BAMCore"]),
    ],
    targets: [
        .target(name: "BAMCore"),
        .testTarget(
            name: "BAMCoreTests",
            dependencies: ["BAMCore"]
        ),
    ]
)
