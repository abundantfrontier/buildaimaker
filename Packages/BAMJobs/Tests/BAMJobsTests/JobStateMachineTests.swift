import XCTest
import BAMModels
@testable import BAMJobs
import BAMCore

final class JobStateMachineTests: XCTestCase {
    func testHappyPathTransitions() throws {
        var status = JobStatus.draft
        for next in [JobStatus.queued, .preparing, .running, .succeeded] {
            XCTAssertTrue(JobStateMachine.canTransition(from: status, to: next))
            status = try JobStateMachine.transition(from: status, to: next)
        }
        XCTAssertTrue(JobStateMachine.isTerminal(status))
    }

    func testNoPauseState() {
        // Pause is intentionally not a JobStatus case and has no transitions.
        let all = JobStatus.allCases.map(\.rawValue)
        XCTAssertFalse(all.contains("paused"))
        XCTAssertFalse(all.contains("pause"))
        for status in JobStatus.allCases {
            XCTAssertFalse(JobStateMachine.canTransition(from: status, to: status),
                           "No self-transition for \(status)")
        }
    }

    func testTerminalStatesRejectFurtherTransitions() {
        for terminal in JobStateMachine.terminalStatuses {
            for next in JobStatus.allCases {
                XCTAssertFalse(
                    JobStateMachine.canTransition(from: terminal, to: next),
                    "\(terminal) → \(next) should be illegal"
                )
            }
        }
    }

    func testCancelFromQueuedAndRunning() throws {
        XCTAssertTrue(JobStateMachine.canTransition(from: .queued, to: .cancelled))
        XCTAssertTrue(JobStateMachine.canTransition(from: .running, to: .cancelled))
        XCTAssertTrue(JobStateMachine.canTransition(from: .preparing, to: .cancelled))
        XCTAssertTrue(JobStateMachine.canTransition(from: .draft, to: .cancelled))
        _ = try JobStateMachine.transition(from: .running, to: .cancelled)
    }

    func testInterruptedCanRequeue() throws {
        XCTAssertTrue(JobStateMachine.canTransition(from: .running, to: .interrupted))
        XCTAssertTrue(JobStateMachine.canTransition(from: .interrupted, to: .queued))
        _ = try JobStateMachine.transition(from: .interrupted, to: .queued)
    }

    func testIllegalTransitionThrows() {
        XCTAssertThrowsError(try JobStateMachine.transition(from: .succeeded, to: .running)) { error in
            guard let bam = error as? BAMError else {
                return XCTFail("expected BAMError")
            }
            XCTAssertEqual(bam.code, .schemaInvalid)
        }
        XCTAssertThrowsError(try JobStateMachine.transition(from: .draft, to: .running))
        XCTAssertThrowsError(try JobStateMachine.transition(from: .queued, to: .succeeded))
    }

    func testActiveStatuses() {
        XCTAssertTrue(JobStateMachine.isActive(.queued))
        XCTAssertTrue(JobStateMachine.isActive(.preparing))
        XCTAssertTrue(JobStateMachine.isActive(.running))
        XCTAssertFalse(JobStateMachine.isActive(.succeeded))
        XCTAssertFalse(JobStateMachine.isActive(.draft))
    }
}
