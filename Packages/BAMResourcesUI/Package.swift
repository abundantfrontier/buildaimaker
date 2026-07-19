// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BAMResourcesUI",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "BAMResourcesUI", targets: ["BAMResourcesUI"]),
    ],
    dependencies: [
        .package(path: "../BAMCore"),
    ],
    targets: [
        .target(
            name: "BAMResourcesUI",
            dependencies: ["BAMCore"]
        ),
    ]
)
