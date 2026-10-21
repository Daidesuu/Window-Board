import ApplicationServices
import XCTest
@testable import WindowBoard

final class ControlledMinimizationWindowServiceTests: XCTestCase {
    @MainActor
    func testIndependentGatesRecordConcurrencyWithoutBlockingMainActor() async throws {
        let service = ControlledMinimizationWindowService()
        let listed = expectation(description: "listing started")
        let written = expectation(description: "write started")
        let listGate = service.holdNext(.list, onStart: { listed.fulfill() })
        let writeGate = service.holdNext(.minimize, onStart: { written.fulfill() })
        let window = makeWindow()
        let listing = Task.detached { service.listWindowsReport() }
        await fulfillment(of: [listed], timeout: 2)
        let writing = Task.detached { try service.setMinimized(true, for: window) }
        await fulfillment(of: [written], timeout: 2)
        XCTAssertEqual(service.snapshot.activeCalls, 2)
        XCTAssertEqual(service.snapshot.maximumConcurrentCalls, 2)
        XCTAssertFalse(service.snapshot.events.contains { $0.onMainThread })
        writeGate.release()
        try await writing.value
        XCTAssertEqual(service.snapshot.activeCalls, 1)
        listGate.release()
        _ = await listing.value
        XCTAssertEqual(service.snapshot.activeCalls, 0)
        XCTAssertEqual(service.snapshot.events.filter { $0.phase == .started }.map(\.operation), [.list, .minimize])
    }

    func testUnknownStateAndDirectionalFailuresRemainIndependent() throws {
        let service = ControlledMinimizationWindowService()
        let window = makeWindow()
        let issue = WindowInspectionIssue(stage: .readMinimized, pid: window.pid, windowID: window.id, failure: .invalidValue)
        service.setObservation(MinimizedObservation(state: .failure(issue), quality: .diagnostic), for: window.id)
        XCTAssertThrowsError(try service.minimizedObservation(of: window).state.get())
        service.setWriteFailure(issue, minimized: true, for: window.id)
        XCTAssertThrowsError(try service.setMinimized(true, for: window))
        try service.setMinimized(false, for: window)
        XCTAssertFalse(try service.minimizedObservation(of: window).state.get())
        XCTAssertEqual(service.snapshot.count(for: .minimize), 1)
        XCTAssertEqual(service.snapshot.count(for: .restore), 1)
        XCTAssertEqual(ControlledMinimizationWindowService().snapshot.events.count, 0)
    }

    @MainActor
    func testReadResultCanPauseAfterSamplingAndReportPreservesCoverage() async throws {
        let service = ControlledMinimizationWindowService()
        let window = makeWindow()
        service.setReport(WindowEnumerationReport(windows: [window], coverage: .partial, issues: [], failedPIDs: [42]))
        XCTAssertEqual(service.listWindowsReport().coverage, .partial)
        let sampled = expectation(description: "read sampled")
        let gate = service.holdNext(.readResult, onStart: { sampled.fulfill() })
        let reading = Task.detached { service.minimizedObservation(of: window) }
        await fulfillment(of: [sampled], timeout: 2)
        service.setObservation(MinimizedObservation(state: .success(true), quality: .diagnostic), for: window.id)
        gate.release()
        let observation = await reading.value
        XCTAssertFalse(try observation.state.get())
        XCTAssertTrue(try service.minimizedObservation(of: window).state.get())
    }

    @MainActor
    func testReadAndRestoreGatesPauseBeforeStateMutation() async throws {
        let service = ControlledMinimizationWindowService()
        let window = makeWindow()
        service.setObservation(MinimizedObservation(state: .success(true), quality: .diagnostic), for: window.id)
        let readStarted = expectation(description: "read started")
        let readGate = service.holdNext(.read, onStart: { readStarted.fulfill() })
        let reading = Task.detached { service.minimizedObservation(of: window) }
        await fulfillment(of: [readStarted], timeout: 2)
        XCTAssertEqual(service.snapshot.count(for: .read), 1)
        readGate.release()
        let original = await reading.value
        XCTAssertTrue(try original.state.get())
        let restoreStarted = expectation(description: "restore started")
        let restoreGate = service.holdNext(.restore, onStart: { restoreStarted.fulfill() })
        let restoring = Task.detached { try service.setMinimized(false, for: window) }
        await fulfillment(of: [restoreStarted], timeout: 2)
        XCTAssertTrue(try service.minimizedObservation(of: window).state.get())
        restoreGate.release()
        try await restoring.value
        XCTAssertFalse(try service.minimizedObservation(of: window).state.get())
    }

    private func makeWindow() -> WindowInfo {
        WindowInfo(id: "test", appName: "Test", title: "", pid: 42, bundleIdentifier: nil, bundleURL: nil, documentURL: nil, axWindow: AXUIElementCreateApplication(42), windowNumber: 1, position: .zero)
    }
}

final class WindowMinimizationExecutorTests: XCTestCase {
    private let intent = MinimizationIntentID(value: 1)
    private func window(_ id: String, pid: pid_t = 42) -> WindowInfo {
        WindowInfo(id: id, appName: id, title: id, pid: pid, bundleIdentifier: nil, bundleURL: nil, documentURL: nil, axWindow: AXUIElementCreateApplication(pid), windowNumber: UInt32(id.count), position: .zero)
    }
    @MainActor
    private func execute(_ source: CandidateSource, service: any WorkspaceWindowOperating, kind: MinimizationExecutionRequest.Kind = .automatic, protection: ProtectionSnapshot = ProtectionSnapshot(records: [])) async -> (MinimizationOperationResult, [StepReceipt]) {
        var receipts: [StepReceipt] = []
        let result = await UnattachedWindowMinimizationExecutor().run(
            request: MinimizationExecutionRequest(intentID: intent, operationID: UUID(), kind: kind, candidateSource: source), service: service,
            authorize: { proposal in
                XCTAssertTrue(proposal.hasMatchingCandidateIdentity)
                let selected = proposal.candidateWindow
                return .perform(WindowOperationPermit(operationID: proposal.operationID, intentID: proposal.intentID, stepID: proposal.stepID, kind: proposal.kind, identity: proposal.candidateIdentity, window: selected, attachmentID: proposal.attachmentID, expectedLedgerVersion: proposal.expectedLedgerVersion, protectionFingerprint: protection.fingerprint, classification: .target))
            }, restorePlan: { protection }, record: { receipts.append($0) })
        return (result, receipts)
    }
    @MainActor
    func testRefreshFindsNewWindowAndRunsOffMainActor() async {
        let service = ControlledMinimizationWindowService()
        service.setReport(WindowEnumerationReport(windows: [window("new")], coverage: .complete, issues: [], failedPIDs: []))
        let (result, receipts) = await execute(.refresh(fallback: [window("stale")]), service: service)
        XCTAssertEqual(service.snapshot.count(for: .list), 1)
        XCTAssertEqual(result.summary.minimizedCount, 1)
        XCTAssertEqual(receipts.count, 1)
        XCTAssertEqual(result.candidateSnapshot?.report.windows.map(\.id), ["new"])
        XCTAssertFalse(service.snapshot.events.contains { $0.onMainThread })
    }
    @MainActor
    func testSameIntentDiagnosticPartialReportReusesAndMergesFailedScope() async {
        let service = ControlledMinimizationWindowService()
        let report = WindowEnumerationReport(windows: [window("fresh")], coverage: .partial, issues: [], failedPIDs: [43])
        let snapshot = CandidateSnapshot(report: report, origin: .switchResolution, intentID: intent, capturedAt: .now, fallback: [window("fallback", pid: 43), window("excluded", pid: 44)])
        let (result, _) = await execute(.reuse(snapshot), service: service)
        XCTAssertEqual(service.snapshot.count(for: .list), 0)
        XCTAssertEqual(result.summary.minimizedCount, 2)
        XCTAssertEqual(result.summary.coverage, .partial)
    }
    @MainActor
    func testLegacyAndOtherIntentRefreshExactlyOnceAndFailedZeroIsNotEmptySuccess() async {
        for legacy in [true, false] {
            let service = ControlledMinimizationWindowService()
            let issue = WindowInspectionIssue(stage: .enumerateWindows, pid: 42, windowID: nil, failure: .invalidValue)
            service.setReport(WindowEnumerationReport(windows: [], coverage: .failed, issues: [issue], failedPIDs: [42]))
            let snapshot = CandidateSnapshot(report: WindowEnumerationReport(windows: [], coverage: legacy ? .unverifiedLegacy : .complete, issues: [], failedPIDs: []), origin: legacy ? .legacyCache : .switchResolution, intentID: MinimizationIntentID(value: legacy ? 1 : 2), capturedAt: .now)
            let (result, _) = await execute(.reuse(snapshot), service: service)
            XCTAssertEqual(service.snapshot.count(for: .list), 1)
            XCTAssertEqual(result.summary.issues, [issue])
            XCTAssertEqual(result.endReason, .failed)
        }
    }
    @MainActor
    func testKnownManualNoOpUnknownAndWriteFailureContinueToSuccess() async {
        let service = ControlledMinimizationWindowService()
        let windows = [window("already"), window("unknown"), window("failed"), window("success")]
        service.setObservation(MinimizedObservation(state: .success(true), quality: .diagnostic), for: "already")
        let issue = WindowInspectionIssue(stage: .readMinimized, pid: 42, windowID: "unknown", failure: .invalidValue)
        service.setObservation(MinimizedObservation(state: .failure(issue), quality: .diagnostic), for: "unknown")
        service.setWriteFailure(issue, minimized: true, for: "failed")
        let (result, receipts) = await execute(.known(windows), service: service, kind: .manual)
        XCTAssertEqual(service.snapshot.count(for: .list), 0)
        XCTAssertEqual(result.summary.noOpCount, 1)
        XCTAssertEqual(result.summary.readFailureCount, 1)
        XCTAssertEqual(result.summary.writeFailureCount, 1)
        XCTAssertEqual(result.summary.failureCount, 2)
        XCTAssertEqual(result.summary.minimizedCount, 1)
        XCTAssertEqual(receipts.count, 4)
        XCTAssertEqual(Set(receipts.map(\.stepID)).count, 4)
    }
    @MainActor
    func testAvailableAttachmentsRestoreAndFailedRestoreDoesNotStopOthers() async {
        let service = ControlledMinimizationWindowService()
        let windows = [window("restore-fail"), window("restore-ok"), window("normal"), window("unavailable")]
        for w in windows.prefix(2) { service.setObservation(MinimizedObservation(state: .success(true), quality: .diagnostic), for: w.id) }
        let issue = WindowInspectionIssue(stage: .restoreMinimized, pid: 42, windowID: windows[0].id, failure: .invalidValue)
        service.setWriteFailure(issue, minimized: false, for: windows[0].id)
        let protection = ProtectionSnapshot(records: windows.enumerated().map { index, w in ProtectionRecord(attachmentID: UUID(), window: w, savedReference: nil, isAvailable: index != 3, isReconnecting: false, lastWindowOrigin: .zero) })
        let (result, receipts) = await execute(.known(windows), service: service, protection: protection)
        XCTAssertEqual(result.summary.registeredCount, 4)
        XCTAssertEqual(result.summary.restoredCount, 1)
        XCTAssertEqual(result.summary.writeFailureCount, 1)
        XCTAssertEqual(result.summary.noOpCount, 1)
        XCTAssertEqual(receipts.count, 3)
    }
    @MainActor
    func testCompleteZeroIsEmptyAndFailedEnumerationStillProcessesFallbackOnce() async {
        let emptyService = ControlledMinimizationWindowService()
        let (empty, _) = await execute(.refresh(fallback: [window("stale")]), service: emptyService)
        XCTAssertEqual(empty.endReason, .empty)
        XCTAssertEqual(empty.summary.coverage, .complete)
        XCTAssertEqual(emptyService.snapshot.count(for: .minimize), 0)
        let service = ControlledMinimizationWindowService()
        let issue = WindowInspectionIssue(stage: .enumerateWindows, pid: 42, windowID: nil, failure: .invalidValue)
        service.setReport(WindowEnumerationReport(windows: [], coverage: .failed, issues: [issue], failedPIDs: [42]))
        let (failed, _) = await execute(.refresh(fallback: [window("known")]), service: service)
        XCTAssertEqual(failed.endReason, .failed)
        XCTAssertEqual(failed.summary.minimizedCount, 1)
        XCTAssertEqual(failed.summary.enumerationCount, 1)
        XCTAssertEqual(service.snapshot.count(for: .list), 1)
        XCTAssertEqual(failed.candidateSnapshot?.fallback.map(\.id), ["known"])
    }
    @MainActor
    func testObservationQualityDoesNotChangeEnumerationCompleteness() async {
        let service = ControlledMinimizationWindowService()
        let w = window("legacy-state")
        service.setObservation(MinimizedObservation(state: .success(true), quality: .legacy), for: w.id)
        let snapshot = CandidateSnapshot(report: WindowEnumerationReport(windows: [w], coverage: .complete, issues: [], failedPIDs: []), origin: .switchResolution, intentID: intent, capturedAt: .now)
        let (result, receipts) = await execute(.reuse(snapshot), service: service)
        XCTAssertEqual(result.summary.coverage, .complete)
        XCTAssertEqual(service.snapshot.count(for: .list), 0)
        XCTAssertEqual(service.snapshot.count(for: .minimize), 0)
        XCTAssertEqual(result.summary.noOpCount, 1)
        guard case .alreadyDesired = receipts.first?.outcome else { return XCTFail("expected no-op receipt") }
    }
    @MainActor
    func testReconcileReusesFixedLegacySnapshotWithoutListing() async {
        let service = ControlledMinimizationWindowService()
        let snapshot = CandidateSnapshot(report: WindowEnumerationReport(windows: [window("fixed")], coverage: .unverifiedLegacy, issues: [], failedPIDs: []), origin: .legacyCache, intentID: intent, capturedAt: .now)
        let (result, _) = await execute(.reuse(snapshot), service: service, kind: .reconcile)
        XCTAssertEqual(service.snapshot.count(for: .list), 0)
        XCTAssertEqual(result.summary.minimizedCount, 1)
    }
    @MainActor
    func testDiscoveredAXHandleSurvivesAuthorizationAndServiceOperations() async {
        let discovered = window("new-handle")
        let service = HandleTrackingMinimizationService(discovered: discovered)
        var proposalHandle: AXUIElement?
        var receipts: [StepReceipt] = []
        let result = await UnattachedWindowMinimizationExecutor().run(
            request: MinimizationExecutionRequest(intentID: intent, operationID: UUID(), kind: .automatic, candidateSource: .refresh(fallback: [])), service: service,
            authorize: { proposal in
                XCTAssertTrue(proposal.hasMatchingCandidateIdentity)
                proposalHandle = proposal.candidateWindow.axWindow
                return .perform(self.permit(proposal))
            }, restorePlan: { ProtectionSnapshot(records: []) }, record: { receipts.append($0) })
        XCTAssertTrue(proposalHandle === discovered.axWindow)
        XCTAssertEqual(service.handles.count, 2)
        XCTAssertTrue(service.handles.allSatisfy { $0 === discovered.axWindow })
        XCTAssertTrue(receipts.first?.window.axWindow === discovered.axWindow)
        XCTAssertEqual(result.summary.minimizedCount, 1)
    }

    @MainActor
    func testInconsistentPermitsNeverReachAXService() async {
        let candidate = window("candidate")
        let other = window("different", pid: 43)
        for mismatch in 0..<7 {
            let service = ControlledMinimizationWindowService()
            var receipts: [StepReceipt] = []
            let result = await UnattachedWindowMinimizationExecutor().run(
                request: MinimizationExecutionRequest(intentID: intent, operationID: UUID(), kind: .manual, candidateSource: .known([candidate])), service: service,
                authorize: { proposal in
                    .perform(WindowOperationPermit(
                        operationID: mismatch == 0 ? UUID() : proposal.operationID,
                        intentID: mismatch == 1 ? MinimizationIntentID(value: 999) : proposal.intentID,
                        stepID: mismatch == 2 ? proposal.stepID + 1 : proposal.stepID,
                        kind: mismatch == 3 ? .restoreAttachment : proposal.kind,
                        identity: mismatch == 4 ? LiveWindowIdentity(window: other) : proposal.candidateIdentity,
                        window: mismatch == 5 ? other : proposal.candidateWindow,
                        attachmentID: mismatch == 6 ? UUID() : proposal.attachmentID,
                        expectedLedgerVersion: nil, protectionFingerprint: ProtectionSnapshot(records: []).fingerprint, classification: .target))
                }, restorePlan: { ProtectionSnapshot(records: []) }, record: { receipts.append($0) })
            XCTAssertEqual(service.snapshot.count(for: .read), 0, "mismatch \(mismatch)")
            XCTAssertEqual(service.snapshot.count(for: .minimize), 0, "mismatch \(mismatch)")
            XCTAssertEqual(result.summary.minimizedCount, 0)
            guard case .skipped(.identityChanged) = receipts.first?.outcome else {
                XCTFail("invalid permit must produce identityChanged receipt \(mismatch)")
                continue
            }
        }
    }

    @MainActor
    func testReconcileRejectsOtherIntentSnapshotWithoutListingOrAXOperations() async {
        let service = ControlledMinimizationWindowService()
        let snapshot = CandidateSnapshot(report: WindowEnumerationReport(windows: [window("old")], coverage: .complete, issues: [], failedPIDs: []), origin: .minimization, intentID: MinimizationIntentID(value: 2), capturedAt: .now)
        let (result, receipts) = await execute(.reuse(snapshot), service: service, kind: .reconcile)
        XCTAssertEqual(result.endReason, .superseded)
        XCTAssertEqual(result.summary.interruptionReason, .superseded)
        XCTAssertEqual(service.snapshot.events.count, 0)
        XCTAssertTrue(receipts.isEmpty)
        XCTAssertNil(result.candidateSnapshot)
    }

    private func permit(_ proposal: StepProposal) -> WindowOperationPermit {
        WindowOperationPermit(operationID: proposal.operationID, intentID: proposal.intentID, stepID: proposal.stepID, kind: proposal.kind, identity: proposal.candidateIdentity, window: proposal.candidateWindow, attachmentID: proposal.attachmentID, expectedLedgerVersion: proposal.expectedLedgerVersion, protectionFingerprint: ProtectionSnapshot(records: []).fingerprint, classification: .target)
    }

}

/// A test-local proxy records the actual AX references, rather than inferring
/// handle preservation from IDs accepted by the shared controlled fake.
private final class HandleTrackingMinimizationService: WorkspaceWindowOperating {
    private let base = ControlledMinimizationWindowService()
    private let lock = NSLock()
    private var captured: [AXUIElement] = []
    var handles: [AXUIElement] {
        lock.lock()
        defer { lock.unlock() }
        return captured
    }
    init(discovered: WindowInfo) {
        base.setReport(WindowEnumerationReport(windows: [discovered], coverage: .complete, issues: [], failedPIDs: []))
    }
    private func capture(_ window: WindowInfo) {
        lock.lock()
        defer { lock.unlock() }
        captured.append(window.axWindow)
    }
    func listWindows() -> [WindowInfo] { base.listWindows() }
    func listWindowsReport() -> WindowEnumerationReport { base.listWindowsReport() }
    func minimizedObservation(of window: WindowInfo) -> MinimizedObservation {
        capture(window)
        return base.minimizedObservation(of: window)
    }
    func isMinimized(_ window: WindowInfo) -> Bool { base.isMinimized(window) }
    func setMinimized(_ minimized: Bool, for window: WindowInfo) throws {
        capture(window)
        try base.setMinimized(minimized, for: window)
    }
    func windows(matching window: WindowInfo) -> [WindowInfo] { base.windows(matching: window) }
    func position(of window: WindowInfo) throws -> CGPoint { try base.position(of: window) }
    func size(of window: WindowInfo) throws -> CGSize { try base.size(of: window) }
    func setPosition(_ position: CGPoint, for window: WindowInfo) throws { try base.setPosition(position, for: window) }
    func setSize(_ size: CGSize, for window: WindowInfo) throws { try base.setSize(size, for: window) }
    func raise(_ window: WindowInfo) { base.raise(window) }
    func openSavedWindowReference(_ reference: SavedWindowReference) -> Bool { false }
    func activateSavedApplication(_ reference: SavedWindowReference) -> Bool { false }
}
