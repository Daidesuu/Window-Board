import ApplicationServices
import XCTest
@testable import WindowBoard

final class WorkspaceMinimizationTests: XCTestCase {
    @MainActor
    func testDeferredRecoveryReclassifiesFixedCandidatesWithoutEnumeration() async throws {
        let defaults = UserDefaults(suiteName: "DeferredReconcile.\(UUID())")!
        defaults.set(true, forKey: "minimizeUnattachedOnWorkspaceSwitch")
        let service = ControlledMinimizationWindowService()
        let old = ledgerWindow()
        let replacement = ledgerWindow(pid: 74, number: 14, id: "replacement")
        let reference = SavedWindowReference(id: UUID(), displayName: old.title, appName: old.appName,
            title: old.title, bundleIdentifier: nil, bundleURLString: nil, documentURLString: nil,
            workspaceURLString: nil, offsetX: 0, offsetY: 0)
        let store = WorkspaceStore(defaults: defaults)
        let board = store.saveWorkspace(name: "Recovered", windows: [reference])
        let session = WorkspaceSessionController(workspaceStore: store, defaults: defaults,
            windowServiceFactory: { service })
        service.setReport(.init(windows: [old], coverage: .complete, issues: [], failedPIDs: []))
        session.switchWorkspace(id: board.id, boardOrigin: nil, source: .mainWindow, followMode: .none,
            windowCache: [old], completion: { _ in })
        await waitForAutomaticIdle(session)
        let attachment = try XCTUnwrap(session.attachedWindows.first)
        let intent = try XCTUnwrap(session.latestMinimizationIntent?.id)
        try service.setMinimized(true, for: replacement)
        let before = service.snapshot.count(for: .list)
        let recovered = AttachedWindow(attachmentID: attachment.id, window: replacement,
            savedReference: attachment.savedReference, lastBoardOrigin: .zero,
            lastWindowOrigin: .zero, lastAppliedOrigin: nil, pendingReleaseOrigin: nil)
        session.applyDeferredRecovery([attachment.id: recovered], failedAttachments: [attachment],
            workspaceID: board.id, minimizationIntentID: intent)
        await waitForAutomaticIdle(session)
        XCTAssertEqual(service.snapshot.count(for: .list), before)
        XCTAssertTrue(service.snapshot.events.contains { $0.operation == .minimize && $0.windowID == old.id })
        XCTAssertTrue(service.snapshot.events.contains { $0.operation == .restore && $0.windowID == replacement.id })
        XCTAssertEqual(session.attachedWindows.first?.window.pid, replacement.pid)
    }

    @MainActor
    func testDeferredRecoveryEligibilityRejectsOffEmptyUnmaterializedAndOldIntent() async throws {
        for mode in ["off", "empty", "unmaterialized", "old"] {
            let session = makeSession()
            let target = session.workspaceStore.defaultWorkspace!.id
            session.activeWorkspaceID = target
            let intent = try XCTUnwrap(session.acceptSwitchIntent(target: target, automaticEnabled: mode != "off"))
            if mode != "unmaterialized" { materialize(session, intent, target, empty: mode == "empty") }
            if mode == "old" {
                _ = session.acceptSwitchIntent(target: target, automaticEnabled: true)
            }
            let old = AttachedWindow(window: ledgerWindow(), lastBoardOrigin: .zero,
                lastWindowOrigin: .zero, lastAppliedOrigin: nil, pendingReleaseOrigin: nil)
            session.attachedWindows = [old]
            let replacement = AttachedWindow(attachmentID: old.id, window: ledgerWindow(pid: 74),
                lastBoardOrigin: .zero, lastWindowOrigin: .zero, lastAppliedOrigin: nil, pendingReleaseOrigin: nil)
            session.applyDeferredRecovery([old.id: replacement], failedAttachments: [old],
                workspaceID: target, minimizationIntentID: intent)
            XCTAssertNil(session.pendingAutomaticMinimization, mode)
            XCTAssertNil(session.activeMinimizationOperation, mode)
            if mode == "old" { XCTAssertEqual(session.attachedWindows.first?.window.pid, old.window.pid) }
        }
    }

    @MainActor
    func testRecoveryWhileFullSnapshotPendingRevisitsFormerlyRegisteredCandidate() async throws {
        let defaults = UserDefaults(suiteName: "SnapshotPending.\(UUID())")!
        defaults.set(true, forKey: "minimizeUnattachedOnWorkspaceSwitch")
        let service = ControlledMinimizationWindowService()
        let old = ledgerWindow()
        let other = WindowInfo(id: "other", appName: "Other", title: "Other", pid: 81,
            bundleIdentifier: nil, bundleURL: nil, documentURL: nil,
            axWindow: AXUIElementCreateApplication(81), windowNumber: 25, position: nil)
        let replacement = ledgerWindow(pid: 74, number: 14, id: "replacement")
        let store = WorkspaceStore(defaults: defaults)
        let reference = SavedWindowReference(id: UUID(), displayName: old.title, appName: old.appName,
            title: old.title, bundleIdentifier: nil, bundleURLString: nil, documentURLString: nil,
            workspaceURLString: nil, offsetX: 0, offsetY: 0)
        let board = store.saveWorkspace(name: "Pending", windows: [reference])
        let session = WorkspaceSessionController(workspaceStore: store, defaults: defaults, windowServiceFactory: { service })
        service.setReport(.init(windows: [old, other], coverage: .complete, issues: [], failedPIDs: []))
        let started = expectation(description: "full worker has not returned its snapshot")
        let gate = service.holdNext(.minimize) { started.fulfill() }
        defer { gate.release() }
        session.switchWorkspace(id: board.id, boardOrigin: nil, source: .mainWindow, followMode: .none,
            windowCache: [old, other], completion: { _ in })
        await fulfillment(of: [started], timeout: 3)
        let attachment = try XCTUnwrap(session.attachedWindows.first)
        let intent = try XCTUnwrap(session.latestMinimizationIntent?.id)
        service.setObservation(.init(state: .success(true), quality: .diagnostic), for: replacement.id)
        let recovered = AttachedWindow(attachmentID: attachment.id, window: replacement,
            savedReference: reference, lastBoardOrigin: .zero, lastWindowOrigin: .zero,
            lastAppliedOrigin: nil, pendingReleaseOrigin: nil)
        let lists = service.snapshot.count(for: .list)
        session.applyDeferredRecovery([attachment.id: recovered], failedAttachments: [attachment],
            workspaceID: board.id, minimizationIntentID: intent)
        gate.release()
        await waitForAutomaticIdle(session)
        XCTAssertEqual(service.snapshot.count(for: .list), lists)
        XCTAssertTrue(service.snapshot.events.contains { $0.operation == .minimize && $0.windowID == old.id })
        XCTAssertTrue(service.snapshot.events.contains { $0.operation == .restore && $0.windowID == replacement.id })
        XCTAssertEqual(session.automaticMinimizationSummary.minimizedCount, 2)
        XCTAssertEqual(session.automaticMinimizationSummary.restoredCount, 1)
    }

    @MainActor
    func testBackgroundSwitchRecoveryUsesOriginalIntentAndReconciles() async throws {
        let defaults = UserDefaults(suiteName: "RealDeferredRoute.\(UUID())")!
        defaults.set(true, forKey: "minimizeUnattachedOnWorkspaceSwitch")
        defaults.set(true, forKey: "restoreMissingWindowsOnWorkspaceSwitch")
        let service = ControlledMinimizationWindowService()
        let replacement = ledgerWindow()
        let reference = SavedWindowReference(id: UUID(), displayName: replacement.title, appName: replacement.appName,
            title: replacement.title, bundleIdentifier: nil, bundleURLString: nil, documentURLString: nil,
            workspaceURLString: nil, offsetX: 0, offsetY: 0)
        let store = WorkspaceStore(defaults: defaults)
        let board = store.saveWorkspace(name: "Missing", windows: [reference])
        let session = WorkspaceSessionController(workspaceStore: store, defaults: defaults, windowServiceFactory: { service })
        // Resolution sees no window; hold the existing background recovery's poll.
        service.holdNext(.list).release()
        let polling = expectation(description: "background recovery poll")
        let gate = service.holdNext(.list) { polling.fulfill() }
        defer { gate.release() }
        session.switchWorkspace(id: board.id, boardOrigin: nil, source: .mainWindow, followMode: .none,
            windowCache: [], completion: { _ in })
        await fulfillment(of: [polling], timeout: 3)
        await waitForAutomaticIdle(session)
        let intent = session.latestMinimizationIntent?.id
        XCTAssertEqual(session.automaticMinimizationSummary.registeredCount, 0)
        service.setReport(.init(windows: [replacement], coverage: .complete, issues: [], failedPIDs: []))
        gate.release()
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while (session.attachedWindows.first?.window.pid != replacement.pid ||
               session.automaticMinimizationSummary.noOpCount != 1), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        await waitForAutomaticIdle(session)
        XCTAssertEqual(session.latestMinimizationIntent?.id, intent)
        XCTAssertEqual(session.attachedWindows.first?.window.pid, replacement.pid)
        XCTAssertEqual(session.automaticMinimizationSummary.noOpCount, 1)
        XCTAssertEqual(service.snapshot.count(for: .list), 2)
    }

    @MainActor
    func testReconcileRetainsFailureAndAutomaticSnapshotAfterManualCompletion() async throws {
        let defaults = UserDefaults(suiteName: "SummarySnapshot.\(UUID())")!
        defaults.set(true, forKey: "minimizeUnattachedOnWorkspaceSwitch")
        let service = ControlledMinimizationWindowService()
        let old = ledgerWindow()
        let failed = WindowInfo(id: "failed", appName: "Other", title: "Other", pid: 81,
            bundleIdentifier: nil, bundleURL: nil, documentURL: nil,
            axWindow: AXUIElementCreateApplication(81), windowNumber: 25, position: nil)
        let replacement = ledgerWindow(pid: 74, number: 14, id: "replacement")
        let reference = SavedWindowReference(id: UUID(), displayName: old.title, appName: old.appName,
            title: old.title, bundleIdentifier: nil, bundleURLString: nil, documentURLString: nil,
            workspaceURLString: nil, offsetX: 0, offsetY: 0)
        let store = WorkspaceStore(defaults: defaults)
        let board = store.saveWorkspace(name: "Summary", windows: [reference])
        let session = WorkspaceSessionController(workspaceStore: store, defaults: defaults, windowServiceFactory: { service })
        let enumerationIssue = WindowInspectionIssue(stage: .enumerateWindows, pid: 90,
            windowID: nil, failure: .invalidValue)
        service.setReport(.init(windows: [old, failed], coverage: .partial, issues: [enumerationIssue], failedPIDs: [90]))
        let issue = WindowInspectionIssue(stage: .writeMinimized, pid: failed.pid,
            windowID: failed.id, failure: .invalidValue)
        service.setWriteFailure(issue, minimized: true, for: failed.id)
        session.switchWorkspace(id: board.id, boardOrigin: nil, source: .mainWindow, followMode: .none,
            windowCache: [old, failed], completion: { _ in })
        await waitForAutomaticIdle(session)
        XCTAssertEqual(session.automaticMinimizationSummary.writeFailureCount, 1)
        // A manual operation with a different, empty snapshot must not replace
        // the automatic intent's retained candidate set.
        session.minimizeUnattachedWindows(knownWindows: [], refreshWindowList: false,
            mergeWindows: { _ in }, removeWindows: { _ in })
        await waitForAutomaticIdle(session)
        service.setWriteFailure(nil, minimized: true, for: failed.id)
        service.setObservation(.init(state: .success(true), quality: .diagnostic), for: failed.id)
        let attachment = try XCTUnwrap(session.attachedWindows.first)
        let intent = try XCTUnwrap(session.latestMinimizationIntent?.id)
        let recovered = AttachedWindow(attachmentID: attachment.id, window: replacement,
            savedReference: reference, lastBoardOrigin: .zero, lastWindowOrigin: .zero,
            lastAppliedOrigin: nil, pendingReleaseOrigin: nil)
        session.applyDeferredRecovery([attachment.id: recovered], failedAttachments: [attachment],
            workspaceID: board.id, minimizationIntentID: intent)
        await waitForAutomaticIdle(session)
        XCTAssertTrue(service.snapshot.events.contains { $0.operation == .minimize && $0.windowID == old.id })
        XCTAssertEqual(session.automaticMinimizationSummary.candidateCount, 2)
        XCTAssertEqual(session.automaticMinimizationSummary.writeFailureCount, 1)
        // A further reconciliation performs no successful write, but cannot
        // erase the failure from this same switch.
        session.applyDeferredRecovery([attachment.id: recovered], failedAttachments: [attachment],
            workspaceID: board.id, minimizationIntentID: intent)
        await waitForAutomaticIdle(session)
        XCTAssertEqual(session.automaticMinimizationSummary.writeFailureCount, 1)
        XCTAssertEqual(session.automaticMinimizationSummary.minimizedCount, 1)
        XCTAssertEqual(session.automaticMinimizationSummary.issues.filter { $0 == enumerationIssue }.count, 1)
        XCTAssertTrue(session.statusMessage.contains("1 operation(s) failed."))
    }

    @MainActor
    func testManualPreparationOwnsSlotAndStalePreparationHandsOffToLatestBoard() async throws {
        let defaults = UserDefaults(suiteName: "ManualPreparation.\(UUID())")!
        defaults.set(true, forKey: "minimizeUnattachedOnWorkspaceSwitch")
        let service = ControlledMinimizationWindowService()
        let old = ledgerWindow()
        let latest = WindowInfo(id: "latest", appName: "Other", title: "Latest", pid: 73,
            bundleIdentifier: nil, bundleURL: nil, documentURL: nil,
            axWindow: AXUIElementCreateApplication(73), windowNumber: 12, position: nil)
        let store = WorkspaceStore(defaults: defaults)
        let reference = SavedWindowReference(id: UUID(), displayName: latest.title, appName: latest.appName,
            title: latest.title, bundleIdentifier: nil, bundleURLString: nil, documentURLString: nil,
            workspaceURLString: nil, offsetX: 0, offsetY: 0)
        let board = store.saveWorkspace(name: "Latest", windows: [reference])
        let session = WorkspaceSessionController(workspaceStore: store, defaults: defaults, windowServiceFactory: { service })
        service.setReport(.init(windows: [old, latest], coverage: .complete, issues: [], failedPIDs: []))
        let preparing = expectation(description: "manual preparation")
        let gate = service.holdNext(.list) { preparing.fulfill() }
        defer { gate.release() }
        var callbackCount = 0
        session.minimizeUnattachedWindows(knownWindows: [old], refreshWindowList: true,
            mergeWindows: { _ in callbackCount += 1 }, removeWindows: { _ in callbackCount += 1 })
        await fulfillment(of: [preparing], timeout: 3)
        let manual = try XCTUnwrap(session.activeMinimizationOperation)
        XCTAssertEqual(manual.kind, .manual)
        let displayed = expectation(description: "latest displayed")
        session.switchWorkspace(id: board.id, boardOrigin: nil, source: .mainWindow, followMode: .none,
            windowCache: [latest], completion: { _ in displayed.fulfill() })
        await fulfillment(of: [displayed], timeout: 3)
        XCTAssertEqual(session.activeMinimizationOperation?.operationID, manual.operationID)
        gate.release()
        await waitForAutomaticIdle(session)
        XCTAssertEqual(session.attachedWindows.map(\.window.id), [latest.id])
        XCTAssertEqual(callbackCount, 0)
        XCTAssertEqual(service.snapshot.events.filter { $0.operation == .minimize && $0.phase == .started }.map(\.windowID), [old.id])
        XCTAssertEqual(service.snapshot.count(for: .list), 2)
    }

    @MainActor
    func testManualInflightSuccessOrFailureKeepsLatestWorkerBusyAndPhysicalLedger() async throws {
        for fail in [false, true] {
            let defaults = UserDefaults(suiteName: "ManualInflight.\(UUID())")!
            defaults.set(true, forKey: "minimizeUnattachedOnWorkspaceSwitch")
            let service = ControlledMinimizationWindowService()
            let other = ledgerWindow()
            let registered = WindowInfo(id: "registered", appName: "Other", title: "Registered", pid: 73,
                bundleIdentifier: nil, bundleURL: nil, documentURL: nil,
                axWindow: AXUIElementCreateApplication(73), windowNumber: 12, position: nil)
            let store = WorkspaceStore(defaults: defaults)
            let reference = SavedWindowReference(id: UUID(), displayName: registered.title, appName: registered.appName,
                title: registered.title, bundleIdentifier: nil, bundleURLString: nil, documentURLString: nil,
                workspaceURLString: nil, offsetX: 0, offsetY: 0)
            let board = store.saveWorkspace(name: "Latest", windows: [reference])
            let session = WorkspaceSessionController(workspaceStore: store, defaults: defaults, windowServiceFactory: { service })
            service.setReport(.init(windows: [registered, other], coverage: .complete, issues: [], failedPIDs: []))
            if fail {
                service.setWriteFailure(.init(stage: .writeMinimized, pid: registered.pid,
                    windowID: registered.id, failure: .invalidValue), minimized: true, for: registered.id)
            }
            let manualWriting = expectation(description: "manual write in flight")
            let oldGate = service.holdNext(.minimize) { manualWriting.fulfill() }
            defer { oldGate.release() }
            var callbacks = 0
            session.minimizeUnattachedWindows(knownWindows: [registered],
                removeWindows: { _ in callbacks += 1 })
            await fulfillment(of: [manualWriting], timeout: 3)
            let manual = try XCTUnwrap(session.activeMinimizationOperation)
            let displayed = expectation(description: "latest displayed")
            session.switchWorkspace(id: board.id, boardOrigin: nil, source: .mainWindow, followMode: .none,
                windowCache: [registered], completion: { _ in displayed.fulfill() })
            await fulfillment(of: [displayed], timeout: 3)
            let latestWriting = expectation(description: "latest worker started")
            let latestGate = service.holdNext(.minimize) { latestWriting.fulfill() }
            defer { latestGate.release() }
            oldGate.release()
            await fulfillment(of: [latestWriting], timeout: 3)
            XCTAssertTrue(session.isMinimizingUnattached)
            XCTAssertNotEqual(session.activeMinimizationOperation?.operationID, manual.operationID)
            XCTAssertEqual(session.minimizedWindows.map(\.id), fail ? [] : [registered.id])
            XCTAssertEqual(callbacks, 0)
            latestGate.release()
            await waitForAutomaticIdle(session)
            XCTAssertEqual(session.minimizedWindows.map(\.id), [other.id])
            XCTAssertEqual(service.snapshot.count(for: .restore), fail ? 0 : 1)
            XCTAssertNil(session.pendingAutomaticMinimization)
            XCTAssertNil(session.activeMinimizationOperation)
        }
    }

    @MainActor
    func testEmptyManualFinishesAndDoesNotResubmitCompletedAutomaticWork() async throws {
        let defaults = UserDefaults(suiteName: "ManualEmpty.\(UUID())")!
        let service = ControlledMinimizationWindowService()
        let session = WorkspaceSessionController(workspaceStore: WorkspaceStore(defaults: defaults),
            defaults: defaults, windowServiceFactory: { service })
        session.minimizeUnattachedWindows(knownWindows: [])
        XCTAssertNotNil(session.activeMinimizationOperation)
        await waitForAutomaticIdle(session)
        XCTAssertNil(session.activeMinimizationOperation)
        XCTAssertNil(session.pendingAutomaticMinimization)
        XCTAssertEqual(service.snapshot.count(for: .list), 0)
        XCTAssertEqual(service.snapshot.count(for: .minimize), 0)
        XCTAssertEqual(session.statusMessage, "No other windows to minimize.")
    }

    @MainActor
    func testManualPreparationDoesNotOverwriteReconnectedAttachmentInSameIntent() async throws {
        let defaults = UserDefaults(suiteName: "ManualIdentity.\(UUID())")!
        let service = ControlledMinimizationWindowService()
        let original = ledgerWindow()
        let replacement = ledgerWindow(pid: 74, number: 14)
        let session = WorkspaceSessionController(workspaceStore: WorkspaceStore(defaults: defaults),
            defaults: defaults, windowServiceFactory: { service })
        session.attachedWindows = [AttachedWindow(window: original, lastBoardOrigin: .zero,
            lastWindowOrigin: .zero, lastAppliedOrigin: nil, pendingReleaseOrigin: nil)]
        service.setReport(.init(windows: [original], coverage: .complete, issues: [], failedPIDs: []))
        let preparing = expectation(description: "manual list blocked")
        let gate = service.holdNext(.list) { preparing.fulfill() }
        defer { gate.release() }
        session.minimizeUnattachedWindows(knownWindows: [], refreshWindowList: true)
        await fulfillment(of: [preparing], timeout: 3)
        let operation = try XCTUnwrap(session.activeMinimizationOperation)
        session.attachedWindows[0].window = replacement
        gate.release()
        await waitForAutomaticIdle(session)
        XCTAssertEqual(session.attachedWindows[0].window.pid, replacement.pid)
        XCTAssertTrue(session.attachedWindows[0].window.axWindow === replacement.axWindow)
        XCTAssertEqual(operation.kind, .manual)
        XCTAssertEqual(service.snapshot.count(for: .list), 1)
    }

    @MainActor
    func testManualInflightReceiptRetainsLedgerButDoesNotRemoveReplacementUI() async throws {
        let defaults = UserDefaults(suiteName: "ManualReceiptIdentity.\(UUID())")!
        let service = ControlledMinimizationWindowService()
        let original = ledgerWindow()
        let replacement = ledgerWindow(pid: 74, number: 14)
        let session = WorkspaceSessionController(workspaceStore: WorkspaceStore(defaults: defaults),
            defaults: defaults, windowServiceFactory: { service })
        let writing = expectation(description: "manual write blocked")
        let gate = service.holdNext(.minimize) { writing.fulfill() }
        defer { gate.release() }
        var removed = Set<WindowInfo.ID>()
        session.minimizeUnattachedWindows(knownWindows: [original], removeWindows: { removed.formUnion($0) })
        await fulfillment(of: [writing], timeout: 3)
        session.attachedWindows = [AttachedWindow(window: replacement, lastBoardOrigin: .zero,
            lastWindowOrigin: .zero, lastAppliedOrigin: nil, pendingReleaseOrigin: nil)]
        gate.release()
        await waitForAutomaticIdle(session)
        XCTAssertTrue(removed.isEmpty)
        XCTAssertEqual(session.minimizedWindows.first?.pid, original.pid)
        XCTAssertTrue(session.attachedWindows.first?.window.axWindow === replacement.axWindow)
    }

    @MainActor
    func testManualRefreshReusesOneReportAndKnownModeDoesNotEnumerate() async throws {
        for refresh in [false, true] {
            let service = ControlledMinimizationWindowService()
            let window = ledgerWindow()
            service.setReport(.init(windows: [window], coverage: .unverifiedLegacy, issues: [], failedPIDs: []))
            let defaults = UserDefaults(suiteName: "ManualEnumeration.\(UUID())")!
            let session = WorkspaceSessionController(workspaceStore: WorkspaceStore(defaults: defaults),
                defaults: defaults, windowServiceFactory: { service })
            session.minimizeUnattachedWindows(knownWindows: [window], refreshWindowList: refresh)
            await waitForAutomaticIdle(session)
            XCTAssertEqual(service.snapshot.count(for: .list), refresh ? 1 : 0)
            XCTAssertEqual(service.snapshot.count(for: .minimize), 1)
            XCTAssertEqual(session.minimizedWindows.map(\.id), [window.id])
            XCTAssertFalse(service.snapshot.events.contains { $0.onMainThread })
        }
    }

    @MainActor
    func testCachedSwitchPublishesBeforeCandidateRefreshAndMinimizesNewWindow() async throws {
        let defaults = UserDefaults(suiteName: "AutoIntegration.\(UUID())")!
        defaults.set(true, forKey: "minimizeUnattachedOnWorkspaceSwitch")
        let service = ControlledMinimizationWindowService()
        let registered = ledgerWindow(pid: 72, number: 11)
        let other = WindowInfo(id: "new", appName: "Other", title: "new", pid: 73,
            bundleIdentifier: nil, bundleURL: nil, documentURL: nil,
            axWindow: AXUIElementCreateApplication(73), windowNumber: 12, position: nil)
        let reference = SavedWindowReference(id: UUID(), displayName: "old", appName: "App", title: "old",
            bundleIdentifier: nil, bundleURLString: nil, documentURLString: nil, workspaceURLString: nil,
            offsetX: 0, offsetY: 0)
        let store = WorkspaceStore(defaults: defaults)
        let board = store.saveWorkspace(name: "Target", windows: [reference])
        let session = WorkspaceSessionController(workspaceStore: store, defaults: defaults,
            windowServiceFactory: { service })
        service.setReport(.init(windows: [registered, other], coverage: .complete, issues: [], failedPIDs: []))
        let listed = expectation(description: "post-display candidate refresh")
        let gate = service.holdNext(.list) { listed.fulfill() }
        defer { gate.release() }
        let displayed = expectation(description: "board displayed")
        session.switchWorkspace(id: board.id, boardOrigin: nil, source: .mainWindow, followMode: .none,
            windowCache: [registered], completion: { _ in displayed.fulfill() })
        await fulfillment(of: [displayed, listed], timeout: 3)
        XCTAssertEqual(session.activeWorkspaceID, board.id)
        XCTAssertEqual(session.attachedWindows.first?.window.id, registered.id)
        XCTAssertFalse(session.isLoadingWorkspace)
        let written = expectation(description: "new target minimized")
        let write = service.holdNext(.minimize) { written.fulfill() }
        gate.release()
        await fulfillment(of: [written], timeout: 3)
        write.release()
        await waitForAutomaticIdle(session)
        XCTAssertEqual(service.snapshot.count(for: .list), 1)
        XCTAssertEqual(service.snapshot.events.filter { $0.operation == .minimize && $0.phase == .started }.map(\.windowID), [other.id])
        XCTAssertFalse(service.snapshot.events.contains { $0.onMainThread })
    }

    @MainActor
    func testSwitchResolutionReportReusedAndOffOrEmptyAddsNoFeatureCalls() async throws {
        for mode in ["report", "off", "empty", "included"] {
            let defaults = UserDefaults(suiteName: "AutoBoundary.\(UUID())")!
            defaults.set(mode != "off", forKey: "minimizeUnattachedOnWorkspaceSwitch")
            let service = ControlledMinimizationWindowService()
            let registered = ledgerWindow()
            let reference = SavedWindowReference(id: UUID(), displayName: "old", appName: "App", title: "old",
                bundleIdentifier: nil, bundleURLString: nil, documentURLString: nil, workspaceURLString: nil,
                offsetX: 0, offsetY: 0)
            let store = WorkspaceStore(defaults: defaults)
            let board = store.saveWorkspace(name: mode, windows: ["empty", "included"].contains(mode) ? [] : [reference])
            let composition = BoardCompositionStore(defaults: defaults)
            if mode == "included" {
                let included = store.saveWorkspace(name: "Included", windows: [reference])
                _ = composition.includeRoot(included.id, for: board.id,
                    availableBoardIDs: Set(store.workspaces.map(\.id)))
            }
            let session = WorkspaceSessionController(workspaceStore: store, defaults: defaults,
                boardCompositionStore: composition, windowServiceFactory: { service })
            service.setReport(.init(windows: [registered], coverage: .complete, issues: [], failedPIDs: []))
            let displayed = expectation(description: "displayed \(mode)")
            session.switchWorkspace(id: board.id, boardOrigin: nil, source: .mainWindow, followMode: .none,
                windowCache: mode == "report" ? nil : [registered], completion: { _ in displayed.fulfill() })
            await fulfillment(of: [displayed], timeout: 3)
            await waitForAutomaticIdle(session)
            // Resolution itself enumerates once only when no cache is provided.
            XCTAssertEqual(service.snapshot.count(for: .list), ["report", "included"].contains(mode) ? 1 : 0)
            XCTAssertEqual(service.snapshot.count(for: .minimize), 0)
            XCTAssertEqual(service.snapshot.count(for: .restore), 0)
        }
    }

    @MainActor
    func testInflightOldSuccessRecordedAndLatestSwitchRestoresItsAttachment() async throws {
        let defaults = UserDefaults(suiteName: "AutoHandoff.\(UUID())")!
        defaults.set(true, forKey: "minimizeUnattachedOnWorkspaceSwitch")
        let service = ControlledMinimizationWindowService()
        let a = ledgerWindow()
        let b = WindowInfo(id: "b", appName: "Other", title: "B", pid: 73, bundleIdentifier: nil,
            bundleURL: nil, documentURL: nil, axWindow: AXUIElementCreateApplication(73),
            windowNumber: 12, position: nil)
        func reference(_ window: WindowInfo) -> SavedWindowReference {
            SavedWindowReference(id: UUID(), displayName: window.title, appName: window.appName, title: window.title,
                bundleIdentifier: nil, bundleURLString: nil, documentURLString: nil, workspaceURLString: nil,
                offsetX: 0, offsetY: 0)
        }
        let store = WorkspaceStore(defaults: defaults)
        let boardA = store.saveWorkspace(name: "A", windows: [reference(a)])
        let boardB = store.saveWorkspace(name: "B", windows: [reference(b)])
        let session = WorkspaceSessionController(workspaceStore: store, defaults: defaults,
            windowServiceFactory: { service })
        service.setReport(.init(windows: [a, b], coverage: .complete, issues: [], failedPIDs: []))
        let oldWrite = expectation(description: "old minimizes B inflight")
        let gate = service.holdNext(.minimize) { oldWrite.fulfill() }
        defer { gate.release() }
        session.switchWorkspace(id: boardA.id, boardOrigin: nil, source: .mainWindow, followMode: .none,
            windowCache: [a, b])
        await fulfillment(of: [oldWrite], timeout: 3)
        let newDisplayed = expectation(description: "latest B displayed before old write completes")
        session.switchWorkspace(id: boardB.id, boardOrigin: nil, source: .mainWindow, followMode: .none,
            windowCache: [a, b], completion: { _ in newDisplayed.fulfill() })
        await fulfillment(of: [newDisplayed], timeout: 3)
        XCTAssertEqual(session.activeWorkspaceID, boardB.id)
        gate.release()
        await waitForAutomaticIdle(session)
        XCTAssertEqual(session.activeWorkspaceID, boardB.id)
        XCTAssertEqual(service.snapshot.count(for: .minimize), 2)
        XCTAssertEqual(service.snapshot.count(for: .restore), 1)
        XCTAssertEqual(session.minimizedWindows.map(\.id), [a.id])
        XCTAssertNil(session.pendingAutomaticMinimization)
        XCTAssertNil(session.activeMinimizationOperation)
        let writes = service.snapshot.events.filter { $0.operation == .minimize || $0.operation == .restore }
        var activeWrites = 0
        for event in writes {
            activeWrites += event.phase == .started ? 1 : -1
            XCTAssertLessThanOrEqual(activeWrites, 1)
        }
        XCTAssertEqual(activeWrites, 0)
    }

    @MainActor
    private func waitForAutomaticIdle(_ session: WorkspaceSessionController) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        // Include the layout-to-materialization turn after display publication.
        repeat {
            try? await Task.sleep(for: .milliseconds(5))
            if !session.isLoadingWorkspace && !session.isApplyingWorkspaceWindows &&
                !session.isMinimizingUnattached && session.pendingAutomaticMinimization == nil &&
                session.activeMinimizationOperation == nil { return }
        } while ContinuousClock.now < deadline
        XCTFail("automatic minimization did not settle")
    }

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

    private func ledgerWindow(pid: pid_t = 72, number: CGWindowID = 11, id: String = "same") -> WindowInfo {
        WindowInfo(id: id, appName: "App", title: "old", pid: pid, bundleIdentifier: nil,
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
