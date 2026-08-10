import BAMCore
import BAMModels
import XCTest

@testable import BAMRunnersMLX

final class HardwareFitGateTests: XCTestCase {

    // MARK: - K16 gate

    func testRefuseBelowMinimum() {
        let result = HardwareFitGate.check(availableUnifiedGB: 8)
        XCTAssertFalse(result.allowed)
        XCTAssertEqual(result.minimumRequiredGB, AppIdentity.minimumUnifiedMemoryGB)
        XCTAssertNotNil(result.message)
    }

    func testAllowAtMinimum() {
        let result = HardwareFitGate.check(availableUnifiedGB: 16)
        XCTAssertTrue(result.allowed)
        XCTAssertNil(result.message)
    }

    func testRefuseIfUnsupportedThrows() {
        XCTAssertThrowsError(
            try HardwareFitGate.refuseIfUnsupported(availableUnifiedGB: 12)
        ) { error in
            let bam = error as? BAMError
            XCTAssertEqual(bam?.code, .preflightMemory)
        }
    }

    func testRefuseIfUnsupportedPasses() throws {
        try HardwareFitGate.refuseIfUnsupported(availableUnifiedGB: 32)
    }

    func testProbeReturnsNonNegative() {
        XCTAssertGreaterThanOrEqual(HardwareFitGate.probeAvailableUnifiedGB(), 0)
    }

    // MARK: - Peak formula unit checks

    func testPeakFormulaBaseComponents() {
        // 1.5B @ 4-bit, rank 16, seq 2048, batch 1, accum 4
        let parts = HardwareFitGate.estimatePeakGB(
            paramCountB: 1.5,
            quantBits: 4,
            loraRank: 16,
            maxSeqLen: 2048,
            batchSize: 1,
            gradAccum: 4
        )
        // base = 1.5 * (4/8) = 0.75 GB
        XCTAssertEqual(parts.baseGB, 0.75, accuracy: 1e-9)
        // lora = 1.5 * (16/16) * 0.02 = 0.03 → clamp to 0.05
        XCTAssertEqual(parts.loraGB, 0.05, accuracy: 1e-9)
        // optim = 2 * lora = 0.10
        XCTAssertEqual(parts.optimGB, 0.10, accuracy: 1e-9)
        // activ = (2048/2048)*1*4*0.5*1.5 = 3.0
        XCTAssertEqual(parts.activGB, 3.0, accuracy: 1e-9)
        // peak = 0.75 + 0.05 + 0.10 + 3.0 + 1.5 = 5.4
        XCTAssertEqual(parts.peakGB, 5.4, accuracy: 1e-9)
    }

    func testLoraBytesScalesWithRankWithoutClamp() {
        // Large enough that raw lora > 0.05 GB: 3B * (32/16) * 0.02 = 0.12
        let parts = HardwareFitGate.estimatePeakGB(
            paramCountB: 3.0,
            quantBits: 4,
            loraRank: 32,
            maxSeqLen: 2048,
            batchSize: 1,
            gradAccum: 1
        )
        XCTAssertEqual(parts.loraGB, 0.12, accuracy: 1e-9)
        XCTAssertEqual(parts.optimGB, 0.24, accuracy: 1e-9)
    }

    func testQuantBitsAffectsBaseOnly() {
        let q4 = HardwareFitGate.estimatePeakGB(
            paramCountB: 1.0, quantBits: 4, loraRank: 16,
            maxSeqLen: 2048, batchSize: 1, gradAccum: 1
        )
        let q8 = HardwareFitGate.estimatePeakGB(
            paramCountB: 1.0, quantBits: 8, loraRank: 16,
            maxSeqLen: 2048, batchSize: 1, gradAccum: 1
        )
        XCTAssertEqual(q4.baseGB, 0.5, accuracy: 1e-9)
        XCTAssertEqual(q8.baseGB, 1.0, accuracy: 1e-9)
        XCTAssertEqual(q4.loraGB, q8.loraGB, accuracy: 1e-9)
        XCTAssertEqual(q4.activGB, q8.activGB, accuracy: 1e-9)
        XCTAssertGreaterThan(q8.peakGB, q4.peakGB)
    }

    // MARK: - Table fixtures (param, quant, rank, seq → status)

    /// Table-driven fixtures: catalog-like size classes × host RAM.
    struct FitFixture {
        let name: String
        let paramCountB: Double
        let quantBits: Int
        let loraRank: Int
        let maxSeqLen: Int
        let batchSize: Int
        let gradAccum: Int
        let osReserveGB: Double
        let availableUnifiedGB: Double
        let expectedStatus: HardwareFitGate.FitStatus
        /// Optional expected peak (when formula is asserted).
        let expectedPeakGB: Double?
    }

    static let tableFixtures: [FitFixture] = [
        // K16 refuse regardless of tiny peak.
        FitFixture(
            name: "k16_8gb_host",
            paramCountB: 0.5, quantBits: 4, loraRank: 8, maxSeqLen: 1024,
            batchSize: 1, gradAccum: 1, osReserveGB: 6, availableUnifiedGB: 8,
            expectedStatus: .refuse, expectedPeakGB: nil
        ),
        // Tiny fixture model on 16 GB → ok.
        FitFixture(
            name: "fixture_tiny_16gb",
            paramCountB: 0.001, quantBits: 16, loraRank: 16, maxSeqLen: 2048,
            batchSize: 1, gradAccum: 4, osReserveGB: 6, availableUnifiedGB: 16,
            expectedStatus: .ok, expectedPeakGB: nil
        ),
        // 0.5B 4-bit defaults on 16 GB → ok (small peak + 6 reserve).
        FitFixture(
            name: "qwen_0_5b_defaults_16gb",
            paramCountB: 0.5, quantBits: 4, loraRank: 16, maxSeqLen: 2048,
            batchSize: 1, gradAccum: 4, osReserveGB: 6, availableUnifiedGB: 16,
            expectedStatus: .ok, expectedPeakGB: nil
        ),
        // 1.5B 4-bit defaults: peak 5.4 + 6 = 11.4 of 16 → ok (headroom > 15%).
        FitFixture(
            name: "qwen_1_5b_defaults_16gb",
            paramCountB: 1.5, quantBits: 4, loraRank: 16, maxSeqLen: 2048,
            batchSize: 1, gradAccum: 4, osReserveGB: 6, availableUnifiedGB: 16,
            expectedStatus: .ok, expectedPeakGB: 5.4
        ),
        // 3B 4-bit aggressive: peak large enough to refuse on 16 GB.
        // base=1.5, lora=max(0.05, 3*0.02)=0.06, optim=0.12, activ=(1)*1*4*0.5*3=6, +1.5
        // peak=1.5+0.06+0.12+6+1.5=9.18; required=15.18 of 16 → within 15% → warning
        FitFixture(
            name: "qwen_3b_defaults_16gb_warning",
            paramCountB: 3.0, quantBits: 4, loraRank: 16, maxSeqLen: 2048,
            batchSize: 1, gradAccum: 4, osReserveGB: 6, availableUnifiedGB: 16,
            expectedStatus: .warning, expectedPeakGB: 9.18
        ),
        // Push 3B over the edge: higher seq/batch.
        // activ=(4096/2048)*2*8*0.5*3 = 2*2*8*0.5*3 = 48; peak huge → refuse
        FitFixture(
            name: "qwen_3b_heavy_16gb_refuse",
            paramCountB: 3.0, quantBits: 4, loraRank: 32, maxSeqLen: 4096,
            batchSize: 2, gradAccum: 8, osReserveGB: 6, availableUnifiedGB: 16,
            expectedStatus: .refuse, expectedPeakGB: nil
        ),
        // Comfortable 32 GB host for 3B.
        FitFixture(
            name: "qwen_3b_defaults_32gb_ok",
            paramCountB: 3.0, quantBits: 4, loraRank: 16, maxSeqLen: 2048,
            batchSize: 1, gradAccum: 4, osReserveGB: 6, availableUnifiedGB: 32,
            expectedStatus: .ok, expectedPeakGB: 9.18
        ),
        // 16-bit 1.5B: base = 1.5 * 2 = 3.0; same lora clamp/activ as 4-bit.
        // peak = 3.0 + 0.05 + 0.10 + 3.0 + 1.5 = 7.65; req=13.65 of 16
        // 13.65/16 ≈ 0.853 → within 15% band → warning
        FitFixture(
            name: "qwen_1_5b_fp16_16gb",
            paramCountB: 1.5, quantBits: 16, loraRank: 16, maxSeqLen: 2048,
            batchSize: 1, gradAccum: 4, osReserveGB: 6, availableUnifiedGB: 16,
            expectedStatus: .warning, expectedPeakGB: 7.65
        ),
        // Exactly at warning band edge: required == available * 0.85 → warning.
        // Craft: available=20, reserve=0, need peak=17 (85% of 20).
        // Easier: available=10 is K16 refuse; use available=20, osReserve=0.
        // Use synthetic: we'll check via estimate with known required.
        FitFixture(
            name: "warning_band_15pct",
            paramCountB: 1.5, quantBits: 4, loraRank: 16, maxSeqLen: 2048,
            batchSize: 1, gradAccum: 4, osReserveGB: 6, availableUnifiedGB: 12.0,
            // required 11.4 of 12 → 11.4/12=0.95 → within 15% → warning
            // BUT available 12 < 16 → K16 refuse takes precedence
            expectedStatus: .refuse, expectedPeakGB: 5.4
        ),
        // Soft warning without K16: 24 GB host, required close to available.
        // peak 5.4 + reserve 14 = 19.4 of 20 → warning (20 >= 16 K16 ok)
        FitFixture(
            name: "soft_warning_near_limit",
            paramCountB: 1.5, quantBits: 4, loraRank: 16, maxSeqLen: 2048,
            batchSize: 1, gradAccum: 4, osReserveGB: 14, availableUnifiedGB: 20,
            expectedStatus: .warning, expectedPeakGB: 5.4
        ),
        // Clear refuse from estimate only (not K16): huge model on 16 GB.
        FitFixture(
            name: "7b_fp16_refuse_16gb",
            paramCountB: 7.0, quantBits: 16, loraRank: 16, maxSeqLen: 2048,
            batchSize: 1, gradAccum: 4, osReserveGB: 6, availableUnifiedGB: 16,
            expectedStatus: .refuse, expectedPeakGB: nil
        ),
    ]

    func testTableFixtures() {
        for fixture in Self.tableFixtures {
            let input = HardwareFitGate.EstimateInput(
                paramCountB: fixture.paramCountB,
                quantBits: fixture.quantBits,
                loraRank: fixture.loraRank,
                maxSeqLen: fixture.maxSeqLen,
                batchSize: fixture.batchSize,
                gradAccum: fixture.gradAccum,
                osReserveGB: fixture.osReserveGB,
                availableUnifiedGB: fixture.availableUnifiedGB
            )
            let est = HardwareFitGate.estimate(input)
            XCTAssertEqual(
                est.status,
                fixture.expectedStatus,
                "Fixture \(fixture.name): expected \(fixture.expectedStatus), got \(est.status) "
                    + "(peak=\(est.peakGB) required=\(est.requiredGB) avail=\(est.availableUnifiedGB))"
            )
            if let expectedPeak = fixture.expectedPeakGB {
                XCTAssertEqual(
                    est.peakGB,
                    expectedPeak,
                    accuracy: 1e-6,
                    "Fixture \(fixture.name) peak"
                )
            }
            if est.status == .refuse {
                XCTAssertFalse(est.allowed)
                XCTAssertNotNil(est.message)
            }
            if est.status == .warning {
                XCTAssertTrue(est.allowed)
                XCTAssertNotNil(est.message)
            }
            if est.status == .ok {
                XCTAssertTrue(est.allowed)
            }
        }
    }

    func testRefuseIfUnfitThrowsOnOversize() {
        let input = HardwareFitGate.EstimateInput(
            paramCountB: 7.0,
            quantBits: 16,
            loraRank: 32,
            maxSeqLen: 4096,
            batchSize: 2,
            gradAccum: 8,
            osReserveGB: 6,
            availableUnifiedGB: 16
        )
        XCTAssertThrowsError(try HardwareFitGate.refuseIfUnfit(input)) { error in
            XCTAssertEqual((error as? BAMError)?.code, .preflightMemory)
        }
    }

    func testRefuseIfUnfitPassesComfortable() throws {
        let input = HardwareFitGate.EstimateInput(
            paramCountB: 0.5,
            quantBits: 4,
            loraRank: 8,
            maxSeqLen: 1024,
            batchSize: 1,
            gradAccum: 1,
            osReserveGB: 6,
            availableUnifiedGB: 32
        )
        try HardwareFitGate.refuseIfUnfit(input)
    }

    func testSuggestionsIncludeRankAndSeq() {
        let input = HardwareFitGate.EstimateInput(
            paramCountB: 3.0,
            quantBits: 4,
            loraRank: 16,
            maxSeqLen: 2048,
            batchSize: 2,
            gradAccum: 4,
            availableUnifiedGB: 16
        )
        let suggestions = HardwareFitGate.makeSuggestions(input: input)
        XCTAssertTrue(suggestions.contains(where: { $0.lowercased().contains("rank") }))
        XCTAssertTrue(suggestions.contains(where: { $0.lowercased().contains("seq") }))
        XCTAssertTrue(suggestions.contains(where: { $0.lowercased().contains("batch") }))
    }

    func testEstimateFromHyperparameters() {
        let hp = LLMHyperparameters(
            loraRank: 8,
            batchSize: 1,
            gradAccum: 2,
            maxSeqLen: 1024
        )
        let input = HardwareFitGate.EstimateInput(
            paramCountB: 1.5,
            quantBits: 4,
            hyperparameters: hp,
            availableUnifiedGB: 32
        )
        XCTAssertEqual(input.loraRank, 8)
        XCTAssertEqual(input.maxSeqLen, 1024)
        XCTAssertEqual(input.gradAccum, 2)
        let est = HardwareFitGate.estimate(input)
        XCTAssertEqual(est.status, .ok)
    }

    func testApproximateLabelCopy() {
        XCTAssertTrue(HardwareFitGate.approximateLabel.lowercased().contains("approximate"))
    }

    func testWarningBandBoundary() {
        // required exactly at 85% of available → warning
        // peak 5.4 → choose reserve so required = 0.85 * available
        // available=20, 0.85*20=17 → reserve = 17 - 5.4 = 11.6
        let input = HardwareFitGate.EstimateInput(
            paramCountB: 1.5,
            quantBits: 4,
            loraRank: 16,
            maxSeqLen: 2048,
            batchSize: 1,
            gradAccum: 4,
            osReserveGB: 11.6,
            availableUnifiedGB: 20
        )
        let est = HardwareFitGate.estimate(input)
        XCTAssertEqual(est.status, .warning)
        XCTAssertEqual(est.requiredGB, 17.0, accuracy: 1e-6)
    }

    func testJustBelowWarningBandIsOk() {
        // required slightly under 85%: available=20, threshold=17; required=16.9
        let input = HardwareFitGate.EstimateInput(
            paramCountB: 1.5,
            quantBits: 4,
            loraRank: 16,
            maxSeqLen: 2048,
            batchSize: 1,
            gradAccum: 4,
            osReserveGB: 11.5,
            availableUnifiedGB: 20
        )
        let est = HardwareFitGate.estimate(input)
        XCTAssertEqual(est.status, .ok)
    }
}
