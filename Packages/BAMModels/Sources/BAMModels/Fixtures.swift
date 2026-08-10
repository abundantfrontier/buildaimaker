import Foundation

/// Frozen dual-modality fixtures for Codable round-trips and CI (no GPU).
public enum DomainFixtures: Sendable {
    // MARK: - Stable IDs (UUID-shaped, fixed for golden vectors)

    public static let llmJobId = "11111111-1111-4111-8111-111111111111"
    public static let voiceCloneJobId = "22222222-2222-4222-8222-222222222222"
    public static let baseModelId = "33333333-3333-4333-8333-333333333333"
    public static let datasetVersionId = "44444444-4444-4444-8444-444444444444"
    public static let consentRecordId = "00000000-0000-4000-8000-000000000001"
    public static let audioDatasetId = "55555555-5555-4555-8555-555555555555"
    public static let textDatasetId = "66666666-6666-4666-8666-666666666666"
    public static let personaId = "77777777-7777-4777-8777-777777777777"
    public static let voiceProfileId = "88888888-8888-4888-8888-888888888888"
    public static let adapterArtifactId = "99999999-9999-4999-8999-999999999999"

    /// Golden consent hash input timestamps / labels.
    public static let goldenCreatedAt = "2026-07-18T12:00:00Z"
    public static let goldenAppVersion = "0.1.0"

    /// Normative golden SHA-256 (lowercase hex) for `goldenConsentRecord` hash input.
    ///
    /// Canonical JSON (no jurisdictionNote):
    /// `{"appVersion":"0.1.0","attestedAt":"2026-07-18T12:00:00Z","attestorUserLabel":"test-user","createdAt":"2026-07-18T12:00:00Z","id":"00000000-0000-4000-8000-000000000001","retention":"until_user_deletes","schemaVersion":1,"scope":"personal_use","statements":["I have the right to use this voice for the selected scope.","I will not use this to commit fraud or illegal impersonation."],"subjectDisplayName":"Test Subject","subjectType":"self"}`
    public static let goldenConsentContentHash =
        "a20497efdc463ecfe6a6f9f135c11c40ee61d6cadaf5435bbbaeafb2815b6895"

    // MARK: - Consent

    /// Golden `ConsentRecord` used to pin canonical contentHash in CI.
    public static var goldenConsentRecord: ConsentRecord {
        ConsentRecord(
            id: consentRecordId,
            schemaVersion: ConsentRecord.schemaVersionV1,
            createdAt: goldenCreatedAt,
            subjectType: .self_,
            subjectDisplayName: "Test Subject",
            attestorUserLabel: "test-user",
            scope: .personalUse,
            statements: [
                "I have the right to use this voice for the selected scope.",
                "I will not use this to commit fraud or illegal impersonation.",
            ],
            attestedAt: goldenCreatedAt,
            appVersion: goldenAppVersion,
            jurisdictionNote: nil,
            retention: ConsentRecord.defaultRetention,
            contentHash: goldenConsentContentHash
        )
    }

    // MARK: - JobSpec

    public static var llmJobSpec: JobSpec {
        .llm(
            id: llmJobId,
            baseModelId: baseModelId,
            baseModelSourceKey: "mlx-community/Qwen2.5-1.5B-Instruct-4bit",
            datasetVersionId: datasetVersionId
        )
    }

    public static var voiceCloneJobSpec: JobSpec {
        .voiceClone(
            id: voiceCloneJobId,
            consentRecordId: consentRecordId,
            consentContentHash: "sha256:\(goldenConsentContentHash)"
        )
    }

    // MARK: - JobPaths

    public static let fixtureLibraryRoot = "/tmp/BuildAIMaker-fixture"
    public static let fixtureJobDir = "/tmp/BuildAIMaker-fixture/jobs/\(llmJobId)"

    public static var llmJobPaths: JobPaths {
        JobPaths(
            jobDir: fixtureJobDir,
            libraryRoot: fixtureLibraryRoot,
            datasetPath: "\(fixtureLibraryRoot)/datasets/\(textDatasetId)/normalized",
            baseModelPath: "\(fixtureLibraryRoot)/models/base/\(baseModelId)",
            referenceAudioPath: nil,
            outputPath: "\(fixtureJobDir)/artifacts",
            checkpointPath: "\(fixtureJobDir)/checkpoints",
            cancelFlagPath: "\(fixtureJobDir)/cancel.flag",
            logPath: "\(fixtureJobDir)/logs"
        )
    }

    public static var voiceCloneJobPaths: JobPaths {
        let jobDir = "\(fixtureLibraryRoot)/jobs/\(voiceCloneJobId)"
        return JobPaths(
            jobDir: jobDir,
            libraryRoot: fixtureLibraryRoot,
            datasetPath: nil,
            baseModelPath: nil,
            referenceAudioPath: "\(fixtureLibraryRoot)/voices/staging/\(voiceProfileId)/ref.wav",
            outputPath: "\(jobDir)/artifacts",
            checkpointPath: "\(jobDir)/checkpoints",
            cancelFlagPath: "\(jobDir)/cancel.flag",
            logPath: "\(jobDir)/logs"
        )
    }

    // MARK: - Datasets

    public static var textDataset: DatasetRecord {
        DatasetRecord(
            id: textDatasetId,
            name: "ShareGPT fixture",
            modality: .text,
            rootPath: "\(fixtureLibraryRoot)/datasets/\(textDatasetId)",
            importMode: .copy,
            status: .ready,
            createdAt: goldenCreatedAt
        )
    }

    /// Audio dataset fixture (`DatasetModality.audio`) for dual-modality CI.
    public static var audioDataset: DatasetRecord {
        DatasetRecord(
            id: audioDatasetId,
            name: "Voice clone refs",
            modality: .audio,
            rootPath: "\(fixtureLibraryRoot)/datasets/\(audioDatasetId)",
            importMode: .copy,
            status: .ready,
            createdAt: goldenCreatedAt
        )
    }

    // MARK: - Persona

    public static var fullPersona: PersonaDocument {
        PersonaDocument(
            id: personaId,
            name: "Socrates",
            version: "1.0.0",
            llm: PersonaLLMComponents(
                baseModelId: baseModelId,
                adapterArtifactId: adapterArtifactId
            ),
            voice: PersonaVoiceComponents(voiceProfileId: voiceProfileId),
            systemPrompt: "You are Socrates. Answer with questions.",
            sampling: PersonaSampling(temperature: 0.7, topP: 0.9, maxTokens: 512)
        )
    }

    public static var textOnlyPersona: PersonaDocument {
        PersonaDocument(
            id: personaId,
            name: "Text Socrates",
            version: "1.0.0",
            llm: PersonaLLMComponents(baseModelId: baseModelId, adapterArtifactId: nil),
            voice: nil,
            systemPrompt: "You are Socrates."
        )
    }

    public static var voicePreviewPersona: PersonaDocument {
        PersonaDocument(
            id: personaId,
            name: "Voice only",
            version: "1.0.0",
            llm: nil,
            voice: PersonaVoiceComponents(voiceProfileId: voiceProfileId)
        )
    }
}
