// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BuildAIMaker",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "BAMCore", targets: ["BAMCore"]),
        .library(name: "BAMModels", targets: ["BAMModels"]),
        .library(name: "BAMPersistence", targets: ["BAMPersistence"]),
        .library(name: "BAMJobs", targets: ["BAMJobs"]),
        .library(name: "BAMResourcesUI", targets: ["BAMResourcesUI"]),
        .executable(name: "BuildAIMaker", targets: ["BuildAIMaker"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .target(
            name: "BAMCore",
            path: "Packages/BAMCore/Sources/BAMCore"
        ),
        .target(
            name: "BAMModels",
            dependencies: ["BAMCore"],
            path: "Packages/BAMModels/Sources/BAMModels"
        ),
        .target(
            name: "BAMPersistence",
            dependencies: [
                "BAMCore",
                "BAMModels",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Packages/BAMPersistence/Sources/BAMPersistence"
        ),
        .target(
            name: "BAMJobs",
            dependencies: [
                "BAMCore",
                "BAMModels",
                "BAMPersistence",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Packages/BAMJobs/Sources/BAMJobs"
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
                "BAMModels",
                "BAMPersistence",
                "BAMJobs",
                "BAMResourcesUI",
            ],
            path: "Apps/BuildAIMaker/Sources"
        ),
        .testTarget(
            name: "BAMCoreTests",
            dependencies: ["BAMCore"],
            path: "Packages/BAMCore/Tests/BAMCoreTests"
        ),
        .testTarget(
            name: "BAMModelsTests",
            dependencies: ["BAMModels", "BAMCore"],
            path: "Packages/BAMModels/Tests/BAMModelsTests"
        ),
        .testTarget(
            name: "BAMPersistenceTests",
            dependencies: [
                "BAMPersistence",
                "BAMModels",
                "BAMCore",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Packages/BAMPersistence/Tests/BAMPersistenceTests"
        ),
        .testTarget(
            name: "BAMJobsTests",
            dependencies: [
                "BAMJobs",
                "BAMModels",
                "BAMCore",
                "BAMPersistence",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Packages/BAMJobs/Tests/BAMJobsTests"
        ),
    ]
)
