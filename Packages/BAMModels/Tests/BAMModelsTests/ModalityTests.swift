import XCTest
import BAMModels

final class ModalityTests: XCTestCase {
    func testJobModalityCases() {
        XCTAssertEqual(JobModality.allCases.map(\.rawValue), [
            "llm", "voiceClone", "voiceFinetune", "foundationAdapter",
        ])
        XCTAssertEqual(Modality.llm, JobModality.llm)
        XCTAssertEqual(JobModality.foundationAdapter.rawValue, "foundationAdapter")
    }

    func testDatasetModalityCases() {
        XCTAssertEqual(DatasetModality.allCases.map(\.rawValue), ["text", "audio"])
    }

    func testModalityMapping() {
        XCTAssertEqual(ModalityMapping.eligibleJobModalities(for: .text), [.llm, .foundationAdapter])
        XCTAssertEqual(
            ModalityMapping.eligibleJobModalities(for: .audio),
            [.voiceClone, .voiceFinetune]
        )
        XCTAssertTrue(ModalityMapping.isCompatible(dataset: .text, job: .llm))
        XCTAssertTrue(ModalityMapping.isCompatible(dataset: .text, job: .foundationAdapter))
        XCTAssertFalse(ModalityMapping.isCompatible(dataset: .text, job: .voiceClone))
        XCTAssertTrue(ModalityMapping.isCompatible(dataset: .audio, job: .voiceClone))
        XCTAssertTrue(ModalityMapping.isCompatible(dataset: .audio, job: .voiceFinetune))
        XCTAssertFalse(ModalityMapping.isCompatible(dataset: .audio, job: .llm))
        XCTAssertFalse(ModalityMapping.isCompatible(dataset: .audio, job: .foundationAdapter))
    }

    func testFoundationAdapterJobSpecFactory() {
        let spec = JobSpec.foundationAdapter(id: "j1", datasetVersionId: "dv1")
        XCTAssertEqual(spec.modality, .foundationAdapter)
        XCTAssertEqual(spec.method, "foundation_adapter")
        XCTAssertEqual(spec.baseModelId, "apple-foundation")
        XCTAssertEqual(spec.datasetVersionId, "dv1")
    }

    func testJobStatusHasNoPause() {
        let raw = JobStatus.allCases.map(\.rawValue)
        XCTAssertFalse(raw.contains("paused"))
        XCTAssertFalse(raw.contains("pausing"))
        XCTAssertTrue(raw.contains("interrupted"))
    }
}
