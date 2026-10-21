import ApplicationServices
import XCTest
@testable import WindowBoard

final class WindowOperationInspectionTests: XCTestCase {
    func testProductionAggregationDistinguishesZeroPartialAndFailure() {
        typealias Inspection = AccessibilityWindowService.ApplicationInspection
        let empty = AccessibilityWindowService.aggregateInspections([])
        XCTAssertEqual(empty.coverage, .complete)
        let issue = WindowInspectionIssue(stage: .enumerateWindows, pid: 43, windowID: nil, failure: .ax(.cannotComplete))
        let failed = Inspection(pid: 43, windows: [], issues: [issue], hasSuccessfulScope: false)
        XCTAssertEqual(AccessibilityWindowService.aggregateInspections([failed]).coverage, .failed)
        let window = makeWindow(id: "retained")
        let partial = AccessibilityWindowService.aggregateInspections([
            Inspection(pid: 42, windows: [window], issues: [], hasSuccessfulScope: true), failed
        ])
        XCTAssertEqual(partial.coverage, .partial)
        XCTAssertEqual(partial.windows.map(\.id), [window.id])
        XCTAssertEqual(partial.failedPIDs, [43])
        XCTAssertEqual(partial.issues, [issue])
        XCTAssertEqual(AccessibilityWindowService.aggregateInspections([], permissionGranted: false).coverage, .failed)
        let permissionChanged = AccessibilityWindowService.aggregateInspections([
            Inspection(pid: 42, windows: [window], issues: [], hasSuccessfulScope: true), failed
        ], permissionGranted: false)
        XCTAssertEqual(permissionChanged.windows.map(\.id), [window.id])
        XCTAssertEqual(permissionChanged.coverage, .failed)
        XCTAssertEqual(permissionChanged.failedPIDs, [43])
        XCTAssertEqual(permissionChanged.issues.map(\.stage), [.enumerateWindows, .accessibilityPermission])
    }

    func testProductionBoolConversionRejectsNumbersStringsNilAndAXFailure() throws {
        for expected in [true, false] {
            let observation = AccessibilityWindowService.minimizedObservation(rawValue: expected ? kCFBooleanTrue : kCFBooleanFalse, error: .success, pid: 42, windowID: "w")
            XCTAssertEqual(try observation.state.get(), expected)
            XCTAssertEqual(observation.quality, .diagnostic)
        }
        for raw: CFTypeRef? in [nil, NSNumber(value: 1), "true" as CFString] {
            let observation = AccessibilityWindowService.minimizedObservation(rawValue: raw, error: .success, pid: 42, windowID: "w")
            XCTAssertThrowsError(try observation.state.get()) { error in
                XCTAssertEqual((error as? WindowInspectionIssue)?.failure, .invalidValue)
            }
        }
        let failed = AccessibilityWindowService.minimizedObservation(rawValue: kCFBooleanFalse, error: .cannotComplete, pid: 42, windowID: "w")
        XCTAssertThrowsError(try failed.state.get()) { error in
            XCTAssertEqual((error as? WindowInspectionIssue)?.failure, .ax(.cannotComplete))
        }
    }

    func testProductionGeometryConversionDistinguishesExpectedAXTypesAndReadErrors() {
        var point = CGPoint(x: 10, y: 20)
        var size = CGSize(width: 100, height: 200)
        let positionValue = AXValueCreate(.cgPoint, &point)!
        let sizeValue = AXValueCreate(.cgSize, &size)!
        XCTAssertNil(AccessibilityWindowService.geometryIssue(rawValue: positionValue, error: .success, stage: .readPosition, pid: 42))
        XCTAssertNil(AccessibilityWindowService.geometryIssue(rawValue: sizeValue, error: .success, stage: .readSize, pid: 42))
        for raw: CFTypeRef? in [nil, kCFBooleanTrue, "invalid" as CFString, sizeValue] {
            XCTAssertEqual(AccessibilityWindowService.geometryIssue(rawValue: raw, error: .success, stage: .readPosition, pid: 42)?.failure, .invalidValue)
        }
        XCTAssertEqual(AccessibilityWindowService.geometryIssue(rawValue: positionValue, error: .cannotComplete, stage: .readPosition, pid: 42)?.failure, .ax(.cannotComplete))
    }

    func testProductionRoleConversionKeepsLegitimateExclusionSeparateFromFailure() throws {
        XCTAssertEqual(try AccessibilityWindowService.roleObservation(rawValue: kAXButtonRole as CFString, error: .success, pid: 42).get(), kAXButtonRole)
        XCTAssertEqual(try AccessibilityWindowService.roleObservation(rawValue: kAXWindowRole as CFString, error: .success, pid: 42).get(), kAXWindowRole)
        for raw: CFTypeRef? in [nil, kCFBooleanTrue, NSNumber(value: 1)] {
            XCTAssertThrowsError(try AccessibilityWindowService.roleObservation(rawValue: raw, error: .success, pid: 42).get())
        }
        XCTAssertThrowsError(try AccessibilityWindowService.roleObservation(rawValue: kAXWindowRole as CFString, error: .cannotComplete, pid: 42).get())
        let excluded = AccessibilityWindowService.ApplicationInspection(pid: 42, windows: [], issues: [], hasSuccessfulScope: true)
        XCTAssertEqual(AccessibilityWindowService.aggregateInspections([excluded]).coverage, .complete)
    }

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
