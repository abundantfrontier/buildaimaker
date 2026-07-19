import BAMCore
import XCTest

@testable import BAMRunnersMLX

final class HardwareFitGateTests: XCTestCase {
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
}
