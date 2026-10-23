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
