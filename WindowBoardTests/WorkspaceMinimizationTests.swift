import ApplicationServices
import XCTest
@testable import WindowBoard

final class WorkspaceMinimizationTests: XCTestCase {
    @MainActor
    func testLatestPendingReplacesAndEveryEndReasonHandsOffWithoutOldFinishReleasingSlot() throws {
        for reason: MinimizationOperationResult.EndReason in [.completed, .failed, .empty, .superseded, .cancelled] {
            for startsAutomatically in [false, true] {
                let session = makeSession()
                let target = session.workspaceStore.defaultWorkspace!.id
                let manual: MinimizationExecutionRequest
                if startsAutomatically {
                    let initial = try XCTUnwrap(session.acceptSwitchIntent(target: target, automaticEnabled: true))
                    materialize(session, initial, target)
                    manual = try XCTUnwrap(session.takeNextMinimizationOperation())
                } else {
                    manual = try XCTUnwrap(session.startManualMinimizationOperation(candidateSource: .known([])))
                }
                let first = try XCTUnwrap(session.acceptSwitchIntent(target: target, automaticEnabled: true))
                materialize(session, first, target)
                let latest = try XCTUnwrap(session.acceptSwitchIntent(target: target, automaticEnabled: true))
                materialize(session, latest, target)
                XCTAssertFalse(session.isCurrentMinimizationOperation(manual))
                XCTAssertNil(session.startManualMinimizationOperation(candidateSource: .known([])))
                XCTAssertNil(session.takeNextMinimizationOperation())
                let result = MinimizationOperationResult(operationID: manual.operationID, intentID: manual.intentID,
                    summary: OperationSummary(), endReason: reason)
                let next = try XCTUnwrap(session.finishOperation(result))
                XCTAssertEqual(next.intentID, latest)
                XCTAssertTrue(session.isCurrentMinimizationOperation(next))
                XCTAssertNil(session.finishOperation(result))
                XCTAssertEqual(session.activeMinimizationOperation?.operationID, next.operationID)
                session.finishOperation(.init(operationID: next.operationID, intentID: latest,
                    summary: OperationSummary(), endReason: .completed))
                let laterManual = try XCTUnwrap(session.startManualMinimizationOperation(candidateSource: .known([])))
                XCTAssertEqual(laterManual.intentID, latest)
                XCTAssertNil(session.finishOperation(.init(operationID: laterManual.operationID, intentID: latest,
                    summary: OperationSummary(), endReason: .completed)))
                XCTAssertNil(session.pendingAutomaticMinimization)
            }
        }
    }

    @MainActor
    func testOffEmptyInvalidAndStaleMaterializationDoNotCreateWork() throws {
        let session = makeSession()
        let target = session.workspaceStore.defaultWorkspace!.id
        let initial = try XCTUnwrap(session.acceptSwitchIntent(target: target, automaticEnabled: true))
        materialize(session, initial, target)
        XCTAssertNil(session.acceptSwitchIntent(target: UUID(), automaticEnabled: true))
        XCTAssertEqual(session.latestMinimizationIntent?.id, initial)
        let off = try XCTUnwrap(session.acceptSwitchIntent(target: target, automaticEnabled: false))
        materialize(session, off, target)
        materialize(session, initial, target)
        XCTAssertNil(session.takeNextMinimizationOperation())
        let empty = try XCTUnwrap(session.acceptSwitchIntent(target: target, automaticEnabled: true))
        materialize(session, empty, target, empty: true)
        XCTAssertNil(session.takeNextMinimizationOperation())
    }

    @MainActor
    func testFullPendingWinsOverReconcileAndManualDoesNotIssueIntent() throws {
        let session = makeSession()
        let target = session.workspaceStore.defaultWorkspace!.id
        let intent = try XCTUnwrap(session.acceptSwitchIntent(target: target, automaticEnabled: true))
        materialize(session, intent, target)
        let snapshot = CandidateSnapshot(report: .init(windows: [], coverage: .complete, issues: [], failedPIDs: []),
            origin: .minimization, intentID: intent, capturedAt: .now)
        session.requestMinimizationReconcile(intent: intent, snapshot: snapshot)
        XCTAssertEqual(session.pendingAutomaticMinimization?.kind, .automatic)
        let full = try XCTUnwrap(session.takeNextMinimizationOperation())
        session.finishOperation(.init(operationID: full.operationID, intentID: intent,
            summary: OperationSummary(), endReason: .completed))
        let manual = try XCTUnwrap(session.startManualMinimizationOperation(candidateSource: .known([])))
        XCTAssertEqual(manual.intentID, intent)
        XCTAssertEqual(session.latestMinimizationIntent?.id, intent)
    }

    @MainActor
    func testQueuedSameTargetAdoptsLatestSettingsSourceAndCallbackWithoutNewReplayIntent() async throws {
        let defaults = UserDefaults(suiteName: "MinimizationQueue.\(UUID())")!
        let service = ControlledMinimizationWindowService()
        let started = expectation(description: "initial resolution held")
        let gate = service.holdNext(.list) { started.fulfill() }
        defer { gate.release() }
        let session = WorkspaceSessionController(workspaceStore: WorkspaceStore(defaults: defaults),
            defaults: defaults, windowServiceFactory: { service })
        let target = session.workspaceStore.defaultWorkspace!.id
        defaults.set(true, forKey: "minimizeUnattachedOnWorkspaceSwitch")
        var oldCallbackCount = 0
        session.switchWorkspace(id: target, boardOrigin: nil, source: .mainWindow, followMode: .none,
            completion: { _ in oldCallbackCount += 1 })
        await fulfillment(of: [started], timeout: 3)
        let first = try XCTUnwrap(session.latestMinimizationIntent)
        // A member selection while loading changes selection only.
        XCTAssertTrue(session.requestMemberSelection(memberBoardID: target, groupPrimaryID: target))
        XCTAssertEqual(session.latestMinimizationIntent?.id, first.id)
        defaults.set(false, forKey: "minimizeUnattachedOnWorkspaceSwitch")
        let finished = expectation(description: "latest context published")
        session.switchWorkspace(id: target, boardOrigin: CGPoint(x: 20, y: 30),
            source: .statusItem, followMode: .none, windowCache: [], completion: { front in
                XCTAssertFalse(front)
                finished.fulfill()
            })
        let latest = try XCTUnwrap(session.latestMinimizationIntent)
        XCTAssertGreaterThan(latest.id, first.id)
        XCTAssertFalse(latest.automaticEnabled)
        XCTAssertEqual(latest.source, .statusItem)
        XCTAssertGreaterThanOrEqual(latest.notBefore, first.notBefore)
        gate.release()
        await fulfillment(of: [finished], timeout: 3)
        XCTAssertEqual(oldCallbackCount, 0)
        XCTAssertEqual(session.latestMinimizationIntent?.id, latest.id)
        XCTAssertNil(session.pendingAutomaticMinimization)
        XCTAssertFalse(session.isLoadingWorkspace)
    }

    @MainActor
    func testStalePhysicalSuccessIsRecordedWithoutPublishingOldUIAndDuplicateIsIdempotent() throws {
        let session = makeSession()
        let operation = try XCTUnwrap(session.startManualMinimizationOperation(candidateSource: .known([])))
        let window = ledgerWindow()
        let receipt = ledgerReceipt(operation, window: window)
        let target = session.workspaceStore.defaultWorkspace!.id
        _ = session.acceptSwitchIntent(target: target, automaticEnabled: false)
        let status = session.statusMessage
        let workspace = session.activeWorkspaceID
        let references = session.workspaceStore.workspaces
        XCTAssertFalse(session.commitReceipt(receipt))
        let first = try XCTUnwrap(session.minimizedLedger[receipt.identity])
        XCTAssertEqual(session.minimizedWindows.map(\.id), [window.id])
        session.finishOperation(.init(operationID: operation.operationID, intentID: operation.intentID,
            summary: OperationSummary(), endReason: .superseded))
        XCTAssertFalse(session.commitReceipt(receipt))
        XCTAssertEqual(session.minimizedLedger[receipt.identity]?.entryVersion, first.entryVersion)
        XCTAssertEqual(session.statusMessage, status)
        XCTAssertEqual(session.activeWorkspaceID, workspace)
        XCTAssertEqual(session.workspaceStore.workspaces, references)
    }

    @MainActor
    func testLedgerVersionsAdvanceWithoutChangingOrderAndDistinctLiveIdentitiesStaySeparate() throws {
        let session = makeSession()
        let operation = try XCTUnwrap(session.startManualMinimizationOperation(candidateSource: .known([])))
        let first = ledgerWindow()
        let otherPID = ledgerWindow(pid: 73)
        let otherNumber = ledgerWindow(number: 12)
        XCTAssertTrue(session.commitReceipt(ledgerReceipt(operation, window: first)))
        let original = try XCTUnwrap(session.minimizedLedger[LiveWindowIdentity(window: first)])
        XCTAssertTrue(session.canApplyMinimizationReceipt(ledgerReceipt(operation, window: first), to: first))
        XCTAssertFalse(session.canApplyMinimizationReceipt(ledgerReceipt(operation, window: first), to: otherPID))
        XCTAssertFalse(session.canApplyMinimizationReceipt(ledgerReceipt(operation, window: first), to: otherNumber))
        session.rememberMinimizedWindow(otherPID)
        session.rememberMinimizedWindow(otherNumber)
        XCTAssertTrue(session.commitReceipt(ledgerReceipt(operation, window: first.updatingTitle("new"), step: 2)))
        let updated = try XCTUnwrap(session.minimizedLedger[LiveWindowIdentity(window: first)])
        XCTAssertGreaterThan(updated.entryVersion, original.entryVersion)
        XCTAssertEqual(updated.insertionOrder, original.insertionOrder)
        XCTAssertEqual(session.minimizedWindows.map { LiveWindowIdentity(window: $0) },
            [first, otherPID, otherNumber].map { LiveWindowIdentity(window: $0) })
        XCTAssertEqual(session.minimizedWindows.first?.title, "new")
    }

    @MainActor
    func testOnlyChangedMinimizationCreatesLedgerEntry() throws {
        let session = makeSession()
        let operation = try XCTUnwrap(session.startManualMinimizationOperation(candidateSource: .known([])))
        let issue = WindowInspectionIssue(stage: .readMinimized, pid: 72, windowID: "same", failure: .invalidValue)
        let outcomes: [StepOutcome] = [.alreadyDesired, .readFailed(issue), .writeFailed(issue, observedAfter: nil),
            .skipped(.registered), .superseded]
        for (index, outcome) in outcomes.enumerated() {
            XCTAssertTrue(session.commitReceipt(ledgerReceipt(operation, window: ledgerWindow(),
                step: UInt64(index), outcome: outcome)))
        }
        XCTAssertTrue(session.commitReceipt(ledgerReceipt(operation, window: ledgerWindow(), step: 10, desired: false)))
        XCTAssertTrue(session.minimizedLedger.isEmpty)
        XCTAssertTrue(session.minimizedWindows.isEmpty)
    }

    @MainActor
    func testAutomaticRestoreDeletesOnlyMatchingVersionEvenAfterIntentChanges() throws {
        let session = makeSession()
        let window = ledgerWindow()
        session.rememberMinimizedWindow(window)
        let version = try XCTUnwrap(session.minimizedLedger[LiveWindowIdentity(window: window)]).entryVersion
        let operation = try XCTUnwrap(session.startManualMinimizationOperation(candidateSource: .known([])))
        _ = session.acceptSwitchIntent(target: session.workspaceStore.defaultWorkspace!.id, automaticEnabled: false)
        let receipt = StepReceipt(operationID: operation.operationID, intentID: operation.intentID, stepID: 1,
            identity: LiveWindowIdentity(window: window), window: window, desiredMinimized: false,
            outcome: .alreadyDesired, expectedLedgerVersion: version)
        XCTAssertFalse(session.commitReceipt(receipt))
        XCTAssertTrue(session.minimizedWindows.isEmpty)
        session.rememberMinimizedWindow(window)
        XCTAssertFalse(session.commitReceipt(.init(operationID: operation.operationID, intentID: operation.intentID,
            stepID: 2, identity: receipt.identity, window: window, desiredMinimized: false,
            outcome: .changed, expectedLedgerVersion: version)))
        XCTAssertEqual(session.minimizedWindows.count, 1)
    }

    @MainActor
    func testAutomaticRestoreOutcomesUseSameVersionedLedgerContract() throws {
        let issue = WindowInspectionIssue(stage: .restoreMinimized, pid: 72, windowID: "same", failure: .invalidValue)
        let outcomes: [(StepOutcome, Bool)] = [(.changed, true), (.alreadyDesired, true),
            (.readFailed(issue), false), (.writeFailed(issue, observedAfter: nil), false),
            (.writeFailed(issue, observedAfter: .init(state: .failure(issue), quality: .diagnostic)), false),
            (.writeFailed(issue, observedAfter: .init(state: .success(true), quality: .diagnostic)), false),
            (.writeFailed(issue, observedAfter: .init(state: .success(false), quality: .diagnostic)), true)]
        for (outcome, removes) in outcomes {
            let session = makeSession()
            let window = ledgerWindow()
            session.rememberMinimizedWindow(window)
            let version = try XCTUnwrap(session.minimizedLedger[LiveWindowIdentity(window: window)]).entryVersion
            let operation = try XCTUnwrap(session.startManualMinimizationOperation(candidateSource: .known([])))
            XCTAssertTrue(session.commitReceipt(.init(operationID: operation.operationID, intentID: operation.intentID,
                stepID: 1, identity: LiveWindowIdentity(window: window), window: window, desiredMinimized: false,
                outcome: outcome, expectedLedgerVersion: version)))
            XCTAssertEqual(session.minimizedWindows.isEmpty, removes)
        }
    }

    @MainActor
    func testExplicitRestorePreservesNewVersionAndOtherEntryDuringWrite() async throws {
        let service = ControlledMinimizationWindowService()
        let defaults = UserDefaults(suiteName: "RestoreVersion.\(UUID())")!
        let session = WorkspaceSessionController(workspaceStore: WorkspaceStore(defaults: defaults),
            defaults: defaults, windowServiceFactory: { service })
        let window = ledgerWindow()
        let other = ledgerWindow(pid: 73)
        service.setObservation(.init(state: .success(true), quality: .diagnostic), for: window.id)
        session.rememberMinimizedWindow(window)
        let started = expectation(description: "restore held")
        let gate = service.holdNext(.restore) { started.fulfill() }
        defer { gate.release() }
        let done = expectation(description: "restore completed")
        session.restoreMinimizedWindows { _ in done.fulfill() }
        await fulfillment(of: [started], timeout: 3)
        session.rememberMinimizedWindow(window)
        session.rememberMinimizedWindow(other)
        let version = session.minimizedLedger[LiveWindowIdentity(window: window)]?.entryVersion
        gate.release()
        await fulfillment(of: [done], timeout: 3)
        XCTAssertEqual(session.minimizedWindows.count, 2)
        XCTAssertEqual(session.minimizedLedger[LiveWindowIdentity(window: window)]?.entryVersion, version)
        XCTAssertFalse(service.snapshot.events.contains { $0.onMainThread })
    }

    @MainActor
    func testExplicitRestoreRetainsUnknownAndFailedTrueThenCommitsBeforeNextRead() async throws {
        let service = ControlledMinimizationWindowService()
        let defaults = UserDefaults(suiteName: "RestoreFailure.\(UUID())")!
        let session = WorkspaceSessionController(workspaceStore: WorkspaceStore(defaults: defaults),
            defaults: defaults, windowServiceFactory: { service })
        func window(_ id: String) -> WindowInfo {
            WindowInfo(id: id, appName: "App", title: id, pid: 72, bundleIdentifier: nil,
                bundleURL: nil, documentURL: nil, axWindow: AXUIElementCreateApplication(72),
                windowNumber: nil, position: nil)
        }
        let unknown = window("unknown"), failed = window("failed"), normal = window("normal"), last = window("last")
        let issue = WindowInspectionIssue(stage: .readMinimized, pid: 72, windowID: unknown.id, failure: .invalidValue)
        service.setObservation(.init(state: .failure(issue), quality: .diagnostic), for: unknown.id)
        service.setObservation(.init(state: .success(true), quality: .diagnostic), for: failed.id)
        service.setWriteFailure(issue, minimized: false, for: failed.id)
        for value in [unknown, failed, normal, last] { session.rememberMinimizedWindow(value) }
        // Reads: unknown, failed before write, failed after write, normal, last.
        for _ in 0..<4 { service.holdNext(.read).release() }
        let nextRead = expectation(description: "next read begins after normal receipt")
        let gate = service.holdNext(.read) { nextRead.fulfill() }
        defer { gate.release() }
        let done = expectation(description: "all targets attempted")
        session.restoreMinimizedWindows { merged in
            XCTAssertEqual(merged.map(\.id), [normal.id, last.id])
            done.fulfill()
        }
        await fulfillment(of: [nextRead], timeout: 3)
        XCTAssertEqual(session.minimizedWindows.map(\.id), [unknown.id, failed.id, last.id])
        gate.release()
        await fulfillment(of: [done], timeout: 3)
        XCTAssertEqual(session.minimizedWindows.map(\.id), [unknown.id, failed.id])
        XCTAssertEqual(service.snapshot.count(for: .restore), 1)
        service.setObservation(.init(state: .success(true), quality: .diagnostic), for: unknown.id)
        service.setWriteFailure(nil, minimized: false, for: failed.id)
        let retried = expectation(description: "failed targets can retry")
        session.restoreMinimizedWindows { _ in retried.fulfill() }
        await fulfillment(of: [retried], timeout: 3)
        XCTAssertTrue(session.minimizedWindows.isEmpty)
        XCTAssertFalse(service.snapshot.events.contains { $0.onMainThread })
    }

    @MainActor
    func testFailedWriteObservedNormalMergesWindowAndRetainsFailureDiagnostic() async throws {
        let service = ControlledMinimizationWindowService()
        let defaults = UserDefaults(suiteName: "RestoreMerge.\(UUID())")!
        let session = WorkspaceSessionController(workspaceStore: WorkspaceStore(defaults: defaults),
            defaults: defaults, windowServiceFactory: { service })
        let window = ledgerWindow()
        let identity = LiveWindowIdentity(window: window)
        let issue = WindowInspectionIssue(stage: .restoreMinimized, pid: window.pid,
            windowID: window.id, failure: .invalidValue)
        service.setObservation(.init(state: .success(true), quality: .diagnostic), for: window.id)
        service.setWriteFailure(issue, minimized: false, for: window.id)
        session.rememberMinimizedWindow(window)
        let started = expectation(description: "failed write held")
        let gate = service.holdNext(.restore) { started.fulfill() }
        defer { gate.release() }
        let done = expectation(description: "normal window merged")
        session.restoreMinimizedWindows { merged in
            XCTAssertEqual(merged.map(\.id), [window.id])
            done.fulfill()
        }
        await fulfillment(of: [started], timeout: 3)
        session.rememberMinimizedWindow(window)
        let newVersion = session.minimizedLedger[identity]?.entryVersion
        service.setObservation(.init(state: .success(false), quality: .diagnostic), for: window.id)
        gate.release()
        await fulfillment(of: [done], timeout: 3)
        XCTAssertEqual(session.minimizedLedger[identity]?.entryVersion, newVersion)
        XCTAssertEqual(session.statusMessage, "Restored 1 window(s). 1 window operation(s) reported an error.")
    }

    private func ledgerWindow(pid: pid_t = 72, number: CGWindowID = 11) -> WindowInfo {
        WindowInfo(id: "same", appName: "App", title: "old", pid: pid, bundleIdentifier: nil,
            bundleURL: nil, documentURL: nil, axWindow: AXUIElementCreateApplication(pid),
            windowNumber: number, position: nil)
    }

    private func ledgerReceipt(_ operation: MinimizationExecutionRequest, window: WindowInfo,
                               step: UInt64 = 1, desired: Bool = true, outcome: StepOutcome = .changed) -> StepReceipt {
        StepReceipt(operationID: operation.operationID, intentID: operation.intentID, stepID: step,
            identity: LiveWindowIdentity(window: window), window: window, desiredMinimized: desired,
            outcome: outcome, expectedLedgerVersion: nil)
    }

    @MainActor
    private func makeSession() -> WorkspaceSessionController {
        let defaults = UserDefaults(suiteName: "MinimizationTests.\(UUID())")!
        return WorkspaceSessionController(workspaceStore: WorkspaceStore(defaults: defaults), defaults: defaults)
    }

    @MainActor
    private func materialize(_ session: WorkspaceSessionController, _ intent: MinimizationIntentID,
                             _ target: UUID, empty: Bool = false) {
        session.materializeAutomaticRequest(intent: intent, resolution: .init(targetBoardID: target,
            composedReferenceIDs: empty ? [] : [UUID()], report: nil, switchRevision: 0, notBefore: .now))
    }
}
