// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BuildAIMaker",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "BAMCore", targets: ["BAMCore"]),
        .library(name: "BAMResourcesUI", targets: ["BAMResourcesUI"]),
        .executable(name: "BuildAIMaker", targets: ["BuildAIMaker"]),
        .executable(name: "bam-llm-worker", targets: ["bam-llm-worker"]),
    ],
    targets: [
        .target(
            name: "BAMCore",
            path: "Packages/BAMCore/Sources/BAMCore"
        ),
        .target(
            name: "BAMResourcesUI",
            dependencies: ["BAMCore"],
            path: "Packages/BAMResourcesUI/Sources/BAMResourcesUI"
        ),
        .executableTarget(
            name: "BuildAIMaker",
            dependencies: [
                "BAMCore",
                "BAMResourcesUI",
            ],
            path: "Apps/BuildAIMaker/Sources"
        ),
        .executableTarget(
            name: "bam-llm-worker",
            dependencies: ["BAMCore"],
            path: "Workers/bam-llm-worker/Sources"
        ),
        .testTarget(
            name: "BAMCoreTests",
            dependencies: ["BAMCore"],
            path: "Packages/BAMCore/Tests/BAMCoreTests"
        ),
    ]
)
