import XCTest
@testable import BAMJobs

final class HeartbeatTests: XCTestCase {
    func testInMemoryStaleDetection() throws {
        let monitor = HeartbeatMonitor()
        // Untouched: grace for live runs; requireTouch for recovery checks.
        XCTAssertFalse(monitor.isStale(timeout: 1))
        XCTAssertTrue(monitor.isStale(timeout: 1, requireTouch: true))

        monitor.touch(at: Date())
        XCTAssertFalse(monitor.isStale(timeout: 10, now: Date()))
        XCTAssertTrue(monitor.isStale(timeout: 0.01, now: Date().addingTimeInterval(1)))
    }

    func testFileHeartbeatRoundTrip() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("bam-hb-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let monitor = HeartbeatMonitor(fileURL: tmp)
        monitor.touch(rssBytes: 99, gpuUtil: 0.5, cpuUtil: 0.2)

        let loaded = try HeartbeatMonitor.readFile(at: tmp)
        XCTAssertEqual(loaded?.rssBytes, 99)
        XCTAssertEqual(loaded?.gpuUtil, 0.5)
        XCTAssertFalse(try HeartbeatMonitor.isFileStale(at: tmp, timeout: 30))
    }

    func testFileStaleByMtime() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("bam-hb-stale-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let monitor = HeartbeatMonitor(fileURL: tmp)
        monitor.touch()
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-100)],
            ofItemAtPath: tmp.path
        )
        XCTAssertTrue(try HeartbeatMonitor.isFileStale(at: tmp, timeout: 20))
    }
}
