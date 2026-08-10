import XCTest
import BAMCore

final class OnboardingChecklistTests: XCTestCase {
    func testEmptyProbe_allIncomplete() {
        let state = OnboardingChecklistEvaluator.evaluate(probe: OnboardingLibraryProbe())
        XCTAssertFalse(state.isFullyComplete)
        XCTAssertTrue(state.shouldShow)
        XCTAssertEqual(state.completedCount, 0)
        XCTAssertEqual(state.totalCount, 4)
        XCTAssertEqual(state.progress, 0, accuracy: 0.001)
        for step in OnboardingStep.allCases {
            XCTAssertFalse(state.isComplete(step))
        }
        XCTAssertEqual(state.remaining, OnboardingStep.allCases)
    }

    func testProbeMarksStepsIndependently() {
        let probe = OnboardingLibraryProbe(
            hasReadyDataset: true,
            hasLocalBaseModel: true,
            hasDryRunOrTrain: false,
            hasPlaygroundChat: false
        )
        let state = OnboardingChecklistEvaluator.evaluate(probe: probe)
        XCTAssertTrue(state.isComplete(.importDataset))
        XCTAssertTrue(state.isComplete(.installFixture))
        XCTAssertFalse(state.isComplete(.dryRunOrTrain))
        XCTAssertFalse(state.isComplete(.playgroundChat))
        XCTAssertEqual(state.completedCount, 2)
        XCTAssertEqual(state.progress, 0.5, accuracy: 0.001)
        XCTAssertTrue(state.shouldShow)
    }

    func testFullyCompleteHidesChecklist() {
        let probe = OnboardingLibraryProbe(
            hasReadyDataset: true,
            hasLocalBaseModel: true,
            hasDryRunOrTrain: true,
            hasPlaygroundChat: true
        )
        let state = OnboardingChecklistEvaluator.evaluate(probe: probe)
        XCTAssertTrue(state.isFullyComplete)
        XCTAssertFalse(state.shouldShow)
        XCTAssertEqual(state.remaining, [])
        XCTAssertEqual(state.progress, 1.0, accuracy: 0.001)
    }

    func testDismissedHidesEvenWhenIncomplete() {
        let probe = OnboardingLibraryProbe(hasReadyDataset: true)
        let persisted = OnboardingPersistedState(dismissed: true)
        let state = OnboardingChecklistEvaluator.evaluate(probe: probe, persisted: persisted)
        XCTAssertFalse(state.isFullyComplete)
        XCTAssertTrue(state.dismissed)
        XCTAssertFalse(state.shouldShow)
    }

    func testManualCompletionUnionsWithProbe() {
        let probe = OnboardingLibraryProbe(hasReadyDataset: true)
        let persisted = OnboardingPersistedState(
            dismissed: false,
            manuallyCompleted: [.playgroundChat]
        )
        let state = OnboardingChecklistEvaluator.evaluate(probe: probe, persisted: persisted)
        XCTAssertTrue(state.isComplete(.importDataset))
        XCTAssertTrue(state.isComplete(.playgroundChat))
        XCTAssertFalse(state.isComplete(.installFixture))
        XCTAssertFalse(state.isComplete(.dryRunOrTrain))
    }

    func testStepMetadataStable() {
        XCTAssertEqual(OnboardingStep.importDataset.destinationHint, "datasets")
        XCTAssertEqual(OnboardingStep.installFixture.destinationHint, "models")
        XCTAssertEqual(OnboardingStep.dryRunOrTrain.destinationHint, "train")
        XCTAssertEqual(OnboardingStep.playgroundChat.destinationHint, "playground")
        for step in OnboardingStep.allCases {
            XCTAssertFalse(step.title.isEmpty)
            XCTAssertFalse(step.detail.isEmpty)
            XCTAssertFalse(step.systemImage.isEmpty)
        }
    }

    func testOnboardingStoreRoundTrip() {
        let suiteName = "bam.test.onboarding.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Could not create suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = OnboardingStore(defaults: defaults)
        XCTAssertFalse(store.loadPersisted().dismissed)
        XCTAssertTrue(store.loadPersisted().manuallyCompleted.isEmpty)

        store.markCompleted(.importDataset)
        store.markCompleted(.dryRunOrTrain)
        store.dismiss()

        let loaded = store.loadPersisted()
        XCTAssertTrue(loaded.dismissed)
        XCTAssertEqual(loaded.manuallyCompleted, [.importDataset, .dryRunOrTrain])

        store.reset()
        let cleared = store.loadPersisted()
        XCTAssertFalse(cleared.dismissed)
        XCTAssertTrue(cleared.manuallyCompleted.isEmpty)
    }

    func testProbeIsCompleteHelpers() {
        var probe = OnboardingLibraryProbe()
        XCTAssertFalse(probe.isComplete(.importDataset))
        probe.hasReadyDataset = true
        XCTAssertTrue(probe.isComplete(.importDataset))
        probe.hasLocalBaseModel = true
        XCTAssertTrue(probe.isComplete(.installFixture))
        probe.hasDryRunOrTrain = true
        XCTAssertTrue(probe.isComplete(.dryRunOrTrain))
        probe.hasPlaygroundChat = true
        XCTAssertTrue(probe.isComplete(.playgroundChat))
    }
}
