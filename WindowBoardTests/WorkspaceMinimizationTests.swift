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
