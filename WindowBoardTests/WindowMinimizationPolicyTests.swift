import ApplicationServices
import XCTest
@testable import WindowBoard

final class WindowMinimizationPolicyTests: XCTestCase {
    private func window(_ id: String = "candidate", pid: pid_t = 42, app: String = "Editor", title: String = "Document", bundle: String? = "editor", number: CGWindowID? = nil, position: CGPoint? = nil, document: URL? = nil) -> WindowInfo {
        WindowInfo(id: id, appName: app, title: title, pid: pid, bundleIdentifier: bundle, bundleURL: nil, documentURL: document, axWindow: AXUIElementCreateApplication(pid), windowNumber: number, position: position)
    }

    private func record(_ window: WindowInfo, available: Bool = true, reconnecting: Bool = false, origin: CGPoint = .zero) -> ProtectionRecord {
        ProtectionRecord(attachmentID: UUID(), window: window, savedReference: nil, isAvailable: available, isReconnecting: reconnecting, lastWindowOrigin: origin)
    }

    private func classify(_ candidate: WindowInfo, _ records: [ProtectionRecord]) -> CandidateClassification {
        UnattachedWindowMinimizationPolicy.classify(candidate, protection: ProtectionSnapshot(records: records))
    }

    func testRegisteredIdentityPrecedesAvailabilityAndSameApplicationRules() {
        XCTAssertEqual(classify(window(), [record(window(), available: false, reconnecting: true)]), .registered)
        XCTAssertEqual(classify(window(number: 7), [record(window("other", number: 7))]), .registered)
        XCTAssertEqual(classify(window(number: 7), [record(window("other", pid: 99, bundle: "different", number: 7))]), .target)
        XCTAssertEqual(classify(window(bundle: "com.microsoft.VSCode"), [record(window(bundle: "com.microsoft.VSCode"))]), .registered)
    }

    func testLegacyPositionMatchUsesLastOriginAndStrictThreePointBoundary() {
        let registered = record(window("other", position: CGPoint(x: 900, y: 900)), available: false, origin: CGPoint(x: 10, y: 20))
        XCTAssertEqual(classify(window(position: CGPoint(x: 12.9, y: 17.1)), [registered]), .registered)
        XCTAssertEqual(classify(window(position: CGPoint(x: 13, y: 20)), [registered]), .target)
        XCTAssertEqual(classify(window(position: nil), [registered]), .target)
        XCTAssertEqual(classify(window(title: "different", position: CGPoint(x: 10, y: 20)), [registered]), .target)
    }

    func testTerminalProtectsDistinctNumberDocumentAndTitleButOnlyWhenAvailable() {
        let terminal = window("registered", bundle: "com.apple.Terminal", number: 1, document: URL(fileURLWithPath: "/one"))
        let other = window(title: "Different", bundle: "com.apple.Terminal", number: 2, document: URL(fileURLWithPath: "/two"))
        XCTAssertEqual(classify(other, [record(terminal)]), .sameApplicationProtected)
        XCTAssertEqual(classify(other, [record(terminal, available: false)]), .target)
        XCTAssertEqual(classify(other, [record(terminal, reconnecting: true)]), .target)
        XCTAssertEqual(classify(other, [record(window("placeholder", pid: 0, bundle: "com.apple.Terminal"))]), .target)
    }

    func testAmbiguityFallbackAndConcreteDisambiguation() {
        let registered = record(window("other"))
        XCTAssertEqual(classify(window(), [registered]), .sameApplicationProtected)
        XCTAssertEqual(classify(window(title: "  Document\n"), [registered]), .sameApplicationProtected)
        XCTAssertEqual(classify(window(title: "Other"), [registered]), .target)
        XCTAssertEqual(classify(window(title: "  "), [registered]), .sameApplicationProtected)
        XCTAssertEqual(classify(window(number: 2), [record(window("other", number: 1))]), .target)
        XCTAssertEqual(classify(window(document: URL(fileURLWithPath: "/two")), [record(window("other", document: URL(fileURLWithPath: "/one")))]), .target)
        XCTAssertEqual(classify(window(bundle: "different"), [registered]), .target)
        XCTAssertEqual(classify(window(pid: 99, bundle: nil), [registered]), .sameApplicationProtected)
        XCTAssertEqual(classify(window(app: "Different", bundle: nil), [registered]), .sameApplicationProtected)
        XCTAssertEqual(classify(window(), [record(window("other"), available: false)]), .target)
        XCTAssertEqual(classify(window(), [record(window("other"), reconnecting: true)]), .target)
    }

    func testVSCodeNeverUsesAmbiguousProtectionIncludingMissingBundleFallback() {
        for bundle in ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.visualstudio.code.oss"] {
            XCTAssertEqual(classify(window(bundle: bundle), [record(window("other", bundle: bundle))]), .target)
            XCTAssertEqual(classify(window(bundle: nil), [record(window("other", bundle: bundle))]), .target)
            XCTAssertEqual(classify(window(bundle: bundle), [record(window("other", bundle: nil))]), .target)
        }
    }

    func testCallerSuppliedComposedRecordsProtectMainAdditionalChildAndPermanentEqually() {
        let windows = ["main", "additional", "child", "permanent"].enumerated().map { window($0.element, pid: pid_t(50 + $0.offset), bundle: $0.element) }
        let records = windows.map { record($0) }
        for candidate in windows { XCTAssertEqual(classify(candidate, records), .registered) }
        XCTAssertEqual(classify(window(), records), .target)
    }

    func testFreshValuesWinDeduplicationAndCompleteDropsOldFallback() {
        let fresh = window("same", title: "new")
        let report = WindowEnumerationReport(windows: [fresh, fresh], coverage: .complete, issues: [], failedPIDs: [])
        let result = UnattachedWindowMinimizationPolicy.mergeCandidates(report: report, fallback: [window("same", title: "old"), window("stale")])
        XCTAssertEqual(result.map(\.window.id), ["same"])
        XCTAssertEqual(result.first?.window.title, "new")
        XCTAssertEqual(result.first?.provenance, .fresh)
    }

    func testPartialAndFailedReportsOnlySupplementFailedApplications() {
        for coverage in [WindowEnumerationReport.Coverage.partial, .failed] {
            let report = WindowEnumerationReport(windows: [window("same", pid: 2, title: "new")], coverage: coverage, issues: [], failedPIDs: [2])
            let result = UnattachedWindowMinimizationPolicy.mergeCandidates(report: report, fallback: [window("same", pid: 2, title: "old"), window("missing", pid: 2), window("missing", pid: 2), window("stale", pid: 3)])
            XCTAssertEqual(result.map(\.window.id), ["same", "missing"])
            XCTAssertEqual(result.map(\.provenance), [.fresh, .fallback])
            XCTAssertEqual(result.first?.window.title, "new")
        }
    }

    func testUnknownGlobalScopeAndLegacyPermitAllKnownFallback() {
        let permission = WindowInspectionIssue(stage: .accessibilityPermission, pid: nil, windowID: nil, failure: .ax(.apiDisabled))
        let reports = [
            WindowEnumerationReport(windows: [], coverage: .partial, issues: [permission], failedPIDs: [2]),
            WindowEnumerationReport(windows: [], coverage: .failed, issues: [permission], failedPIDs: [2]),
            WindowEnumerationReport(windows: [], coverage: .failed, issues: [], failedPIDs: []),
            WindowEnumerationReport(windows: [], coverage: .unverifiedLegacy, issues: [], failedPIDs: [])
        ]
        for report in reports {
            let result = UnattachedWindowMinimizationPolicy.mergeCandidates(report: report, fallback: [window("a", pid: 2), window("b", pid: 3)])
            XCTAssertEqual(result.map(\.window.id), ["a", "b"])
            XCTAssertEqual(result.map(\.provenance), [.fallback, .fallback])
        }
        let scoped = WindowEnumerationReport(windows: [], coverage: .partial, issues: [], failedPIDs: [])
        XCTAssertTrue(UnattachedWindowMinimizationPolicy.mergeCandidates(report: scoped, fallback: [window()]).isEmpty)
    }
}
