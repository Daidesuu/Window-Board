import ApplicationServices
import XCTest
@testable import WindowBoard

final class WindowOperationInspectionTests: XCTestCase {
    func testLegacyEnumerationPreservesWindowsWithoutClaimingCompleteCoverage() {
        let fake = LegacyInspectionWindowService()
        let first = makeWindow(id: "first")
        let second = makeWindow(id: "second")
        fake.windowsToReturn = [second, first]
        let service: WorkspaceWindowOperating = fake

        let report = service.listWindowsReport()

        XCTAssertEqual(report.windows.map(\.id), ["second", "first"])
        XCTAssertEqual(report.coverage, .unverifiedLegacy)
        XCTAssertTrue(report.issues.isEmpty)
        XCTAssertTrue(report.failedPIDs.isEmpty)
        XCTAssertEqual(fake.listCallCount, 1)
    }

    func testLegacyEmptyEnumerationStillHasUnverifiedCoverage() {
        let fake = LegacyInspectionWindowService()
        let service: WorkspaceWindowOperating = fake
        let report = service.listWindowsReport()
        XCTAssertTrue(report.windows.isEmpty)
        XCTAssertEqual(report.coverage, .unverifiedLegacy)
        XCTAssertEqual(fake.listCallCount, 1)
    }

    func testLegacyMinimizedObservationPreservesBothBoolValuesAndCallsOnce() throws {
        for minimized in [false, true] {
            let fake = LegacyInspectionWindowService()
            fake.minimizedToReturn = minimized
            let window = makeWindow(id: "observed")
            let service: WorkspaceWindowOperating = fake

            let observation = service.minimizedObservation(of: window)

            XCTAssertEqual(try observation.state.get(), minimized)
            XCTAssertEqual(observation.quality, .legacy)
            XCTAssertEqual(fake.observedWindowIDs, [window.id])
        }
    }

    func testExistingEntryPointsRemainDirectLegacyCalls() {
        let fake = LegacyInspectionWindowService()
        let window = makeWindow(id: "direct")
        fake.windowsToReturn = [window]
        let service: WorkspaceWindowOperating = fake
        XCTAssertEqual(service.listWindows().map(\.id), [window.id])
        XCTAssertFalse(service.isMinimized(window))
        XCTAssertEqual(fake.listCallCount, 1)
        XCTAssertEqual(fake.observedWindowIDs, [window.id])
    }

    private func makeWindow(id: String) -> WindowInfo {
        WindowInfo(id: id, appName: "Legacy", title: id, pid: 42,
                   bundleIdentifier: nil, bundleURL: nil, documentURL: nil,
                   axWindow: AXUIElementCreateApplication(42), windowNumber: nil, position: nil)
    }

    func testUnknownMinimizedStateRemainsFailureRatherThanNormalFalse() throws {
        let issue = WindowInspectionIssue(stage: .readMinimized, pid: 42, windowID: "window", failure: .ax(.cannotComplete))
        let unknown = MinimizedObservation(state: .failure(issue), quality: .diagnostic)
        let normal = MinimizedObservation(state: .success(false), quality: .diagnostic)
        XCTAssertThrowsError(try unknown.state.get())
        XCTAssertFalse(try normal.state.get())
        if case .failure(let actual) = unknown.state {
            XCTAssertEqual(actual, issue)
        }
    }

    func testEmptyEnumerationDoesNotImplyCompleteCoverage() {
        let reports = WindowEnumerationReport.Coverage.allCases.map {
            WindowEnumerationReport(windows: [], coverage: $0, issues: [], failedPIDs: [])
        }
        XCTAssertEqual(Set(reports.map(\.coverage)).count, 4)
        XCTAssertTrue(reports.allSatisfy { $0.windows.isEmpty })
    }

    func testReceiptDeduplicationKeyIncludesOperationAndStepButNotIntent() {
        let operation = UUID()
        let first = StepReceiptID(operationID: operation, stepID: 1)
        XCTAssertEqual(first, StepReceiptID(operationID: operation, stepID: 1))
        XCTAssertNotEqual(first, StepReceiptID(operationID: operation, stepID: 2))
        XCTAssertNotEqual(first, StepReceiptID(operationID: UUID(), stepID: 1))
        XCTAssertEqual(Set([first, first]).count, 1)
    }

    func testLiveIdentitySeparatesProcessAndWindowNumber() {
        let first = LiveWindowIdentity(pid: 1, windowID: "same", windowNumber: 10)
        XCTAssertNotEqual(first, LiveWindowIdentity(pid: 2, windowID: "same", windowNumber: 10))
        XCTAssertNotEqual(first, LiveWindowIdentity(pid: 1, windowID: "same", windowNumber: 11))
    }
}

/// Intentionally implements only the pre-diagnostics protocol requirements.
private final class LegacyInspectionWindowService: WorkspaceWindowOperating {
    var windowsToReturn: [WindowInfo] = []
    var minimizedToReturn = false
    private(set) var listCallCount = 0
    private(set) var observedWindowIDs: [String] = []

    func listWindows() -> [WindowInfo] {
        listCallCount += 1
        return windowsToReturn
    }
    func isMinimized(_ window: WindowInfo) -> Bool {
        observedWindowIDs.append(window.id)
        return minimizedToReturn
    }
    func windows(matching window: WindowInfo) -> [WindowInfo] { [] }
    func position(of window: WindowInfo) throws -> CGPoint { .zero }
    func size(of window: WindowInfo) throws -> CGSize { .zero }
    func setPosition(_ position: CGPoint, for window: WindowInfo) throws {}
    func setSize(_ size: CGSize, for window: WindowInfo) throws {}
    func setMinimized(_ minimized: Bool, for window: WindowInfo) throws {}
    func raise(_ window: WindowInfo) {}
    func openSavedWindowReference(_ reference: SavedWindowReference) -> Bool { false }
    func activateSavedApplication(_ reference: SavedWindowReference) -> Bool { false }
}
