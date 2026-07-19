import XCTest
import BAMModels

final class JobSpecFixturesTests: XCTestCase {
    private var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }

    private var decoder: JSONDecoder { JSONDecoder() }

    func testLLMJobSpecCodableRoundTrip() throws {
        let spec = DomainFixtures.llmJobSpec
        XCTAssertEqual(spec.modality, .llm)
        XCTAssertEqual(spec.v, 1)
        XCTAssertEqual(spec.method, "lora")
        XCTAssertNotNil(spec.hyperparameters)
        XCTAssertNil(spec.engineId)
        XCTAssertNil(spec.consentRecordId)

        let data = try encoder.encode(spec)
        let decoded = try decoder.decode(JobSpec.self, from: data)
        XCTAssertEqual(decoded, spec)

        // Ensure no absolute path keys on LLM JobSpec JSON.
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertNil(obj["referenceAudioPath"])
        XCTAssertNil(obj["datasetPath"])
        XCTAssertNil(obj["baseModelPath"])
    }

    func testVoiceCloneJobSpecCodableRoundTrip() throws {
        let spec = DomainFixtures.voiceCloneJobSpec
        XCTAssertEqual(spec.modality, .voiceClone)
        XCTAssertEqual(spec.engineId, "f5-tts")
        XCTAssertEqual(spec.consentRecordId, DomainFixtures.consentRecordId)
        XCTAssertNil(spec.baseModelId)
        XCTAssertNil(spec.datasetVersionId)
        XCTAssertNil(spec.hyperparameters)

        let data = try encoder.encode(spec)
        let decoded = try decoder.decode(JobSpec.self, from: data)
        XCTAssertEqual(decoded, spec)

        // referenceAudioPath must not appear on JobSpec.
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertNil(obj["referenceAudioPath"])
    }

    func testJobPathsReferenceAudioOnlyOnPaths() throws {
        let llmPaths = DomainFixtures.llmJobPaths
        XCTAssertNil(llmPaths.referenceAudioPath)
        XCTAssertNotNil(llmPaths.datasetPath)
        XCTAssertNotNil(llmPaths.baseModelPath)

        let voicePaths = DomainFixtures.voiceCloneJobPaths
        XCTAssertNotNil(voicePaths.referenceAudioPath)
        XCTAssertNil(voicePaths.datasetPath)

        let data = try encoder.encode(voicePaths)
        let decoded = try decoder.decode(JobPaths.self, from: data)
        XCTAssertEqual(decoded, voicePaths)
        XCTAssertTrue(decoded.referenceAudioPath!.hasSuffix("ref.wav"))
    }

    func testAudioDatasetFixture() throws {
        let audio = DomainFixtures.audioDataset
        XCTAssertEqual(audio.modality, .audio)
        XCTAssertTrue(ModalityMapping.isCompatible(dataset: audio.modality, job: .voiceClone))

        let text = DomainFixtures.textDataset
        XCTAssertEqual(text.modality, .text)

        let data = try encoder.encode(audio)
        let decoded = try decoder.decode(DatasetRecord.self, from: data)
        XCTAssertEqual(decoded, audio)
    }

    func testLLMJobSpecJSONFixtureShape() throws {
        // Pin key fields present in design-doc sample JSON.
        let data = try encoder.encode(DomainFixtures.llmJobSpec)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(obj["v"] as? Int, 1)
        XCTAssertEqual(obj["modality"] as? String, "llm")
        XCTAssertEqual(obj["chatTemplateId"] as? String, "qwen2.5-instruct")
        XCTAssertNotNil(obj["hyperparameters"] as? [String: Any])
        XCTAssertNotNil(obj["resources"] as? [String: Any])
        XCTAssertNotNil(obj["outputs"] as? [String: Any])
    }

    func testVoiceCloneJobSpecJSONFixtureShape() throws {
        let data = try encoder.encode(DomainFixtures.voiceCloneJobSpec)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(obj["modality"] as? String, "voiceClone")
        XCTAssertEqual(obj["engineId"] as? String, "f5-tts")
        XCTAssertNotNil(obj["consentContentHash"] as? String)
        XCTAssertNotNil(obj["sampleText"] as? String)
    }
}
