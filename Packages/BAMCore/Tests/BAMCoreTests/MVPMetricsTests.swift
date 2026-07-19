import XCTest
import BAMCore

final class MVPMetricsTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var store: MVPMetricsStore!

    override func setUpWithError() throws {
        suiteName = "bam.test.metrics.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        store = MVPMetricsStore(defaults: defaults)
    }

    override func tearDownWithError() throws {
        if let suiteName {
            defaults?.removePersistentDomain(forName: suiteName)
        }
        defaults = nil
        store = nil
        suiteName = nil
    }

    func testIncrementAndSnapshot() {
        XCTAssertEqual(store.count(for: .trainCompleted), 0)
        XCTAssertEqual(store.increment(.trainCompleted), 1)
        XCTAssertEqual(store.increment(.trainCompleted), 2)
        XCTAssertEqual(store.increment(.jobCancelled, by: 3), 3)
        XCTAssertEqual(store.increment(.playgroundReply), 1)
        XCTAssertEqual(store.increment(.datasetImportOK), 1)
        XCTAssertEqual(store.increment(.datasetImportRejected), 1)

        let snap = store.snapshot()
        XCTAssertEqual(snap.count(for: .trainCompleted), 2)
        XCTAssertEqual(snap.count(for: .jobCancelled), 3)
        XCTAssertEqual(snap.count(for: .playgroundReply), 1)
        XCTAssertEqual(snap.count(for: .datasetImportOK), 1)
        XCTAssertEqual(snap.count(for: .datasetImportRejected), 1)
        XCTAssertEqual(snap.count(for: .networkCallTrainPlay), 0)
        XCTAssertTrue(snap.m5Passes)
    }

    func testM5FailsWhenNetworkRecorded() {
        store.increment(.networkCallTrainPlay)
        let snap = store.snapshot()
        XCTAssertEqual(snap.m5NetworkCallsDuringTrainPlay, 1)
        XCTAssertFalse(snap.m5Passes)
    }

    func testResetAll() {
        store.increment(.trainCompleted)
        store.increment(.playgroundReply)
        store.resetAll()
        for event in MVPMetricEvent.allCases {
            XCTAssertEqual(store.count(for: event), 0, event.rawValue)
        }
    }

    func testMetricIdsAndKeys() {
        XCTAssertEqual(MVPMetricEvent.trainCompleted.metricId, "M1")
        XCTAssertEqual(MVPMetricEvent.jobCancelled.metricId, "M2")
        XCTAssertEqual(MVPMetricEvent.playgroundReply.metricId, "M3")
        XCTAssertEqual(MVPMetricEvent.datasetImportOK.metricId, "M4")
        XCTAssertEqual(MVPMetricEvent.datasetImportRejected.metricId, "M4")
        XCTAssertEqual(MVPMetricEvent.networkCallTrainPlay.metricId, "M5")
        for event in MVPMetricEvent.allCases {
            XCTAssertTrue(event.defaultsKey.hasPrefix("bam.metrics."))
            XCTAssertFalse(event.displayName.isEmpty)
        }
    }

    func testSetCountClampsNegative() {
        store.setCount(-5, for: .trainCompleted)
        XCTAssertEqual(store.count(for: .trainCompleted), 0)
        store.setCount(7, for: .trainCompleted)
        XCTAssertEqual(store.count(for: .trainCompleted), 7)
    }
}
