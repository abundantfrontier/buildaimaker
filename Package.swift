// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BuildAIMaker",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "BAMCore", targets: ["BAMCore"]),
        .library(name: "BAMModels", targets: ["BAMModels"]),
        .library(name: "BAMPersistence", targets: ["BAMPersistence"]),
        .library(name: "BAMDatasets", targets: ["BAMDatasets"]),
        .library(name: "BAMModelCatalog", targets: ["BAMModelCatalog"]),
        .library(name: "BAMConsent", targets: ["BAMConsent"]),
        .library(name: "BAMJobs", targets: ["BAMJobs"]),
        .library(name: "BAMRunners", targets: ["BAMRunners"]),
        .library(name: "BAMRunnersMLX", targets: ["BAMRunnersMLX"]),
        .library(name: "BAMRunnersVoice", targets: ["BAMRunnersVoice"]),
        .library(name: "BAMInference", targets: ["BAMInference"]),
        .library(name: "BAMPersonas", targets: ["BAMPersonas"]),
        .library(name: "BAMResourcesUI", targets: ["BAMResourcesUI"]),
        .executable(name: "BuildAIMaker", targets: ["BuildAIMaker"]),
        .executable(name: "bam-echo-worker", targets: ["bam-echo-worker"]),
        .executable(name: "bam-llm-worker", targets: ["bam-llm-worker"]),
        .executable(name: "bam-voice-worker", targets: ["bam-voice-worker"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .target(name: "BAMCore", path: "Packages/BAMCore/Sources/BAMCore"),
        .target(name: "BAMModels", dependencies: ["BAMCore"], path: "Packages/BAMModels/Sources/BAMModels"),
        .target(name: "BAMPersistence", dependencies: ["BAMCore", "BAMModels", .product(name: "GRDB", package: "GRDB.swift")], path: "Packages/BAMPersistence/Sources/BAMPersistence"),
        .target(name: "BAMDatasets", dependencies: ["BAMCore", "BAMModels", "BAMPersistence", .product(name: "GRDB", package: "GRDB.swift")], path: "Packages/BAMDatasets/Sources/BAMDatasets"),
        .target(name: "BAMModelCatalog", dependencies: ["BAMCore", "BAMModels"], path: "Packages/BAMModelCatalog/Sources/BAMModelCatalog", resources: [.copy("Resources/models.json"), .copy("Resources/fixtures")]),
        .target(name: "BAMConsent", dependencies: ["BAMCore", "BAMModels", "BAMPersistence", .product(name: "GRDB", package: "GRDB.swift")], path: "Packages/BAMConsent/Sources/BAMConsent"),
        .target(name: "BAMJobs", dependencies: ["BAMCore", "BAMModels", "BAMPersistence", .product(name: "GRDB", package: "GRDB.swift")], path: "Packages/BAMJobs/Sources/BAMJobs"),
        .target(name: "BAMRunners", dependencies: ["BAMCore", "BAMModels", "BAMJobs"], path: "Packages/BAMRunners/Sources/BAMRunners"),
        .target(name: "BAMRunnersMLX", dependencies: ["BAMCore", "BAMModels", "BAMJobs", "BAMRunners", "BAMDatasets", "BAMModelCatalog"], path: "Packages/BAMRunnersMLX/Sources/BAMRunnersMLX"),
        .target(name: "BAMRunnersVoice", dependencies: ["BAMCore", "BAMModels", "BAMPersistence", "BAMJobs", "BAMRunners", "BAMConsent", .product(name: "GRDB", package: "GRDB.swift")], path: "Packages/BAMRunnersVoice/Sources/BAMRunnersVoice"),
        .target(name: "BAMInference", dependencies: ["BAMCore", "BAMModels"], path: "Packages/BAMInference/Sources/BAMInference"),
        .target(
            name: "BAMPersonas",
            dependencies: [
                "BAMCore",
                "BAMModels",
                "BAMPersistence",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Packages/BAMPersonas/Sources/BAMPersonas"
        ),
        .target(name: "BAMResourcesUI", dependencies: ["BAMCore"], path: "Packages/BAMResourcesUI/Sources/BAMResourcesUI"),
        .executableTarget(
            name: "BuildAIMaker",
            dependencies: [
                "BAMCore",
                "BAMModels",
                "BAMPersistence",
                "BAMDatasets",
                "BAMModelCatalog",
                "BAMConsent",
                "BAMJobs",
                "BAMRunners",
                "BAMRunnersMLX",
                "BAMRunnersVoice",
                "BAMInference",
                "BAMPersonas",
                "BAMResourcesUI",
            ],
            path: "Apps/BuildAIMaker/Sources"
        ),
        .executableTarget(name: "bam-echo-worker", path: "Workers/bam-echo-worker/Sources"),
        .executableTarget(name: "bam-llm-worker", dependencies: ["BAMCore"], path: "Workers/bam-llm-worker/Sources"),
        .executableTarget(name: "bam-voice-worker", dependencies: ["BAMCore"], path: "Workers/bam-voice-worker/Sources"),
        .testTarget(name: "BAMCoreTests", dependencies: ["BAMCore"], path: "Packages/BAMCore/Tests/BAMCoreTests"),
        .testTarget(name: "BAMModelsTests", dependencies: ["BAMModels", "BAMCore"], path: "Packages/BAMModels/Tests/BAMModelsTests"),
        .testTarget(name: "BAMPersistenceTests", dependencies: ["BAMPersistence", "BAMModels", "BAMCore", .product(name: "GRDB", package: "GRDB.swift")], path: "Packages/BAMPersistence/Tests/BAMPersistenceTests"),
        .testTarget(
            name: "BAMDatasetsTests",
            dependencies: ["BAMDatasets", "BAMModels", "BAMCore", "BAMPersistence", .product(name: "GRDB", package: "GRDB.swift")],
            path: "Packages/BAMDatasets/Tests/BAMDatasetsTests",
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "BAMModelCatalogTests", dependencies: ["BAMModelCatalog", "BAMModels", "BAMCore"], path: "Packages/BAMModelCatalog/Tests/BAMModelCatalogTests"),
        .testTarget(name: "BAMConsentTests", dependencies: ["BAMConsent", "BAMModels", "BAMCore", "BAMPersistence", .product(name: "GRDB", package: "GRDB.swift")], path: "Packages/BAMConsent/Tests/BAMConsentTests"),
        .testTarget(name: "BAMJobsTests", dependencies: ["BAMJobs", "BAMModels", "BAMCore", "BAMPersistence", .product(name: "GRDB", package: "GRDB.swift")], path: "Packages/BAMJobs/Tests/BAMJobsTests"),
        .testTarget(name: "BAMRunnersTests", dependencies: ["BAMRunners", "BAMJobs", "BAMModels", "BAMCore"], path: "Packages/BAMRunners/Tests/BAMRunnersTests", resources: [.copy("Fixtures")]),
        .testTarget(name: "BAMRunnersMLXTests", dependencies: ["BAMRunnersMLX", "BAMCore", "BAMModels", "BAMJobs", "BAMRunners", "BAMDatasets", "BAMModelCatalog"], path: "Packages/BAMRunnersMLX/Tests/BAMRunnersMLXTests"),
        .testTarget(name: "BAMRunnersVoiceTests", dependencies: ["BAMRunnersVoice", "BAMCore", "BAMModels", "BAMPersistence", "BAMJobs", "BAMConsent", .product(name: "GRDB", package: "GRDB.swift")], path: "Packages/BAMRunnersVoice/Tests/BAMRunnersVoiceTests"),
        .testTarget(name: "BAMInferenceTests", dependencies: ["BAMInference", "BAMCore", "BAMModels"], path: "Packages/BAMInference/Tests/BAMInferenceTests"),
        .testTarget(
            name: "BAMPersonasTests",
            dependencies: [
                "BAMPersonas",
                "BAMCore",
                "BAMModels",
                "BAMPersistence",
                "BAMConsent",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Packages/BAMPersonas/Tests/BAMPersonasTests"
        ),
    ]
)
