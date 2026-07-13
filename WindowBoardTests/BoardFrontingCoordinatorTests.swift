import XCTest
@testable import WindowBoard

@MainActor
final class BoardFrontingCoordinatorTests: XCTestCase {
    func testBoardSelectionRunsAfterDelayUsingCurrentEligibility() async {
        let coordinator = BoardFrontingCoordinator(
            boardSelectionDelay: .milliseconds(10),
            boardClickDebounce: 0
        )
        var isEnabled = false
        var actionCount = 0

        coordinator.scheduleBoardSelection(
            isEnabled: { isEnabled },
            hasAvailableWindows: { true },
            perform: { actionCount += 1 }
        )
        isEnabled = true

        let deadline = Date().addingTimeInterval(1)
        while actionCount == 0, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(actionCount, 1)
    }

    func testReschedulingBoardSelectionRunsOnlyLatestAction() async {
        let coordinator = BoardFrontingCoordinator(
            boardSelectionDelay: .milliseconds(10),
            boardClickDebounce: 0
        )
        var firstCount = 0
        var secondCount = 0

        coordinator.scheduleBoardSelection(
            isEnabled: { true },
            hasAvailableWindows: { true },
            perform: { firstCount += 1 }
        )
        coordinator.scheduleBoardSelection(
            isEnabled: { true },
            hasAvailableWindows: { true },
            perform: { secondCount += 1 }
        )

        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(firstCount, 0)
        XCTAssertEqual(secondCount, 1)
    }

    func testBoardSelectionDebounceOnlyAdvancesForAcceptedAction() {
        let clock = FrontingTestClock()
        let coordinator = BoardFrontingCoordinator(
            boardClickDebounce: 0.3,
            now: { clock.date }
        )
        var actionCount = 0

        coordinator.performBoardSelection(
            isEnabled: { false },
            hasAvailableWindows: { true },
            perform: { actionCount += 1 }
        )
        coordinator.performBoardSelection(
            isEnabled: { true },
            hasAvailableWindows: { true },
            perform: { actionCount += 1 }
        )
        clock.date = clock.date.addingTimeInterval(0.1)
        coordinator.performBoardSelection(
            isEnabled: { true },
            hasAvailableWindows: { true },
            perform: { actionCount += 1 }
        )

        XCTAssertEqual(actionCount, 1)
    }

    func testNewFrontingOperationInvalidatesPreviousCompletion() async {
        let coordinator = BoardFrontingCoordinator()
        var firstCompletionCount = 0
        var secondCompletionCount = 0

        coordinator.frontAttachedWindows(
            count: 1,
            operation: { try? await Task.sleep(for: .milliseconds(40)) },
            completion: { firstCompletionCount += 1 }
        )
        coordinator.frontAttachedWindows(
            count: 1,
            operation: {},
            completion: { secondCompletionCount += 1 }
        )

        try? await Task.sleep(for: .milliseconds(70))
        XCTAssertEqual(firstCompletionCount, 0)
        XCTAssertEqual(secondCompletionCount, 1)
    }

    func testFrontingSuppressionKeepsExistingReplacementSemantics() {
        let clock = FrontingTestClock()
        let coordinator = BoardFrontingCoordinator(now: { clock.date })

        coordinator.suppressExternalActivation(for: 0.8)
        clock.date = clock.date.addingTimeInterval(0.2)
        coordinator.suppressExternalActivation(for: 0.3)

        XCTAssertFalse(coordinator.shouldAcceptExternalActivation())
        clock.date = clock.date.addingTimeInterval(0.31)
        XCTAssertTrue(coordinator.shouldAcceptExternalActivation())
    }

    func testOnlyLatestWorkspaceFrontingTokenCanFinish() {
        let coordinator = BoardFrontingCoordinator()
        let firstToken = coordinator.beginWorkspaceFronting {}
        let secondToken = coordinator.beginWorkspaceFronting {}
        var firstEndCount = 0
        var secondEndCount = 0

        coordinator.endWorkspaceFronting(token: firstToken) { firstEndCount += 1 }
        coordinator.endWorkspaceFronting(token: secondToken) { secondEndCount += 1 }

        XCTAssertEqual(firstEndCount, 0)
        XCTAssertEqual(secondEndCount, 1)
    }
}

@MainActor
private final class FrontingTestClock {
    var date = Date(timeIntervalSinceReferenceDate: 1_000)
}
