import ApplicationServices
import XCTest
@testable import WindowBoard

final class WindowOperationInspectionTests: XCTestCase {
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
