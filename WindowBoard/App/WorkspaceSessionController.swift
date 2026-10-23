import AppKit
import ApplicationServices
import Combine
import Foundation
import OSLog

#if DEBUG
private let workspaceSessionLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "WindowBoard",
    category: "WorkspaceSession"
)
#endif

enum WorkspaceSwitchSource {
    case mainWindow
    case statusItem
    case launcher
}

struct BoardSwitchTarget: Identifiable, Equatable {
    let primaryBoardID: SavedWorkspace.ID
    let selectedBoardID: SavedWorkspace.ID
    let board: SavedWorkspace

    var id: String {
        "\(primaryBoardID.uuidString)/\(selectedBoardID.uuidString)"
    }
}

enum AttachedWindowSessionState: Equatable {
    case resolving
    case reconnecting
    case unavailable
    case minimized
    case available
}

struct AttachedWindowSessionSnapshot: Identifiable, Equatable {
    let id: AttachedWindow.ID
    let windowID: WindowInfo.ID
    let appName: String
    let title: String
    let displayName: String
    let bundleIdentifier: String?
    let ownerBoardID: SavedWorkspace.ID?
    let ownerBoardName: String?
    let isFromPrimaryBoard: Bool
    let state: AttachedWindowSessionState
}

enum SessionAttachedWindowInsertion {
    case start
    case end
}

enum SessionWindowAttachResult: Equatable {
    case attached(AttachedWindow.ID)
    case updatedExisting(AttachedWindow.ID)
    case noActiveBoard
    case missingWindowPosition

    var didAttach: Bool {
        switch self {
        case .attached, .updatedExisting:
            true
        case .noActiveBoard, .missingWindowPosition:
            false
        }
    }
}

enum BoardWindowMutationResult: Equatable {
    case moved
    case reordered
    case missingWindow
    case missingBoard
    case duplicate
    case busy

    var userMessage: String {
        switch self {
        case .moved:
            "Moved window to board."
        case .reordered:
            "Updated window order."
        case .missingWindow:
            "Window is no longer attached."
        case .missingBoard:
            "Board not found."
        case .duplicate:
            "That window is already on this board."
        case .busy:
            "Wait for window recovery to finish."
        }
    }
}

private struct SessionRestoreWindowsResult {
    let restoredWindows: [WindowInfo]
    let failedWindows: [WindowInfo]
}

private struct SessionWindowApplicationResult {
    let appliedWindows: [AttachedWindow]
    let failedAttachments: [AttachedWindow]
    let skippedPositionCount: Int
    let setPositionCount: Int
    let setSizeCount: Int
    let failedLayoutCount: Int
}

private enum LayoutOperationResult {
    case skipped
    case applied
    case failed
}

final class WorkspaceSessionController: ObservableObject {
    private struct PendingWorkspaceSwitch {
        let workspaceID: SavedWorkspace.ID
        let minimizationIntentID: MinimizationIntentID
        let selectedBoardID: SavedWorkspace.ID?
        let boardOrigin: CGPoint?
        let source: WorkspaceSwitchSource
        let followMode: FollowMode
        let windowCache: [WindowInfo]?
        let mergeWindows: @MainActor ([WindowInfo]) -> Void
        let completion: @MainActor (_ shouldBringBoardToFront: Bool) -> Void
        let deferredWindowApplicationCompletion: @MainActor () -> Void
        let minimizeAfterSwitchCompletion: @MainActor () -> Void
    }

    struct SwitchMinimizationIntent {
        let id: MinimizationIntentID
        let target: SavedWorkspace.ID
        let automaticEnabled: Bool
        let source: WorkspaceSwitchSource
        let notBefore: ContinuousClock.Instant
        let windowCache: [WindowInfo]
        let minimizeAfterSwitchCompletion: @MainActor () -> Void
    }

    @Published private(set) var minimizationProgress: MinimizationProgress = .notRequested
    @MainActor private var activeMinimizationPhase: MinimizationProgress = .preparing

    @MainActor var displayStatusMessage: String {
        switch minimizationProgress {
        case .waiting, .preparing, .running:
            return "Board displayed; processing windows..."
        case .notRequested, .completed:
            return statusMessage
        }
    }

    @MainActor
    private func updateMinimizationProgress() {
        let pending = pendingAutomaticMinimization?.intentID == latestMinimizationIntent?.id
            && pendingAutomaticMinimization != nil
        let busy = activeMinimizationOperation != nil || pending
        if isMinimizingUnattached != busy { isMinimizingUnattached = busy }
        if pending {
            minimizationProgress = .waiting
        } else if let active = activeMinimizationOperation, isCurrentMinimizationOperation(active) {
            minimizationProgress = activeMinimizationPhase
        } else if activeMinimizationOperation != nil {
            minimizationProgress = .waiting
        } else {
            switch minimizationProgress {
            case .waiting, .preparing, .running: minimizationProgress = .notRequested
            case .notRequested, .completed: break
            }
        }
    }

    @MainActor
    private func prepareMinimization(_ request: MinimizationExecutionRequest) {
        guard isCurrentMinimizationOperation(request) else { return }
        activeMinimizationPhase = .preparing
        updateMinimizationProgress()
    }

    @MainActor private var minimizationGeneration: UInt64 = 0
    @MainActor private(set) var latestMinimizationIntent: SwitchMinimizationIntent?
    @MainActor private(set) var pendingAutomaticMinimization: MinimizationExecutionRequest?
    @MainActor private(set) var activeMinimizationOperation: MinimizationExecutionRequest?
    @MainActor private var materializedMinimizationIntent: MinimizationIntentID?
    @MainActor private var minimizationWorker: (id: UUID, task: Task<Void, Never>)?
    @MainActor private var minimizationCandidateSnapshot: CandidateSnapshot?
    @MainActor private var deferredReconcileIntent: MinimizationIntentID?
    @MainActor private(set) var automaticMinimizationSummary = OperationSummary()
    @MainActor private var automaticSummaryReceipts: Set<StepReceiptID> = []
    @MainActor private var summarizedEnumerationOperations: Set<UUID> = []
    @MainActor private var hasSummarizedAutomaticCandidateReport = false
    @MainActor private var minimizationKnownWindows: [WindowInfo] = []

    @MainActor
    @discardableResult
    func acceptSwitchIntent(
        target: SavedWorkspace.ID,
        automaticEnabled: Bool,
        source: WorkspaceSwitchSource = .mainWindow,
        notBefore: ContinuousClock.Instant = .now,
        windowCache: [WindowInfo] = [],
        minimizeAfterSwitchCompletion: @escaping @MainActor () -> Void = {}
    ) -> MinimizationIntentID? {
        defer { updateMinimizationProgress() }
        guard workspaceStore.workspaces.contains(where: { $0.id == target }) else { return nil }
        minimizationGeneration += 1
        let id = MinimizationIntentID(value: minimizationGeneration)
        latestMinimizationIntent = SwitchMinimizationIntent(
            id: id, target: target, automaticEnabled: automaticEnabled,
            source: source, notBefore: notBefore, windowCache: windowCache,
            minimizeAfterSwitchCompletion: minimizeAfterSwitchCompletion
        )
        minimizationProgress = .notRequested
        pendingAutomaticMinimization = nil
        materializedMinimizationIntent = nil
        minimizationCandidateSnapshot = nil
        deferredReconcileIntent = nil
        automaticMinimizationSummary = OperationSummary()
        automaticSummaryReceipts.removeAll()
        summarizedEnumerationOperations.removeAll()
        hasSummarizedAutomaticCandidateReport = false
        minimizationKnownWindows = Self.mergeMinimizationWindows(windowCache, fallback: minimizationKnownWindows)
        minimizationWorker?.task.cancel()
        return id
    }

    @MainActor
    func materializeAutomaticRequest(intent: MinimizationIntentID, resolution: MinimizationResolution) {
        defer { updateMinimizationProgress() }
        guard let latest = latestMinimizationIntent, latest.id == intent,
              latest.target == resolution.targetBoardID else { return }
        guard latest.automaticEnabled, !resolution.composedReferenceIDs.isEmpty else {
            pendingAutomaticMinimization = nil
            materializedMinimizationIntent = nil
            return
        }
        guard materializedMinimizationIntent != intent else { return }
        materializedMinimizationIntent = intent
        let source: CandidateSource
        if let report = resolution.report {
            source = .reuse(CandidateSnapshot(report: report, origin: .switchResolution,
                intentID: intent, capturedAt: .now, fallback: minimizationKnownWindows))
        } else {
            source = .refresh(fallback: minimizationKnownWindows)
        }
        pendingAutomaticMinimization = MinimizationExecutionRequest(
            intentID: intent, operationID: UUID(), kind: .automatic, candidateSource: source
        )
    }

    @MainActor
    func requestMinimizationReconcile(intent: MinimizationIntentID, snapshot: CandidateSnapshot) {
        defer { updateMinimizationProgress() }
        guard latestMinimizationIntent?.id == intent,
              latestMinimizationIntent?.automaticEnabled == true,
              materializedMinimizationIntent == intent,
              snapshot.intentID == intent else { return }
        if pendingAutomaticMinimization?.kind == .automatic { return }
        pendingAutomaticMinimization = MinimizationExecutionRequest(
            intentID: intent, operationID: UUID(), kind: .reconcile, candidateSource: .reuse(snapshot)
        )
    }

    @MainActor
    private func reconcileAfterDeferredRecovery(intent: MinimizationIntentID) {
        guard latestMinimizationIntent?.id == intent,
              latestMinimizationIntent?.automaticEnabled == true,
              materializedMinimizationIntent == intent else { return }
        // Full pending work observes current protection when it starts. During a
        // full worker retain the request until its fixed snapshot is returned.
        if pendingAutomaticMinimization?.kind == .automatic { return }
        guard let snapshot = minimizationCandidateSnapshot else {
            if activeMinimizationOperation?.intentID == intent,
               activeMinimizationOperation?.kind == .automatic {
                deferredReconcileIntent = intent
            }
            return
        }
        requestMinimizationReconcile(intent: intent, snapshot: snapshot)
        drainAutomaticMinimization()
    }

    /// Consumes pending work only when the shared manual/automatic slot is free.
    @MainActor
    @discardableResult
    func takeNextMinimizationOperation() -> MinimizationExecutionRequest? {
        defer { updateMinimizationProgress() }
        guard activeMinimizationOperation == nil,
              let pending = pendingAutomaticMinimization,
              pending.intentID == latestMinimizationIntent?.id else { return nil }
        pendingAutomaticMinimization = nil
        activeMinimizationPhase = .waiting
        activeMinimizationOperation = pending
        return pending
    }

    @MainActor
    @discardableResult
    func startManualMinimizationOperation(candidateSource: CandidateSource) -> MinimizationExecutionRequest? {
        defer { updateMinimizationProgress() }
        guard activeMinimizationOperation == nil, pendingAutomaticMinimization == nil,
              !isMinimizingUnattached, !isRestoringMinimized else { return nil }
        let request = MinimizationExecutionRequest(
            intentID: latestMinimizationIntent?.id ?? MinimizationIntentID(value: minimizationGeneration),
            operationID: UUID(), kind: .manual, candidateSource: candidateSource
        )
        activeMinimizationPhase = .preparing
        activeMinimizationOperation = request
        return request
    }

    @MainActor
    func isCurrentMinimizationOperation(_ request: MinimizationExecutionRequest) -> Bool {
        activeMinimizationOperation?.operationID == request.operationID
            && request.intentID == (latestMinimizationIntent?.id ?? MinimizationIntentID(value: minimizationGeneration))
    }

    /// Returns ownership of the next request to the caller that will launch its worker.
    @MainActor
    @discardableResult
    func finishOperation(_ result: MinimizationOperationResult, summary: OperationSummary? = nil) -> MinimizationExecutionRequest? {
        defer { updateMinimizationProgress() }
        guard activeMinimizationOperation?.operationID == result.operationID,
              activeMinimizationOperation?.intentID == result.intentID else { return nil }
        completedMinimizationOperations.insert(result.operationID)
        recordedMinimizationReceipts = recordedMinimizationReceipts.filter { $0.operationID != result.operationID }
        if let active = activeMinimizationOperation, isCurrentMinimizationOperation(active) {
            minimizationProgress = .completed(summary ?? result.summary)
        }
        activeMinimizationOperation = nil
        return takeNextMinimizationOperation()
    }

    let workspaceStore: WorkspaceStore

    @Published var selectedWorkspaceID: SavedWorkspace.ID?
    @Published var activeWorkspaceID: SavedWorkspace.ID? {
        didSet {
            if let activeWorkspaceID {
                defaults.set(activeWorkspaceID.uuidString, forKey: BoardStorageKeys.activeBoardID)
            } else {
                defaults.removeObject(forKey: BoardStorageKeys.activeBoardID)
            }
        }
    }
    @Published var workspaceName = ""
    @Published var attachedWindows: [AttachedWindow] = []
    @Published var unavailableAttachedWindowIDs: Set<AttachedWindow.ID> = []
    @Published var reconnectingAttachedWindowIDs: Set<AttachedWindow.ID> = []
    @Published var minimizedAttachedWindowIDs: Set<AttachedWindow.ID> = []
    @MainActor private(set) var minimizedLedger: [LiveWindowIdentity: MinimizedLedgerEntry] = [:]
    @MainActor private var nextMinimizedEntryVersion: UInt64 = 0
    @MainActor private var nextMinimizedInsertionOrder: UInt64 = 0
    @MainActor private var recordedMinimizationReceipts: Set<StepReceiptID> = []
    @MainActor private var completedMinimizationOperations: Set<UUID> = []

    /// Records physical effects independently of permission to publish current UI results.
    @MainActor
    @discardableResult
    func commitReceipt(_ receipt: StepReceipt) -> Bool {
        guard !completedMinimizationOperations.contains(receipt.operationID),
              receipt.identity == LiveWindowIdentity(window: receipt.window),
              recordedMinimizationReceipts.insert(receipt.id).inserted else { return false }
        if let operation = activeMinimizationOperation, operation.kind != .manual,
           operation.operationID == receipt.operationID,
           isCurrentMinimizationOperation(operation),
           automaticSummaryReceipts.insert(receipt.id).inserted {
            switch receipt.outcome {
            case .changed:
                if receipt.desiredMinimized { automaticMinimizationSummary.minimizedCount += 1 }
                else { automaticMinimizationSummary.restoredCount += 1 }
            case .alreadyDesired: automaticMinimizationSummary.noOpCount += 1
            case .readFailed(let issue):
                automaticMinimizationSummary.readFailureCount += 1
                automaticMinimizationSummary.issues.append(issue)
            case .writeFailed(let issue, _):
                automaticMinimizationSummary.writeFailureCount += 1
                automaticMinimizationSummary.issues.append(issue)
            case .skipped, .superseded: break
            }
        }
        if receipt.desiredMinimized, case .changed = receipt.outcome {
            upsertMinimizedWindow(receipt.window)
        }
        if !receipt.desiredMinimized,
           let version = receipt.expectedLedgerVersion,
           minimizedLedger[receipt.identity]?.entryVersion == version {
            let normal: Bool
            switch receipt.outcome {
            case .changed, .alreadyDesired: normal = true
            case .writeFailed(_, let observation):
                if case .success(false)? = observation?.state { normal = true } else { normal = false }
            default: normal = false
            }
            if normal {
                minimizedLedger.removeValue(forKey: receipt.identity)
                refreshMinimizedWindowsProjection()
            }
        }
        return canApplyMinimizationReceipt(receipt, to: receipt.window)
    }

    /// Callers updating a connection or cached candidate must supply its current
    /// live window; an attachment ID alone does not survive reconnect safely.
    @MainActor
    func canApplyMinimizationReceipt(_ receipt: StepReceipt, to currentWindow: WindowInfo) -> Bool {
        guard receipt.identity == LiveWindowIdentity(window: currentWindow),
              let operation = activeMinimizationOperation,
              operation.operationID == receipt.operationID,
              operation.intentID == receipt.intentID,
              isCurrentMinimizationOperation(operation) else { return false }
        return true
    }

    @MainActor
    private func upsertMinimizedWindow(_ window: WindowInfo) {
        let identity = LiveWindowIdentity(window: window)
        nextMinimizedEntryVersion += 1
        let order: UInt64
        if let entry = minimizedLedger[identity] {
            order = entry.insertionOrder
        } else {
            nextMinimizedInsertionOrder += 1
            order = nextMinimizedInsertionOrder
        }
        minimizedLedger[identity] = MinimizedLedgerEntry(identity: identity, window: window,
            entryVersion: nextMinimizedEntryVersion, insertionOrder: order)
        refreshMinimizedWindowsProjection()
    }

    @MainActor
    private func refreshMinimizedWindowsProjection() {
        minimizedWindows = minimizedLedger.values.sorted { $0.insertionOrder < $1.insertionOrder }.map(\.window)
    }

    @Published private(set) var minimizedWindows: [WindowInfo] = []
    @Published var isLoadingWorkspace = false
    @Published var isApplyingWorkspaceWindows = false
    @Published private(set) var isMinimizingUnattached = false
    @Published var isRestoringMinimized = false
    @Published var statusMessage = "Select a window to attach it to the board."
    @Published private(set) var currentBoardComposition: ResolvedBoardComposition = .empty
    @Published private(set) var attachmentOwnerBoardIDs: [AttachedWindow.ID: SavedWorkspace.ID] = [:]

    private var loadedWindowIDsByWorkspaceID: [SavedWorkspace.ID: [SavedWindowReference.ID: WindowInfo.ID]] = [:]
    private var pendingWorkspaceSwitch: PendingWorkspaceSwitch?
    private let defaults: UserDefaults
    private let minimizeUnattachedOnWorkspaceSwitchKey = "minimizeUnattachedOnWorkspaceSwitch"
    private let restoreMissingWindowsOnWorkspaceSwitchKey = "restoreMissingWindowsOnWorkspaceSwitch"
    private let windowServiceFactory: () -> any WorkspaceWindowOperating
    private let boardCompositionStore: BoardCompositionStore
    private var includedAttachmentIDs: Set<AttachedWindow.ID> = []

    init(
        workspaceStore: WorkspaceStore,
        defaults: UserDefaults = .standard,
        boardCompositionStore: BoardCompositionStore? = nil,
        windowServiceFactory: @escaping () -> any WorkspaceWindowOperating = { AccessibilityWindowService() }
    ) {
        self.workspaceStore = workspaceStore
        self.defaults = defaults
        self.boardCompositionStore = boardCompositionStore ?? BoardCompositionStore(defaults: defaults)
        self.windowServiceFactory = windowServiceFactory
        workspaceStore.ensureDefaultWorkspace()
        let storedActiveWorkspaceID = defaults.string(forKey: BoardStorageKeys.activeBoardID).flatMap(UUID.init(uuidString:))
        activeWorkspaceID = storedActiveWorkspaceID

        if let activeWorkspaceID,
           let workspace = workspaceStore.workspaces.first(where: { $0.id == activeWorkspaceID }) {
            selectedWorkspaceID = workspace.id
            workspaceName = workspace.name
        } else if let defaultWorkspace = workspaceStore.defaultWorkspace {
            activeWorkspaceID = defaultWorkspace.id
            selectedWorkspaceID = defaultWorkspace.id
            workspaceName = defaultWorkspace.name
        } else {
            activeWorkspaceID = nil
        }
    }

    var selectedWorkspace: SavedWorkspace? {
        guard let selectedWorkspaceID else {
            return nil
        }
        return workspaceStore.workspaces.first { $0.id == selectedWorkspaceID }
    }

    var canBringAttachedToFront: Bool {
        !attachedWindows.isEmpty
    }

    var canMinimizeUnattached: Bool {
        !attachedWindows.isEmpty && !isMinimizingUnattached && !isRestoringMinimized
    }

    var canRestoreMinimized: Bool {
        !minimizedWindows.isEmpty && !isMinimizingUnattached && !isRestoringMinimized
    }

    var boardSwitchTargets: [BoardSwitchTarget] {
        let projection = boardCompositionStore.sidebarProjection(workspaces: workspaceStore.workspaces)
        let groupTargets = projection.groups.flatMap { group in
            group.boards.map { board in
                BoardSwitchTarget(
                    primaryBoardID: group.primaryBoardID,
                    selectedBoardID: board.id,
                    board: board
                )
            }
        }
        let standaloneTargets = projection.standaloneBoards.map { board in
            BoardSwitchTarget(
                primaryBoardID: board.id,
                selectedBoardID: board.id,
                board: board
            )
        }
        return groupTargets + standaloneTargets
    }

    var attachedWindowSessionSnapshots: [AttachedWindowSessionSnapshot] {
        let workspaceNameByID = Dictionary(uniqueKeysWithValues: workspaceStore.workspaces.map { ($0.id, $0.name) })
        return attachedWindows.map { attachedWindow in
            let ownerBoardID = attachmentOwnerBoardIDs[attachedWindow.id] ?? activeWorkspaceID
            return AttachedWindowSessionSnapshot(
                id: attachedWindow.id,
                windowID: attachedWindow.window.id,
                appName: attachedWindow.window.appName,
                title: attachedWindow.window.title,
                displayName: attachedWindow.window.displayName,
                bundleIdentifier: attachedWindow.window.bundleIdentifier,
                ownerBoardID: ownerBoardID,
                ownerBoardName: ownerBoardID.flatMap { workspaceNameByID[$0] },
                isFromPrimaryBoard: ownerBoardID == activeWorkspaceID,
                state: attachedWindowSessionState(for: attachedWindow.id)
            )
        }
    }

    @discardableResult
    @MainActor
    func switchWorkspaceFromLauncher(
        _ target: BoardSwitchTarget,
        followMode: FollowMode,
        candidateWindows: [WindowInfo]? = nil
    ) -> Bool {
        guard boardSwitchTargets.contains(where: {
            $0.primaryBoardID == target.primaryBoardID && $0.selectedBoardID == target.selectedBoardID
        }) else {
            statusMessage = "Board not found."
            return false
        }

        if activeWorkspaceID == target.primaryBoardID,
           requestMemberSelection(
               memberBoardID: target.selectedBoardID,
               groupPrimaryID: target.primaryBoardID
           ) {
            return true
        }

        switchWorkspace(
            id: target.primaryBoardID,
            selectedBoardID: target.selectedBoardID,
            boardOrigin: nil,
            source: .launcher,
            followMode: followMode,
            windowCache: candidateWindows
        )
        return true
    }

    @discardableResult
    @MainActor
    func restoreLayoutFromLauncher(
        followMode: FollowMode,
        candidateWindows: [WindowInfo]? = nil
    ) -> Bool {
        guard !isLoadingWorkspace, !isApplyingWorkspaceWindows else {
            statusMessage = "Wait for the current board operation to finish."
            return false
        }
        guard let activeWorkspaceID,
              workspaceStore.workspaces.contains(where: { $0.id == activeWorkspaceID }) else {
            statusMessage = "Board not found."
            return false
        }
        let selectedBoardID = selectedWorkspaceID.flatMap { selectedID in
            currentBoardComposition.uniqueBoards.contains(where: { $0.id == selectedID }) ? selectedID : nil
        } ?? activeWorkspaceID
        switchWorkspace(
            id: activeWorkspaceID,
            selectedBoardID: selectedBoardID,
            boardOrigin: nil,
            source: .launcher,
            followMode: followMode,
            windowCache: candidateWindows,
            persistCurrentWorkspaceBeforeSwitch: false
        )
        return true
    }

    @discardableResult
    func attachWindow(
        _ window: WindowInfo,
        boardOrigin: CGPoint,
        insertion: SessionAttachedWindowInsertion = .start
    ) -> SessionWindowAttachResult {
        guard let activeWorkspaceID,
              workspaceStore.workspaces.contains(where: { $0.id == activeWorkspaceID }) else {
            statusMessage = "Select a board before attaching a window."
            return .noActiveBoard
        }
        guard let windowOrigin = window.position else {
            statusMessage = "Could not read the window position."
            return .missingWindowPosition
        }

        if let index = attachedWindows.firstIndex(where: { Self.windowsReferToSameWindow($0.window, window) }) {
            let attachmentID = attachedWindows[index].id
            attachedWindows[index].window = window
            attachedWindows[index].lastBoardOrigin = boardOrigin
            attachedWindows[index].lastWindowOrigin = windowOrigin
            attachedWindows[index].lastAppliedOrigin = windowOrigin
            attachedWindows[index].pendingReleaseOrigin = nil
            unavailableAttachedWindowIDs.remove(attachmentID)
            reconnectingAttachedWindowIDs.remove(attachmentID)
            minimizedAttachedWindowIDs.remove(attachmentID)
            let ownerBoardID = attachmentOwnerBoardIDs[attachmentID] ?? activeWorkspaceID
            persistCachedWorkspaceState(ownerBoardID: ownerBoardID, boardOrigin: boardOrigin)
            statusMessage = "Already attached. Updated \(window.displayName)."
            return .updatedExisting(attachmentID)
        }

        let attachedWindow = AttachedWindow(
            window: window,
            lastBoardOrigin: boardOrigin,
            lastWindowOrigin: windowOrigin,
            lastAppliedOrigin: windowOrigin,
            pendingReleaseOrigin: nil
        )
        switch insertion {
        case .start:
            attachedWindows.insert(attachedWindow, at: attachedWindows.startIndex)
        case .end:
            attachedWindows.append(attachedWindow)
        }
        attachmentOwnerBoardIDs[attachedWindow.id] = activeWorkspaceID
        includedAttachmentIDs.remove(attachedWindow.id)
        persistCachedWorkspaceState(ownerBoardID: activeWorkspaceID, boardOrigin: boardOrigin)
        statusMessage = "Attached \(window.displayName)."
        return .attached(attachedWindow.id)
    }

    @discardableResult
    func selectMemberBoard(_ boardID: SavedWorkspace.ID) -> Bool {
        guard currentBoardComposition.uniqueBoards.contains(where: { $0.id == boardID }),
              let workspace = workspaceStore.workspaces.first(where: { $0.id == boardID }) else {
            return false
        }
        selectedWorkspaceID = boardID
        workspaceName = workspace.name
        return true
    }

    @discardableResult
    @MainActor
    func requestMemberSelection(
        memberBoardID: SavedWorkspace.ID,
        groupPrimaryID: SavedWorkspace.ID
    ) -> Bool {
        guard activeWorkspaceID == groupPrimaryID,
              currentBoardComposition.uniqueBoards.contains(where: { $0.id == memberBoardID }),
              workspaceStore.workspaces.contains(where: { $0.id == memberBoardID }) else {
            return false
        }
        return selectMemberBoard(memberBoardID)
    }

    private var primaryAttachedWindows: [AttachedWindow] {
        attachedWindows.filter { !includedAttachmentIDs.contains($0.id) }
    }

    func saveCurrentWorkspace(name: String, boardOrigin: CGPoint?) {
        guard !attachedWindows.isEmpty,
              let references = currentWorkspaceReferences(boardOrigin: boardOrigin) else {
            return
        }

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = trimmedName.isEmpty
            ? "Board \(workspaceStore.workspaces.count + 1)"
            : trimmedName
        let workspace = workspaceStore.saveWorkspace(name: resolvedName, windows: references)
        selectedWorkspaceID = workspace.id
        activeWorkspaceID = workspace.id
        workspaceName = workspace.name
        rememberLoadedWindowIDs(for: workspace.id, attachedWindows: primaryAttachedWindows)
        statusMessage = "Saved \(workspace.displayName)."
    }

    @discardableResult
    func createWorkspace(boardOrigin: CGPoint?) -> SavedWorkspace {
        if !attachedWindows.isEmpty {
            persistActiveWorkspaceState(boardOrigin: boardOrigin)
        }

        let workspace = workspaceStore.saveWorkspace(name: nextWorkspaceName(), windows: [])
        selectedWorkspaceID = workspace.id
        activeWorkspaceID = workspace.id
        workspaceName = workspace.name
        attachedWindows = []
        includedAttachmentIDs.removeAll()
        attachmentOwnerBoardIDs.removeAll()
        currentBoardComposition = boardCompositionStore.resolveCurrentBoard(
            primaryID: workspace.id,
            workspaces: workspaceStore.workspaces
        )
        unavailableAttachedWindowIDs.removeAll()
        reconnectingAttachedWindowIDs.removeAll()
        minimizedAttachedWindowIDs.removeAll()
        loadedWindowIDsByWorkspaceID[workspace.id] = [:]
        statusMessage = "Created \(workspace.displayName)."
        return workspace
    }

    func overwriteSelectedWorkspace(name: String, boardOrigin: CGPoint?) {
        guard let selectedWorkspaceID else { return }
        overwriteWorkspace(id: selectedWorkspaceID, name: name, boardOrigin: boardOrigin)
    }

    func overwriteWorkspace(id workspaceID: SavedWorkspace.ID, name: String, boardOrigin: CGPoint?) {
        guard !isLoadingWorkspace,
              !attachedWindows.isEmpty,
              let references = currentWorkspaceReferences(
                ownerBoardID: workspaceID,
                boardOrigin: boardOrigin
              ) else {
            return
        }

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetWorkspace = workspaceStore.workspaces.first { $0.id == workspaceID }
        let resolvedName: String?
        if targetWorkspace?.isDefault == true {
            resolvedName = WorkspaceStore.defaultWorkspaceName
        } else {
            resolvedName = trimmedName.isEmpty ? targetWorkspace?.name : trimmedName
        }
        guard let workspace = workspaceStore.updateWorkspace(
            id: workspaceID,
            name: resolvedName,
            windows: references
        ) else {
            return
        }

        workspaceName = workspace.name
        let ownerAttachments = attachedWindows.filter {
            (attachmentOwnerBoardIDs[$0.id] ?? activeWorkspaceID) == workspace.id
        }
        rememberLoadedWindowIDs(for: workspace.id, attachedWindows: ownerAttachments)
        if let activeWorkspaceID {
            currentBoardComposition = boardCompositionStore.resolveCurrentBoard(
                primaryID: activeWorkspaceID,
                workspaces: workspaceStore.workspaces
            )
        }
        statusMessage = "Overwrote \(workspace.displayName)."
    }

    func renameSelectedWorkspace(name: String) {
        guard let selectedWorkspaceID else { return }
        renameWorkspace(id: selectedWorkspaceID, name: name)
    }

    func renameWorkspace(id workspaceID: SavedWorkspace.ID, name: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            return
        }

        guard workspaceStore.workspaces.first(where: { $0.id == workspaceID })?.isDefault != true else {
            workspaceName = WorkspaceStore.defaultWorkspaceName
            statusMessage = "Permanent Board cannot be renamed."
            return
        }

        guard let workspace = workspaceStore.updateWorkspace(id: workspaceID, name: trimmedName) else {
            return
        }

        workspaceName = workspace.name
        statusMessage = "Renamed board to \(workspace.name)."
    }

    func updateWorkspaceSearchAliases(id workspaceID: SavedWorkspace.ID, aliases: [String]) {
        let normalizedAliases = Array(
            Set(
                aliases.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            )
        ).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        guard workspaceStore.updateWorkspace(id: workspaceID, searchAliases: normalizedAliases) != nil else {
            return
        }
        statusMessage = normalizedAliases.isEmpty
            ? "Cleared search aliases."
            : "Saved \(normalizedAliases.count) search alias(es)."
    }

    private func nextWorkspaceName() -> String {
        let existingNames = Set(workspaceStore.workspaces.map(\.name))
        var index = workspaceStore.workspaces.count + 1

        while existingNames.contains("Board \(index)") {
            index += 1
        }

        return "Board \(index)"
    }

    func deleteSelectedWorkspace() {
        guard let selectedWorkspaceID else { return }
        deleteWorkspace(id: selectedWorkspaceID)
    }

    func deleteWorkspace(id workspaceID: SavedWorkspace.ID) {
        guard workspaceStore.workspaces.first(where: { $0.id == workspaceID })?.isDefault != true else {
            statusMessage = "Permanent Board cannot be deleted."
            return
        }

        boardCompositionStore.removeBoardReferences(workspaceID)
        loadedWindowIDsByWorkspaceID[workspaceID] = nil
        workspaceStore.deleteWorkspace(id: workspaceID)
        if activeWorkspaceID == workspaceID {
            activeWorkspaceID = nil
            attachedWindows = []
            includedAttachmentIDs = []
            attachmentOwnerBoardIDs = [:]
            currentBoardComposition = .empty
            unavailableAttachedWindowIDs = []
            reconnectingAttachedWindowIDs = []
            minimizedAttachedWindowIDs = []
        }
        if selectedWorkspaceID == workspaceID || activeWorkspaceID == nil {
            selectedWorkspaceID = workspaceStore.defaultWorkspace?.id
            workspaceName = workspaceStore.defaultWorkspace?.name ?? ""
        }
        statusMessage = "Deleted board."
    }

    @discardableResult
    func persistActiveWorkspaceState(boardOrigin: CGPoint?) -> SavedWorkspace? {
        guard let activeWorkspaceID,
              let references = currentWorkspaceReferences(boardOrigin: boardOrigin) else {
            return nil
        }

        let workspace = workspaceStore.updateWorkspace(id: activeWorkspaceID, windows: references)
        if let workspace {
            rememberLoadedWindowIDs(for: workspace.id, attachedWindows: primaryAttachedWindows)
            currentBoardComposition = boardCompositionStore.resolveCurrentBoard(
                primaryID: workspace.id,
                workspaces: workspaceStore.workspaces
            )
        }
        return workspace
    }

    func persistActiveWorkspaceSnapshot(sizeByAttachmentID: [AttachedWindow.ID: CGSize] = [:]) -> SavedWorkspace? {
        guard let activeWorkspaceID,
              !attachedWindows.isEmpty else {
            return nil
        }

        let referencesByOwner = Dictionary(grouping: attachedWindows) { attachedWindow in
            attachmentOwnerBoardIDs[attachedWindow.id] ?? activeWorkspaceID
        }
        var workspace: SavedWorkspace?
        for (ownerBoardID, ownerAttachments) in referencesByOwner {
            let references = ownerAttachments.map {
                SavedWindowReference.makePreservingOffset(
                    from: $0,
                    size: sizeByAttachmentID[$0.id]
                )
            }
            let updated = workspaceStore.updateWorkspace(id: ownerBoardID, windows: references)
            if ownerBoardID == activeWorkspaceID { workspace = updated }
            rememberLoadedWindowIDs(for: ownerBoardID, attachedWindows: ownerAttachments)
        }
        if let workspace {
            currentBoardComposition = boardCompositionStore.resolveCurrentBoard(
                primaryID: workspace.id,
                workspaces: workspaceStore.workspaces
            )
        }
        return workspace
    }

    @discardableResult
    func persistActiveWorkspaceSnapshotForSwitch(boardOrigin: CGPoint?) -> SavedWorkspace? {
        guard let activeWorkspaceID else {
            return nil
        }

        let primaryAttachedWindows = attachedWindows.filter { !includedAttachmentIDs.contains($0.id) }
        let references = primaryAttachedWindows.map { attachedWindow in
            let savedSize = attachedWindow.savedReference?.savedSize
            guard let boardOrigin else {
                return SavedWindowReference.makePreservingOffset(
                    from: attachedWindow,
                    size: savedSize
                )
            }

            return SavedWindowReference.make(
                from: attachedWindow,
                boardOrigin: boardOrigin,
                size: savedSize
            )
        }
        let workspace = workspaceStore.updateWorkspace(id: activeWorkspaceID, windows: references)
        if let workspace {
            rememberLoadedWindowIDs(for: workspace.id, attachedWindows: primaryAttachedWindows)
        }
        return workspace
    }

    @MainActor
    func switchWorkspace(
        id workspaceID: SavedWorkspace.ID,
        selectedBoardID: SavedWorkspace.ID? = nil,
        boardOrigin: CGPoint?,
        source: WorkspaceSwitchSource,
        followMode: FollowMode,
        windowCache: [WindowInfo]? = nil,
        mergeWindows: @escaping @MainActor ([WindowInfo]) -> Void = { _ in },
        completion: @escaping @MainActor (_ shouldBringBoardToFront: Bool) -> Void = { _ in },
        deferredWindowApplicationCompletion: @escaping @MainActor () -> Void = {},
        minimizeAfterSwitchCompletion: @escaping @MainActor () -> Void = {},
        persistCurrentWorkspaceBeforeSwitch: Bool = true
    ) {
        performSwitchWorkspace(
            id: workspaceID, selectedBoardID: selectedBoardID, boardOrigin: boardOrigin,
            source: source, followMode: followMode, windowCache: windowCache,
            mergeWindows: mergeWindows, completion: completion,
            deferredWindowApplicationCompletion: deferredWindowApplicationCompletion,
            minimizeAfterSwitchCompletion: minimizeAfterSwitchCompletion,
            persistCurrentWorkspaceBeforeSwitch: persistCurrentWorkspaceBeforeSwitch
        )
    }

    @MainActor
    private func performSwitchWorkspace(
        id workspaceID: SavedWorkspace.ID,
        selectedBoardID: SavedWorkspace.ID? = nil,
        boardOrigin: CGPoint?,
        source: WorkspaceSwitchSource,
        followMode: FollowMode,
        windowCache: [WindowInfo]? = nil,
        mergeWindows: @escaping @MainActor ([WindowInfo]) -> Void = { _ in },
        completion: @escaping @MainActor (_ shouldBringBoardToFront: Bool) -> Void = { _ in },
        deferredWindowApplicationCompletion: @escaping @MainActor () -> Void = {},
        minimizeAfterSwitchCompletion: @escaping @MainActor () -> Void = {},
        persistCurrentWorkspaceBeforeSwitch: Bool = true,
        acceptedMinimizationIntentID: MinimizationIntentID? = nil
    ) {
        guard let workspace = workspaceStore.workspaces.first(where: { $0.id == workspaceID }) else {
            statusMessage = "Board not found."
            return
        }

        guard let intentID = acceptedMinimizationIntentID ?? acceptSwitchIntent(
            target: workspaceID,
            automaticEnabled: defaults.bool(forKey: minimizeUnattachedOnWorkspaceSwitchKey),
            source: source, notBefore: .now.advanced(by: .milliseconds(150)),
            windowCache: windowCache ?? [],
            minimizeAfterSwitchCompletion: minimizeAfterSwitchCompletion
        ) else { return }

        if isLoadingWorkspace {
            pendingWorkspaceSwitch = PendingWorkspaceSwitch(
                workspaceID: workspaceID,
                minimizationIntentID: intentID,
                selectedBoardID: selectedBoardID,
                boardOrigin: boardOrigin,
                source: source,
                followMode: followMode,
                windowCache: windowCache,
                mergeWindows: mergeWindows,
                completion: completion,
                deferredWindowApplicationCompletion: deferredWindowApplicationCompletion,
                minimizeAfterSwitchCompletion: minimizeAfterSwitchCompletion
            )
            statusMessage = "Queued \(workspace.name)."
            return
        }

        if persistCurrentWorkspaceBeforeSwitch, !attachedWindows.isEmpty {
            persistActiveWorkspaceSnapshotForSwitch(boardOrigin: boardOrigin)
        }
        let requestedSelectedBoardID = selectedBoardID ?? workspaceID
        selectedWorkspaceID = requestedSelectedBoardID
        workspaceName = workspaceStore.workspaces.first(where: { $0.id == requestedSelectedBoardID })?.name
            ?? workspace.name
        isApplyingWorkspaceWindows = false
        isLoadingWorkspace = true
        statusMessage = "Loading \(workspace.name)..."

        let shouldRestoreSavedOrigin = source == .statusItem || source == .launcher || followMode == .none
        let effectiveBoardOrigin = boardOrigin ?? .zero
        let boardComposition = boardCompositionStore.resolveCurrentBoard(
            primaryID: workspaceID,
            workspaces: workspaceStore.workspaces
        )
        let resolvedSelectedBoardID = boardComposition.uniqueBoards.contains(where: { $0.id == requestedSelectedBoardID })
            ? requestedSelectedBoardID
            : workspaceID
        let composedReferences = boardComposition.uniqueWindowReferences.map(\.reference)
        let ownerBoardIDByReferenceID = Dictionary(
            uniqueKeysWithValues: boardComposition.uniqueWindowReferences.map { ($0.reference.id, $0.ownerBoardID) }
        )
        let includedReferenceIDs = Set(boardComposition.uniqueWindowReferences.compactMap { ownedReference in
            ownedReference.ownerBoardID == workspaceID ? nil : ownedReference.reference.id
        })
        var targetLoadedWindowIDs = loadedWindowIDsByWorkspaceID[workspaceID] ?? [:]
        for includedBoard in boardComposition.uniqueBoards where includedBoard.id != workspaceID {
            targetLoadedWindowIDs.merge(
                loadedWindowIDsByWorkspaceID[includedBoard.id] ?? [:],
                uniquingKeysWith: { current, _ in current }
            )
        }
        let shouldMinimizeAfterSwitch = latestMinimizationIntent?.automaticEnabled == true
        let shouldRestoreMissingWindows = defaults.bool(forKey: restoreMissingWindowsOnWorkspaceSwitchKey)
        let shouldDeferWindowApplication = windowCache != nil
        let plannedAttachedWindows = WorkspaceWindowResolver.placeholderAttachments(
            for: composedReferences,
            boardOrigin: effectiveBoardOrigin,
            useSavedOrigin: shouldRestoreSavedOrigin
        )
        let plannedAttachmentIDs = Set(plannedAttachedWindows.map(\.id))

        attachedWindows = plannedAttachedWindows
        includedAttachmentIDs = includedReferenceIDs
        attachmentOwnerBoardIDs = ownerBoardIDByReferenceID
        currentBoardComposition = boardComposition
        unavailableAttachedWindowIDs = plannedAttachmentIDs
        reconnectingAttachedWindowIDs = []
        minimizedAttachedWindowIDs = []
        activeWorkspaceID = workspace.id
        selectedWorkspaceID = resolvedSelectedBoardID
        loadedWindowIDsByWorkspaceID[workspace.id] = [:]

        Task.detached(priority: .userInitiated) {
            let service = self.windowServiceFactory()
            let resolveStart = Date()
            var availableWindows = windowCache ?? []
            var enumerationReport: WindowEnumerationReport?
            var resolution = WorkspaceWindowResolver.resolve(
                references: composedReferences,
                candidates: availableWindows,
                cachedWindowIDs: targetLoadedWindowIDs
            )

            if windowCache == nil || !resolution.unresolvedReferences.isEmpty {
                let listWindowsStart = Date()
                let report = service.listWindowsReport()
                enumerationReport = report
                availableWindows = report.windows
                Self.logDuration("workspace listWindows", since: listWindowsStart)
            }

            if !resolution.unresolvedReferences.isEmpty {
                resolution = WorkspaceWindowResolver.resolve(
                    references: resolution.unresolvedReferences,
                    candidates: availableWindows,
                    cachedWindowIDs: targetLoadedWindowIDs,
                    previous: resolution
                )
            }

            let loadedAttachedWindows = resolution.matches.map { match in
                Self.makeAttachedWindow(
                    match.window,
                    attachmentID: match.reference.id,
                    reference: match.reference,
                    boardOrigin: effectiveBoardOrigin,
                    useSavedOrigin: shouldRestoreSavedOrigin,
                    applyImmediately: !shouldDeferWindowApplication,
                    raiseImmediately: false,
                    service: service
                )
            }

            let resolvedAvailableWindows = availableWindows
            let resolvedAttachedWindows = WorkspaceWindowResolver.orderedAttachments(
                references: composedReferences,
                resolvedAttachments: loadedAttachedWindows,
                boardOrigin: effectiveBoardOrigin,
                useSavedOrigin: shouldRestoreSavedOrigin
            )
            let resolvedUnavailableAttachmentIDs = Set(resolution.unresolvedReferences.map(\.id))
            let resolvedLoadedWindowIDs = resolution.loadedWindowIDs
            let resolvedReconnectedCount = resolution.matches.count
            let resolvedMissedCount = resolution.unresolvedReferences.count
            let unresolvedAttachmentsForDeferredRecovery = resolvedAttachedWindows.filter {
                resolvedUnavailableAttachmentIDs.contains($0.id)
            }
            let resolvedEnumerationReport = enumerationReport
            Self.logDuration("workspace resolve", since: resolveStart)

            let batchUpdateStart = Date()
            await MainActor.run {
                var selectedBoardIDForBatch = resolvedSelectedBoardID
                if let pendingSwitch = self.pendingWorkspaceSwitch {
                    self.pendingWorkspaceSwitch = nil
                    self.isLoadingWorkspace = false
                    self.performSwitchWorkspace(
                        id: pendingSwitch.workspaceID,
                        selectedBoardID: pendingSwitch.selectedBoardID,
                        boardOrigin: pendingSwitch.boardOrigin,
                        source: pendingSwitch.source,
                        followMode: pendingSwitch.followMode,
                        windowCache: pendingSwitch.windowCache,
                        mergeWindows: pendingSwitch.mergeWindows,
                        completion: pendingSwitch.completion,
                        deferredWindowApplicationCompletion: pendingSwitch.deferredWindowApplicationCompletion,
                        minimizeAfterSwitchCompletion: pendingSwitch.minimizeAfterSwitchCompletion,
                        persistCurrentWorkspaceBeforeSwitch: false,
                        acceptedMinimizationIntentID: pendingSwitch.minimizationIntentID
                    )
                    return
                }
                if let selected = self.selectedWorkspaceID,
                   boardComposition.uniqueBoards.contains(where: { $0.id == selected }) {
                    selectedBoardIDForBatch = selected
                }

                self.attachedWindows = resolvedAttachedWindows
                self.unavailableAttachedWindowIDs = resolvedUnavailableAttachmentIDs
                self.reconnectingAttachedWindowIDs.subtract(resolvedLoadedWindowIDs.keys)
                self.isLoadingWorkspace = false
                self.activeWorkspaceID = workspace.id
                self.selectedWorkspaceID = selectedBoardIDForBatch
                self.workspaceName = self.workspaceStore.workspaces.first(where: { $0.id == selectedBoardIDForBatch })?.name
                    ?? workspace.name
                self.loadedWindowIDsByWorkspaceID[workspace.id] = resolvedLoadedWindowIDs
                self.attachmentOwnerBoardIDs = ownerBoardIDByReferenceID
                self.currentBoardComposition = boardComposition
                for includedBoard in boardComposition.uniqueBoards where includedBoard.id != workspace.id {
                    let referenceIDs = Set(includedBoard.windows.map(\.id))
                    self.loadedWindowIDsByWorkspaceID[includedBoard.id] = resolvedLoadedWindowIDs.filter {
                        referenceIDs.contains($0.key)
                    }
                }

                self.statusMessage = Self.workspaceLoadStatus(
                    loadedCount: resolvedAttachedWindows.count,
                    reconnectedCount: resolvedReconnectedCount,
                    restoredCount: 0,
                    activatedOnlyCount: 0,
                    missedCount: resolvedMissedCount
                )

                mergeWindows(resolvedAvailableWindows)
                completion(source == .mainWindow)

                self.pendingWorkspaceSwitch = nil
            }
            Self.logDuration("workspace mainActor batch update", since: batchUpdateStart)
            let shouldContinueSwitch = await MainActor.run {
                self.activeWorkspaceID == workspace.id
            }
            guard shouldContinueSwitch else {
                return
            }

            if shouldDeferWindowApplication {
                await MainActor.run {
                    if self.activeWorkspaceID == workspace.id {
                        self.isApplyingWorkspaceWindows = true
                    }
                }
                let applyPositionsStart = Date()
                let applicationResult = Self.applyWorkspaceWindowPositions(resolvedAttachedWindows, service: service)
                Self.logDuration("applyWorkspaceWindowPositions", since: applyPositionsStart)
                Self.logWindowApplicationResult(applicationResult, targetCount: resolvedAttachedWindows.count)
                let windowsToRaise = applicationResult.appliedWindows
                let failedAttachments = applicationResult.failedAttachments
                var deferredRecoveryAttachments = unresolvedAttachmentsForDeferredRecovery
                let shouldContinueAfterApply = await MainActor.run {
                    guard self.activeWorkspaceID == workspace.id else {
                        if self.isApplyingWorkspaceWindows {
                            self.isApplyingWorkspaceWindows = false
                        }
                        return false
                    }

                    return true
                }
                guard shouldContinueAfterApply else {
                    return
                }

                if !failedAttachments.isEmpty {
                    deferredRecoveryAttachments.append(contentsOf: failedAttachments)
                    await MainActor.run {
                        self.applyDeferredRecovery(
                            [:],
                            failedAttachments: failedAttachments,
                            workspaceID: workspace.id
                        )
                    }
                }
                if !shouldMinimizeAfterSwitch {
                    Self.raiseWorkspaceWindows(windowsToRaise, service: service)
                }
                await MainActor.run {
                    deferredWindowApplicationCompletion()
                    if self.activeWorkspaceID == workspace.id {
                        self.isApplyingWorkspaceWindows = false
                    }
                }

                if shouldRestoreMissingWindows, !deferredRecoveryAttachments.isEmpty {
                    let recoveryAttachments = Self.uniqueAttachments(deferredRecoveryAttachments)
                    Task.detached(priority: .utility) {
                        let recoveryService = self.windowServiceFactory()
                        await self.recoverMissingAttachmentsAfterWorkspaceSwitch(
                            recoveryAttachments,
                            workspaceID: workspace.id,
                            minimizationIntentID: intentID,
                            boardOrigin: effectiveBoardOrigin,
                            useSavedOrigin: shouldRestoreSavedOrigin,
                            service: recoveryService
                        )
                    }
                }
            } else {
                if !shouldMinimizeAfterSwitch {
                    Self.raiseWorkspaceWindows(resolvedAttachedWindows, service: service)
                }

                if shouldRestoreMissingWindows, !unresolvedAttachmentsForDeferredRecovery.isEmpty {
                    let recoveryAttachments = unresolvedAttachmentsForDeferredRecovery
                    Task.detached(priority: .utility) {
                        let recoveryService = self.windowServiceFactory()
                        await self.recoverMissingAttachmentsAfterWorkspaceSwitch(
                            recoveryAttachments,
                            workspaceID: workspace.id,
                            minimizationIntentID: intentID,
                            boardOrigin: effectiveBoardOrigin,
                            useSavedOrigin: shouldRestoreSavedOrigin,
                            service: recoveryService
                        )
                    }
                }
            }

            let shouldContinueBeforeMinimize = await MainActor.run {
                self.activeWorkspaceID == workspace.id
            }
            guard shouldContinueBeforeMinimize else {
                return
            }

            if shouldMinimizeAfterSwitch {
                await MainActor.run {
                    guard self.latestMinimizationIntent?.id == intentID,
                          self.workspaceSwitchRevision == switchRevision else { return }
                    self.minimizationKnownWindows = Self.mergeMinimizationWindows(resolvedAvailableWindows,
                        fallback: self.minimizationKnownWindows)
                    self.materializeAutomaticRequest(intent: intentID, resolution: MinimizationResolution(
                        targetBoardID: workspace.id, composedReferenceIDs: Set(composedReferences.map(\.id)),
                        report: resolvedEnumerationReport, switchRevision: switchRevision,
                        notBefore: self.latestMinimizationIntent!.notBefore))
                    if !composedReferences.isEmpty {
                        self.latestMinimizationIntent?.minimizeAfterSwitchCompletion()
                    }
                    self.drainAutomaticMinimization()
                }
            }
        }
    }

    // Candidate fallback needs fresh same-ID handles; generic mergeWindows
    // deliberately retains its established cache-first semantics elsewhere.
    private static func mergeMinimizationWindows(_ fresh: [WindowInfo], fallback: [WindowInfo]) -> [WindowInfo] {
        let freshIDs = Set(fresh.map(\.id))
        return fresh + fallback.filter { !freshIDs.contains($0.id) }
    }

    @MainActor
    func protectionSnapshot() -> ProtectionSnapshot {
        ProtectionSnapshot(records: attachedWindows.map { attachment in
            ProtectionRecord(attachmentID: attachment.id, window: attachment.window,
                savedReference: attachment.savedReference,
                isAvailable: !unavailableAttachedWindowIDs.contains(attachment.id) && attachment.window.pid != 0,
                isReconnecting: reconnectingAttachedWindowIDs.contains(attachment.id),
                lastWindowOrigin: attachment.lastWindowOrigin)
        })
    }

    @MainActor
    func authorizeStep(_ proposal: StepProposal) -> StepAuthorization {
        guard let operation = activeMinimizationOperation,
              operation.operationID == proposal.operationID,
              operation.intentID == proposal.intentID,
              isCurrentMinimizationOperation(operation) else { return .stop(.superseded) }
        if case .running = activeMinimizationPhase {} else {
            activeMinimizationPhase = .running
            updateMinimizationProgress()
        }
        guard proposal.hasMatchingCandidateIdentity else { return .skip(.identityChanged) }
        let protection = protectionSnapshot()
        let window: WindowInfo
        let classification: CandidateClassification
        switch proposal.kind {
        case .minimizeCandidate:
            window = proposal.candidateWindow
            classification = UnattachedWindowMinimizationPolicy.classify(window, protection: protection)
            if classification == .registered { return .skip(.registered) }
            if classification == .sameApplicationProtected { return .skip(.sameApplicationProtected) }
        case .restoreAttachment:
            guard let record = protection.records.first(where: { $0.attachmentID == proposal.attachmentID })
                else { return .skip(.noLongerRegistered) }
            guard record.isAvailable else { return .skip(.unavailable) }
            guard !record.isReconnecting else { return .skip(.reconnecting) }
            guard record.identity == proposal.candidateIdentity else { return .skip(.identityChanged) }
            window = record.window
            classification = .registered
        }
        let identity = LiveWindowIdentity(window: window)
        return .perform(WindowOperationPermit(operationID: proposal.operationID, intentID: proposal.intentID,
            stepID: proposal.stepID, kind: proposal.kind, identity: identity, window: window,
            attachmentID: proposal.attachmentID, expectedLedgerVersion: minimizedLedger[identity]?.entryVersion,
            protectionFingerprint: protection.fingerprint, classification: classification))
    }

    @MainActor
    private func drainAutomaticMinimization() {
        guard minimizationWorker == nil, !isRestoringMinimized,
              let request = takeNextMinimizationOperation() else { return }
        launchAutomaticMinimization(request)
    }

    @MainActor
    private func recordMinimizationReceipt(_ receipt: StepReceipt,
        removeWindows: @MainActor (Set<WindowInfo.ID>) -> Void = { _ in }) {
        // Physical results outlive intent validity; UI callbacks do not.
        commitReceipt(receipt)
        guard canApplyMinimizationReceipt(receipt, to: receipt.window) else { return }
        switch receipt.outcome {
        case .changed where receipt.desiredMinimized:
            // A reconnect can reuse a display ID while the old AX write is in
            // flight. Its physical success must not remove the replacement UI.
            guard !attachedWindows.contains(where: {
                $0.window.id == receipt.window.id &&
                    (LiveWindowIdentity(window: $0.window) != receipt.identity ||
                     $0.window.axWindow !== receipt.window.axWindow)
            }) else { return }
            removeWindows([receipt.window.id])
        case .changed, .alreadyDesired:
            if !receipt.desiredMinimized, let attachment = attachedWindows.first(where: {
                LiveWindowIdentity(window: $0.window) == receipt.identity
            }) {
                minimizedAttachedWindowIDs.remove(attachment.id)
            }
        default: break
        }
    }

    @MainActor
    private func completeMinimization(_ result: MinimizationOperationResult,
        request: MinimizationExecutionRequest) {
        guard minimizationWorker?.id == request.operationID,
              activeMinimizationOperation?.operationID == request.operationID else { return }
        var completedSummary = result.summary
        if isCurrentMinimizationOperation(request) {
            var summary = result.summary
            if request.kind != .manual {
                if let snapshot = result.candidateSnapshot {
                    minimizationCandidateSnapshot = snapshot
                    minimizationKnownWindows = Self.mergeMinimizationWindows(snapshot.report.windows,
                        fallback: snapshot.fallback)
                }
                automaticMinimizationSummary.candidateCount = summary.candidateCount
                automaticMinimizationSummary.registeredCount = summary.registeredCount
                automaticMinimizationSummary.sameApplicationProtectedCount = summary.sameApplicationProtectedCount
                automaticMinimizationSummary.coverage = summary.coverage
                automaticMinimizationSummary.interruptionReason = summary.interruptionReason
                if summary.enumerationCount > 0,
                   summarizedEnumerationOperations.insert(request.operationID).inserted {
                    automaticMinimizationSummary.enumerationCount += summary.enumerationCount
                }
                // Reconcile reuses this report. Preserve its diagnostics even
                // when resolution supplied it without an executor enumeration,
                // and do not append the same acquisition issues on each pass.
                if !hasSummarizedAutomaticCandidateReport, let snapshot = result.candidateSnapshot {
                    automaticMinimizationSummary.issues.append(contentsOf: snapshot.report.issues)
                    hasSummarizedAutomaticCandidateReport = true
                }
                summary = automaticMinimizationSummary
                if deferredReconcileIntent == request.intentID,
                   let snapshot = minimizationCandidateSnapshot {
                    deferredReconcileIntent = nil
                    requestMinimizationReconcile(intent: request.intentID, snapshot: snapshot)
                }
            }
            completedSummary = summary
            statusMessage = request.kind == .manual && summary.minimizedCount == 0 &&
                summary.restoredCount == 0 && summary.failureCount == 0
                ? "No other windows to minimize."
                : Self.minimizeStatus(minimizedCount: summary.minimizedCount,
                    restoredAttachedCount: summary.restoredCount, failedCount: summary.failureCount)
            if completedSummary.coverage != .complete {
                statusMessage += " Window list confirmation was incomplete."
            }
        }
        minimizationWorker = nil
        if let next = finishOperation(result, summary: completedSummary) {
            launchAutomaticMinimization(next)
        }
    }

    @MainActor
    private func launchAutomaticMinimization(_ request: MinimizationExecutionRequest) {
        guard activeMinimizationOperation?.operationID == request.operationID,
              minimizationWorker == nil else { return }
        updateMinimizationProgress()
        let notBefore = latestMinimizationIntent?.notBefore ?? .now
        let task = Task.detached(priority: .utility) {
            try? await ContinuousClock().sleep(until: notBefore)
            await self.prepareMinimization(request)
            let service = self.windowServiceFactory()
            let result = await UnattachedWindowMinimizationExecutor().run(request: request, service: service,
                authorize: { self.authorizeStep($0) }, restorePlan: { self.protectionSnapshot() },
                record: { self.recordMinimizationReceipt($0) })
            await self.completeMinimization(result, request: request)
        }
        minimizationWorker = (request.operationID, task)
    }

    @MainActor
    private func startManualMinimization(knownWindows: [WindowInfo], recentWindows: [WindowInfo],
        refreshWindowList: Bool,
        removeWindows: @escaping @MainActor (Set<WindowInfo.ID>) -> Void) {
        let baseWindows = Self.mergeWindows(recentWindows, into: knownWindows)
        guard let request = startManualMinimizationOperation(candidateSource:
            refreshWindowList ? .refresh(fallback: baseWindows) : .known(baseWindows)) else { return }
        let originalAttachments = attachedWindows
        updateMinimizationProgress()
        statusMessage = "Preparing other windows..."
        let task = Task.detached(priority: .userInitiated) {
            let service = self.windowServiceFactory()
            var source = request.candidateSource
            var replacements: [AttachedWindow.ID: WindowInfo] = [:]
            if refreshWindowList && !Task.isCancelled {
                let report = service.listWindowsReport()
                var fallback = baseWindows
                for attachment in originalAttachments where attachment.window.pid != 0 {
                    guard !Task.isCancelled else { break }
                    guard await self.isCurrentMinimizationOperation(request) else { break }
                    let candidates = service.windows(matching: attachment.window)
                    fallback = Self.mergeMinimizationWindows(candidates, fallback: fallback)
                    if let replacement = WindowMatching.bestReplacement(for: attachment.window, in: candidates) {
                        replacements[attachment.id] = replacement
                    }
                }
                source = .reuse(CandidateSnapshot(report: report, origin: .minimization,
                    intentID: request.intentID, capturedAt: .now, fallback: fallback))
            }
            let preparedReplacements = replacements
            let current = await MainActor.run {
                guard self.isCurrentMinimizationOperation(request), !Task.isCancelled else { return false }
                for original in originalAttachments {
                    guard let replacement = preparedReplacements[original.id],
                          let index = self.attachedWindows.firstIndex(where: { $0.id == original.id }),
                          LiveWindowIdentity(window: self.attachedWindows[index].window) == LiveWindowIdentity(window: original.window),
                          self.attachedWindows[index].window.axWindow === original.window.axWindow else { continue }
                    let origin = replacement.position ?? self.attachedWindows[index].lastWindowOrigin
                    self.attachedWindows[index].window = replacement
                    self.attachedWindows[index].lastWindowOrigin = origin
                    self.attachedWindows[index].lastAppliedOrigin = origin
                    self.markAttachedWindowAvailable(original.id)
                }
                return true
            }
            let result: MinimizationOperationResult
            if current {
                let prepared = MinimizationExecutionRequest(intentID: request.intentID,
                    operationID: request.operationID, kind: .manual, candidateSource: source)
                result = await UnattachedWindowMinimizationExecutor().run(request: prepared, service: service,
                    authorize: { self.authorizeStep($0) }, restorePlan: { self.protectionSnapshot() },
                    record: { self.recordMinimizationReceipt($0, removeWindows: removeWindows) })
            } else {
                let reason: MinimizationOperationResult.EndReason = Task.isCancelled ? .cancelled : .superseded
                result = MinimizationOperationResult(operationID: request.operationID, intentID: request.intentID,
                    summary: OperationSummary(), endReason: reason)
            }
            await self.completeMinimization(result, request: request)
        }
        minimizationWorker = (request.operationID, task)
    }

    @MainActor
    func minimizeUnattachedWindows(
        knownWindows: [WindowInfo],
        recentWindows: [WindowInfo] = [],
        refreshWindowList: Bool = false,
        mergeWindows: @escaping @MainActor ([WindowInfo]) -> Void = { _ in },
        removeWindows: @escaping @MainActor (Set<WindowInfo.ID>) -> Void = { _ in }
    ) {
        startManualMinimization(knownWindows: knownWindows, recentWindows: recentWindows,
            refreshWindowList: refreshWindowList, removeWindows: removeWindows)
    }

    @MainActor
    func restoreMinimizedWindows(mergeWindows: @escaping @MainActor ([WindowInfo]) -> Void = { _ in }) {
        guard !isRestoringMinimized, !minimizedWindows.isEmpty else {
            return
        }

        let targets = minimizedLedger.values.sorted { $0.insertionOrder < $1.insertionOrder }.map {
            LedgerRestoreTarget(identity: $0.identity, window: $0.window, expectedEntryVersion: $0.entryVersion)
        }
        let operationID = UUID()
        let intentID = latestMinimizationIntent?.id ?? MinimizationIntentID(value: 0)
        isRestoringMinimized = true
        statusMessage = "Restoring \(targets.count) minimized window(s)..."

        Task.detached(priority: .userInitiated) {
            let service = self.windowServiceFactory()
            var restoredWindows: [WindowInfo] = []
            var failureCount = 0
            for (index, target) in targets.enumerated() {
                let outcome: StepOutcome
                switch service.minimizedObservation(of: target.window).state {
                case .failure(let issue): outcome = .readFailed(issue)
                case .success(false): outcome = .alreadyDesired
                case .success(true):
                    do {
                        try service.setMinimized(false, for: target.window)
                        outcome = .changed
                    } catch {
                        let issue: WindowInspectionIssue
                        if let inspection = error as? WindowInspectionIssue {
                            issue = inspection
                        } else if case let WindowBoardAXError.operationFailed(_, axError) = error {
                            issue = WindowInspectionIssue(stage: .restoreMinimized, pid: target.window.pid,
                                windowID: target.window.id, failure: .ax(axError))
                        } else {
                            issue = WindowInspectionIssue(stage: .restoreMinimized, pid: target.window.pid,
                                windowID: target.window.id, failure: .invalidValue)
                        }
                        outcome = .writeFailed(issue, observedAfter: service.minimizedObservation(of: target.window))
                    }
                }
                let receipt = StepReceipt(operationID: operationID, intentID: intentID, stepID: UInt64(index),
                    identity: target.identity, window: target.window, desiredMinimized: false,
                    outcome: outcome, expectedLedgerVersion: target.expectedEntryVersion)
                await MainActor.run { self.commitReceipt(receipt) }
                switch outcome {
                case .changed: restoredWindows.append(target.window)
                case .alreadyDesired:
                    restoredWindows.append(target.window)
                case .readFailed: failureCount += 1
                case .writeFailed(_, let observation):
                    failureCount += 1
                    if case .success(false)? = observation?.state {
                        restoredWindows.append(target.window)
                    }
                default: break
                }
            }
            let resolvedRestoredWindows = restoredWindows
            let resolvedFailureCount = failureCount
            await MainActor.run {
                self.recordedMinimizationReceipts = self.recordedMinimizationReceipts.filter { $0.operationID != operationID }
                self.isRestoringMinimized = false
                defer { self.drainAutomaticMinimization() }
                guard intentID == (self.latestMinimizationIntent?.id ?? MinimizationIntentID(value: 0)) else { return }
                mergeWindows(resolvedRestoredWindows)
                if resolvedFailureCount == 0 {
                    self.statusMessage = "Restored \(resolvedRestoredWindows.count) minimized window(s)."
                } else {
                    self.statusMessage = "Restored \(resolvedRestoredWindows.count) window(s). \(resolvedFailureCount) window operation(s) reported an error."
                }
            }
        }
    }


    func detachWindow(id: AttachedWindow.ID, boardOrigin: CGPoint?) {
        let ownerBoardID = attachmentOwnerBoardIDs[id] ?? activeWorkspaceID
        attachedWindows.removeAll { $0.id == id }
        includedAttachmentIDs.remove(id)
        attachmentOwnerBoardIDs[id] = nil
        unavailableAttachedWindowIDs.remove(id)
        reconnectingAttachedWindowIDs.remove(id)
        minimizedAttachedWindowIDs.remove(id)
        if let ownerBoardID,
           let owner = workspaceStore.workspaces.first(where: { $0.id == ownerBoardID }) {
            let remainingReferences = owner.windows.filter { $0.id != id }
            _ = workspaceStore.updateWorkspace(id: ownerBoardID, windows: remainingReferences)
            if let activeWorkspaceID {
                currentBoardComposition = boardCompositionStore.resolveCurrentBoard(
                    primaryID: activeWorkspaceID,
                    workspaces: workspaceStore.workspaces
                )
            }
        }
        statusMessage = "Removed window from board."
    }

    @discardableResult
    func moveAttachedWindow(
        id: AttachedWindow.ID,
        toBoardID destinationBoardID: SavedWorkspace.ID
    ) -> BoardWindowMutationResult {
        guard !reconnectingAttachedWindowIDs.contains(id) else {
            return .busy
        }
        guard let attachedWindow = attachedWindows.first(where: { $0.id == id }) else {
            return .missingWindow
        }
        guard let sourceBoardID = attachmentOwnerBoardIDs[id] ?? activeWorkspaceID,
              let sourceBoard = workspaceStore.workspaces.first(where: { $0.id == sourceBoardID }),
              let destinationBoard = workspaceStore.workspaces.first(where: { $0.id == destinationBoardID }) else {
            return .missingBoard
        }
        guard sourceBoardID != destinationBoardID else {
            return .duplicate
        }

        let reference = attachedWindow.savedReference
            ?? sourceBoard.windows.first(where: { $0.id == id })
            ?? SavedWindowReference.makePreservingOffset(from: attachedWindow)
        guard !destinationBoard.windows.contains(where: { candidate in
            candidate.id == reference.id || Self.referencesDescribeSameWindow(candidate, reference)
        }) else {
            return .duplicate
        }

        let sourceReferences = sourceBoard.windows.filter { $0.id != reference.id }
        var destinationReferences = destinationBoard.windows
        destinationReferences.append(reference)
        guard workspaceStore.updateWorkspace(id: sourceBoardID, windows: sourceReferences) != nil,
              workspaceStore.updateWorkspace(id: destinationBoardID, windows: destinationReferences) != nil else {
            return .missingBoard
        }

        if let index = attachedWindows.firstIndex(where: { $0.id == id }) {
            attachedWindows[index].savedReference = reference
        }
        loadedWindowIDsByWorkspaceID[sourceBoardID]?[reference.id] = nil
        loadedWindowIDsByWorkspaceID[destinationBoardID, default: [:]][reference.id] = attachedWindow.window.id
        refreshCurrentCompositionAfterBoardWindowMutation()
        statusMessage = BoardWindowMutationResult.moved.userMessage
        return .moved
    }

    @discardableResult
    func reorderAttachedWindow(
        id: AttachedWindow.ID,
        before destinationID: AttachedWindow.ID?
    ) -> BoardWindowMutationResult {
        guard !reconnectingAttachedWindowIDs.contains(id) else {
            return .busy
        }
        guard let sourceBoardID = attachmentOwnerBoardIDs[id] ?? activeWorkspaceID,
              let sourceBoard = workspaceStore.workspaces.first(where: { $0.id == sourceBoardID }),
              let sourceIndex = sourceBoard.windows.firstIndex(where: { $0.id == id }) else {
            return .missingWindow
        }

        var references = sourceBoard.windows
        let reference = references.remove(at: sourceIndex)
        if let destinationID,
           let destinationIndex = references.firstIndex(where: { $0.id == destinationID }) {
            references.insert(reference, at: destinationIndex)
        } else {
            references.append(reference)
        }
        guard workspaceStore.updateWorkspace(id: sourceBoardID, windows: references) != nil else {
            return .missingBoard
        }

        refreshCurrentCompositionAfterBoardWindowMutation()
        statusMessage = BoardWindowMutationResult.reordered.userMessage
        return .reordered
    }

    func detachAll(boardOrigin: CGPoint?, message: String) {
        let primaryIDs = Set(primaryAttachedWindows.map(\.id))
        attachedWindows.removeAll { primaryIDs.contains($0.id) }
        unavailableAttachedWindowIDs.subtract(primaryIDs)
        reconnectingAttachedWindowIDs.subtract(primaryIDs)
        minimizedAttachedWindowIDs.subtract(primaryIDs)
        primaryIDs.forEach { attachmentOwnerBoardIDs[$0] = nil }
        if let activeWorkspaceID {
            _ = workspaceStore.updateWorkspace(id: activeWorkspaceID, windows: [])
            currentBoardComposition = boardCompositionStore.resolveCurrentBoard(
                primaryID: activeWorkspaceID,
                workspaces: workspaceStore.workspaces
            )
        }
        statusMessage = message
    }

    private func refreshCurrentCompositionAfterBoardWindowMutation() {
        guard let activeWorkspaceID else { return }
        let composition = boardCompositionStore.resolveCurrentBoard(
            primaryID: activeWorkspaceID,
            workspaces: workspaceStore.workspaces
        )
        let ownerByReferenceID = Dictionary(
            uniqueKeysWithValues: composition.uniqueWindowReferences.map { ($0.reference.id, $0.ownerBoardID) }
        )
        let visibleReferenceIDs = Set(ownerByReferenceID.keys)
        let removedAttachmentIDs = Set(attachedWindows.map(\.id)).subtracting(visibleReferenceIDs)
        attachedWindows.removeAll { !visibleReferenceIDs.contains($0.id) }
        unavailableAttachedWindowIDs.subtract(removedAttachmentIDs)
        reconnectingAttachedWindowIDs.subtract(removedAttachmentIDs)
        minimizedAttachedWindowIDs.subtract(removedAttachmentIDs)
        attachmentOwnerBoardIDs = ownerByReferenceID
        includedAttachmentIDs = Set(attachedWindows.compactMap { attachedWindow in
            guard let ownerBoardID = ownerByReferenceID[attachedWindow.id],
                  ownerBoardID != activeWorkspaceID else {
                return nil
            }
            return attachedWindow.id
        })
        currentBoardComposition = composition
    }

    private static func referencesDescribeSameWindow(
        _ lhs: SavedWindowReference,
        _ rhs: SavedWindowReference
    ) -> Bool {
        if lhs.bundleIdentifier != nil,
           lhs.bundleIdentifier == rhs.bundleIdentifier,
           let lhsDocumentURL = lhs.documentURLString,
           !lhsDocumentURL.isEmpty,
           lhsDocumentURL == rhs.documentURLString {
            return true
        }
        if lhs.bundleIdentifier != nil,
           lhs.bundleIdentifier == rhs.bundleIdentifier,
           !lhs.title.isEmpty,
           lhs.title == rhs.title {
            return true
        }
        return lhs.appName == rhs.appName && !lhs.title.isEmpty && lhs.title == rhs.title
    }

    private static func windowsReferToSameWindow(_ lhs: WindowInfo, _ rhs: WindowInfo) -> Bool {
        if lhs.id == rhs.id {
            return true
        }
        if let lhsWindowNumber = lhs.windowNumber,
           let rhsWindowNumber = rhs.windowNumber,
           lhs.pid == rhs.pid,
           lhsWindowNumber == rhsWindowNumber {
            return true
        }
        guard lhs.pid == rhs.pid,
              lhs.appName == rhs.appName,
              lhs.title == rhs.title else {
            return false
        }
        if let lhsDocumentURL = lhs.documentURL,
           let rhsDocumentURL = rhs.documentURL {
            return lhsDocumentURL == rhsDocumentURL
        }
        if let lhsPosition = lhs.position,
           let rhsPosition = rhs.position {
            return originsMatch(lhsPosition, rhsPosition)
        }
        return lhs.windowNumber == nil && rhs.windowNumber == nil
    }

    func markAttachedWindowAvailable(_ id: AttachedWindow.ID) {
        unavailableAttachedWindowIDs.remove(id)
        reconnectingAttachedWindowIDs.remove(id)
    }

    func markAttachedWindowUnavailable(_ id: AttachedWindow.ID) {
        unavailableAttachedWindowIDs.insert(id)
    }

    func isUnavailable(_ id: AttachedWindow.ID) -> Bool {
        unavailableAttachedWindowIDs.contains(id)
    }

    func isReconnecting(_ id: AttachedWindow.ID) -> Bool {
        reconnectingAttachedWindowIDs.contains(id)
    }

    func isMinimized(_ id: AttachedWindow.ID) -> Bool {
        minimizedAttachedWindowIDs.contains(id)
    }

    func attachedWindowSessionState(for id: AttachedWindow.ID) -> AttachedWindowSessionState {
        if isLoadingWorkspace {
            return .resolving
        }
        if reconnectingAttachedWindowIDs.contains(id) {
            return .reconnecting
        }
        if unavailableAttachedWindowIDs.contains(id) {
            return .unavailable
        }
        if minimizedAttachedWindowIDs.contains(id) {
            return .minimized
        }
        return .available
    }

    @MainActor
    func rememberMinimizedWindow(_ window: WindowInfo) {
        upsertMinimizedWindow(window)
    }

    func rememberLoadedWindowIDs(for workspaceID: SavedWorkspace.ID, attachedWindows: [AttachedWindow]) {
        var loadedWindowIDs: [SavedWindowReference.ID: WindowInfo.ID] = [:]
        for attachedWindow in attachedWindows {
            guard let referenceID = attachedWindow.savedReference?.id else {
                continue
            }

            loadedWindowIDs[referenceID] = attachedWindow.window.id
        }

        loadedWindowIDsByWorkspaceID[workspaceID] = loadedWindowIDs
    }

    @MainActor
    func applyDeferredRecovery(
        _ recoveredAttachments: [AttachedWindow.ID: AttachedWindow],
        failedAttachments: [AttachedWindow],
        workspaceID: SavedWorkspace.ID,
        minimizationIntentID: MinimizationIntentID? = nil
    ) {
        guard activeWorkspaceID == workspaceID else { return }
        if let minimizationIntentID, latestMinimizationIntent?.id != minimizationIntentID { return }
        var recoveredCount = 0
        var failedCount = 0

        for failedAttachment in failedAttachments {
            guard let index = attachedWindows.firstIndex(where: { $0.id == failedAttachment.id }) else {
                continue
            }

            if let recoveredAttachment = recoveredAttachments[failedAttachment.id] {
                attachedWindows[index] = AttachedWindow(
                    attachmentID: failedAttachment.id,
                    window: recoveredAttachment.window,
                    savedReference: recoveredAttachment.savedReference,
                    lastBoardOrigin: recoveredAttachment.lastBoardOrigin,
                    lastWindowOrigin: recoveredAttachment.lastWindowOrigin,
                    lastAppliedOrigin: recoveredAttachment.lastAppliedOrigin,
                    pendingReleaseOrigin: recoveredAttachment.pendingReleaseOrigin
                )
                markAttachedWindowAvailable(failedAttachment.id)
                recoveredCount += 1
            } else if Self.shouldKeepUnavailableState(
                for: attachedWindows[index]
            ) {
                unavailableAttachedWindowIDs.insert(failedAttachment.id)
                failedCount += 1
            } else {
                unavailableAttachedWindowIDs.remove(failedAttachment.id)
            }
        }

        rememberLoadedWindowIDs(
            for: workspaceID,
            attachedWindows: attachedWindows.filter { !includedAttachmentIDs.contains($0.id) }
        )

        if recoveredCount > 0 || failedCount > 0 {
            var parts: [String] = []
            if recoveredCount > 0 {
                parts.append("Reconnected \(recoveredCount) closed window(s).")
            }
            if failedCount > 0 {
                parts.append("\(failedCount) unavailable.")
            }
            statusMessage = parts.joined(separator: " ")
        }
        if recoveredCount > 0, let minimizationIntentID {
            reconcileAfterDeferredRecovery(intent: minimizationIntentID)
        }
    }

    private func recoverMissingAttachmentsAfterWorkspaceSwitch(
        _ attachments: [AttachedWindow],
        workspaceID: SavedWorkspace.ID,
        minimizationIntentID: MinimizationIntentID,
        boardOrigin: CGPoint,
        useSavedOrigin: Bool,
        service: any WorkspaceWindowOperating
    ) async {
        let attachments = Self.uniqueAttachments(attachments)
        guard !attachments.isEmpty else {
            return
        }

        let attachmentIDs = Set(attachments.map(\.id))
        let shouldRecover = await MainActor.run {
            guard self.activeWorkspaceID == workspaceID,
                  self.latestMinimizationIntent?.id == minimizationIntentID else {
                return false
            }

            self.reconnectingAttachedWindowIDs.formUnion(attachmentIDs)
            return true
        }

        guard shouldRecover else {
            return
        }

        Self.logEvent("missing deferred recovery start")
        let recoveredAttachments = await Self.recoverMissingAttachmentsLightly(
            attachments,
            boardOrigin: boardOrigin,
            useSavedOrigin: useSavedOrigin,
            service: service
        )
        Self.logDeferredRecoveryResult(
            recoveredCount: recoveredAttachments.count,
            failedCount: attachments.count - recoveredAttachments.count
        )

        await MainActor.run {
            guard self.activeWorkspaceID == workspaceID,
                  self.latestMinimizationIntent?.id == minimizationIntentID else {
                return
            }

            self.reconnectingAttachedWindowIDs.subtract(attachmentIDs)
            self.applyDeferredRecovery(
                recoveredAttachments,
                failedAttachments: attachments,
                workspaceID: workspaceID,
                minimizationIntentID: minimizationIntentID
            )
        }
    }

    private func applyResolvedWorkspaceAttachment(
        _ attachedWindow: AttachedWindow,
        referenceID: SavedWindowReference.ID,
        workspaceID: SavedWorkspace.ID
    ) {
        guard activeWorkspaceID == workspaceID else {
            return
        }

        if let index = attachedWindows.firstIndex(where: { $0.id == attachedWindow.id }) {
            attachedWindows[index] = attachedWindow
        } else {
            attachedWindows.append(attachedWindow)
        }

        unavailableAttachedWindowIDs.remove(attachedWindow.id)
        reconnectingAttachedWindowIDs.remove(attachedWindow.id)
        minimizedAttachedWindowIDs.remove(attachedWindow.id)
        loadedWindowIDsByWorkspaceID[workspaceID, default: [:]][referenceID] = attachedWindow.window.id
    }

    private func currentWorkspaceReferences(boardOrigin: CGPoint?) -> [SavedWindowReference]? {
        guard let activeWorkspaceID else { return nil }
        return currentWorkspaceReferences(ownerBoardID: activeWorkspaceID, boardOrigin: boardOrigin)
    }

    private func persistCachedWorkspaceState(
        ownerBoardID: SavedWorkspace.ID,
        boardOrigin: CGPoint
    ) {
        var references: [SavedWindowReference] = []
        for index in attachedWindows.indices where
            (attachmentOwnerBoardIDs[attachedWindows[index].id] ?? activeWorkspaceID) == ownerBoardID {
            let reference = SavedWindowReference.make(
                from: attachedWindows[index],
                boardOrigin: boardOrigin,
                size: attachedWindows[index].savedReference?.savedSize
            )
            attachedWindows[index].savedReference = reference
            references.append(reference)
        }
        guard workspaceStore.updateWorkspace(id: ownerBoardID, windows: references) != nil else {
            return
        }
        let ownerAttachments = attachedWindows.filter {
            (attachmentOwnerBoardIDs[$0.id] ?? activeWorkspaceID) == ownerBoardID
        }
        rememberLoadedWindowIDs(for: ownerBoardID, attachedWindows: ownerAttachments)
        if let activeWorkspaceID {
            currentBoardComposition = boardCompositionStore.resolveCurrentBoard(
                primaryID: activeWorkspaceID,
                workspaces: workspaceStore.workspaces
            )
        }
    }

    private func currentWorkspaceReferences(
        ownerBoardID: SavedWorkspace.ID,
        boardOrigin: CGPoint?
    ) -> [SavedWindowReference]? {
        let service = windowServiceFactory()
        return attachedWindows.compactMap { attachedWindow in
            let attachmentOwnerID = attachmentOwnerBoardIDs[attachedWindow.id] ?? activeWorkspaceID
            guard attachmentOwnerID == ownerBoardID else {
                return nil
            }
            var snapshot = attachedWindow
            if let currentOrigin = try? service.position(of: attachedWindow.window) {
                snapshot.lastWindowOrigin = currentOrigin
            }
            let size = try? service.size(of: snapshot.window)
            guard let boardOrigin else {
                return SavedWindowReference.makePreservingOffset(
                    from: snapshot,
                    size: size
                )
            }

            return SavedWindowReference.make(
                from: snapshot,
                boardOrigin: boardOrigin,
                size: size
            )
        }
    }

    private static func makeAttachedWindow(
        _ window: WindowInfo,
        attachmentID: AttachedWindow.ID = UUID(),
        reference: SavedWindowReference,
        boardOrigin: CGPoint,
        useSavedOrigin: Bool,
        applyImmediately: Bool = true,
        raiseImmediately: Bool = true,
        service: any WorkspaceWindowOperating
    ) -> AttachedWindow {
        let targetOrigin = reference.targetOrigin(from: boardOrigin, useSavedOrigin: useSavedOrigin)
        let resolvedOrigin: CGPoint
        if applyImmediately {
            do {
                if service.isMinimized(window) {
                    try? service.setMinimized(false, for: window)
                }
                _ = applySavedSizeIfNeeded(reference.savedSize, to: window, service: service)
                let currentOrigin = try? service.position(of: window)
                if let currentOrigin, originsMatch(currentOrigin, targetOrigin) {
                    resolvedOrigin = targetOrigin
                } else {
                    try service.setPosition(targetOrigin, for: window)
                    resolvedOrigin = targetOrigin
                }
            } catch {
                resolvedOrigin = window.position ?? targetOrigin
            }
            if raiseImmediately {
                service.raise(window)
            }
        } else {
            resolvedOrigin = targetOrigin
        }

        return AttachedWindow(
            attachmentID: attachmentID,
            window: window,
            savedReference: reference,
            lastBoardOrigin: boardOrigin,
            lastWindowOrigin: resolvedOrigin,
            lastAppliedOrigin: resolvedOrigin,
            pendingReleaseOrigin: nil
        )
    }

    private static func applyWorkspaceWindowPositions(
        _ attachedWindows: [AttachedWindow],
        service: any WorkspaceWindowOperating
    ) -> SessionWindowApplicationResult {
        var appliedWindows: [AttachedWindow] = []
        var failedAttachments: [AttachedWindow] = []
        var skippedPositionCount = 0
        var setPositionCount = 0
        var setSizeCount = 0
        var failedLayoutCount = 0

        for attachedWindow in attachedWindows where attachedWindow.window.pid != 0 {
            if service.isMinimized(attachedWindow.window) {
                try? service.setMinimized(false, for: attachedWindow.window)
            }

            switch applySavedSizeIfNeeded(
                attachedWindow.savedReference?.savedSize,
                to: attachedWindow.window,
                service: service
            ) {
            case .applied:
                setSizeCount += 1
            case .failed:
                failedLayoutCount += 1
            case .skipped:
                break
            }

            if let knownOrigin = attachedWindow.window.position,
               originsMatch(knownOrigin, attachedWindow.lastWindowOrigin) {
                skippedPositionCount += 1
                appliedWindows.append(attachedWindow)
                continue
            }

            do {
                try service.setPosition(attachedWindow.lastWindowOrigin, for: attachedWindow.window)
                setPositionCount += 1
            } catch {
                failedLayoutCount += 1
            }

            appliedWindows.append(attachedWindow)
        }

        for attachedWindow in attachedWindows where attachedWindow.window.pid == 0 {
            failedAttachments.append(attachedWindow)
        }

        return SessionWindowApplicationResult(
            appliedWindows: appliedWindows,
            failedAttachments: failedAttachments,
            skippedPositionCount: skippedPositionCount,
            setPositionCount: setPositionCount,
            setSizeCount: setSizeCount,
            failedLayoutCount: failedLayoutCount
        )
    }

    private static func shouldKeepUnavailableState(for attachedWindow: AttachedWindow) -> Bool {
        attachedWindow.window.pid == 0
    }

    private static func raiseWorkspaceWindows(
        _ attachedWindows: [AttachedWindow],
        service: any WorkspaceWindowOperating
    ) {
        for attachedWindow in attachedWindows where attachedWindow.window.pid != 0 {
            service.raise(attachedWindow.window)
        }
    }

    private static func applySavedSizeIfNeeded(
        _ savedSize: CGSize?,
        to window: WindowInfo,
        service: any WorkspaceWindowOperating
    ) -> LayoutOperationResult {
        guard let savedSize, savedSize.width > 40, savedSize.height > 40 else {
            return .skipped
        }

        do {
            try service.setSize(savedSize, for: window)
            return .applied
        } catch {
            return .failed
        }
    }

    private static func recoverDeferredAttachments(
        _ failedAttachments: [AttachedWindow],
        boardOrigin: CGPoint,
        useSavedOrigin: Bool,
        service: any WorkspaceWindowOperating
    ) async -> [AttachedWindow.ID: AttachedWindow] {
        var recoveredAttachments: [AttachedWindow.ID: AttachedWindow] = [:]
        var usedWindowIDs = Set<WindowInfo.ID>()
        var unresolvedAttachments = failedAttachments.compactMap { failedAttachment -> (AttachedWindow.ID, SavedWindowReference)? in
            guard let reference = failedAttachment.savedReference else {
                return nil
            }

            return (failedAttachment.id, reference)
        }

        for (_, reference) in unresolvedAttachments {
            if reference.canRestoreWindow {
                _ = service.openSavedWindowReference(reference)
            } else {
                _ = service.activateSavedApplication(reference)
            }
        }

        let attempts = unresolvedAttachments.contains(where: { $0.1.canRestoreWindow }) ? 18 : 10
        for attempt in 0..<attempts {
            guard !Task.isCancelled, !unresolvedAttachments.isEmpty else {
                break
            }

            if attempt > 0 {
                try? await Task.sleep(for: .milliseconds(120))
            }

            if attempt == 8 {
                for (_, reference) in unresolvedAttachments {
                    if reference.canRestoreWindow {
                        _ = service.openSavedWindowReference(reference)
                    } else {
                        _ = service.activateSavedApplication(reference)
                    }
                }
            }

            let availableWindows = service.listWindows()
            var stillUnresolved: [(AttachedWindow.ID, SavedWindowReference)] = []

            for (attachmentID, reference) in unresolvedAttachments {
                guard let replacement = WorkspaceWindowResolver.bestWindow(
                    for: reference,
                    cachedWindowID: nil,
                    in: availableWindows,
                    excluding: usedWindowIDs
                ) else {
                    stillUnresolved.append((attachmentID, reference))
                    continue
                }

                let recoveredAttachment = makeAttachedWindow(
                    replacement,
                    attachmentID: attachmentID,
                    reference: reference,
                    boardOrigin: boardOrigin,
                    useSavedOrigin: useSavedOrigin,
                    applyImmediately: true,
                    raiseImmediately: false,
                    service: service
                )
                usedWindowIDs.insert(replacement.id)
                recoveredAttachments[attachmentID] = recoveredAttachment
            }

            unresolvedAttachments = stillUnresolved
        }

        return recoveredAttachments
    }

    private static func recoverMissingAttachmentsLightly(
        _ attachments: [AttachedWindow],
        boardOrigin: CGPoint,
        useSavedOrigin: Bool,
        service: any WorkspaceWindowOperating
    ) async -> [AttachedWindow.ID: AttachedWindow] {
        var recoveredAttachments: [AttachedWindow.ID: AttachedWindow] = [:]
        var usedWindowIDs = Set<WindowInfo.ID>()
        var unresolvedAttachments = attachments.compactMap { attachment -> (AttachedWindow.ID, SavedWindowReference)? in
            guard let reference = attachment.savedReference else {
                return nil
            }

            return (attachment.id, reference)
        }

        for (_, reference) in unresolvedAttachments {
            if reference.canRestoreWindow {
                _ = service.openSavedWindowReference(reference)
            } else {
                _ = service.activateSavedApplication(reference)
            }
        }

        for attempt in 0..<6 {
            guard !Task.isCancelled, !unresolvedAttachments.isEmpty else {
                break
            }

            if attempt > 0 {
                try? await Task.sleep(for: .milliseconds(120))
            }

            let availableWindows = service.listWindows()
            var stillUnresolved: [(AttachedWindow.ID, SavedWindowReference)] = []

            for (attachmentID, reference) in unresolvedAttachments {
                guard let replacement = WorkspaceWindowResolver.bestWindow(
                    for: reference,
                    cachedWindowID: nil,
                    in: availableWindows,
                    excluding: usedWindowIDs
                ) else {
                    stillUnresolved.append((attachmentID, reference))
                    continue
                }

                let recoveredAttachment = makeAttachedWindow(
                    replacement,
                    attachmentID: attachmentID,
                    reference: reference,
                    boardOrigin: boardOrigin,
                    useSavedOrigin: useSavedOrigin,
                    applyImmediately: true,
                    raiseImmediately: false,
                    service: service
                )
                usedWindowIDs.insert(replacement.id)
                recoveredAttachments[attachmentID] = recoveredAttachment
            }

            unresolvedAttachments = stillUnresolved
        }

        return recoveredAttachments
    }

    private static func originsMatch(_ lhs: CGPoint, _ rhs: CGPoint) -> Bool {
        abs(lhs.x - rhs.x) < 3 && abs(lhs.y - rhs.y) < 3
    }

    private static func sizesMatch(_ lhs: CGSize, _ rhs: CGSize) -> Bool {
        abs(lhs.width - rhs.width) < 3 && abs(lhs.height - rhs.height) < 3
    }

    private static func workspaceLoadStatus(
        loadedCount: Int,
        reconnectedCount: Int,
        restoredCount: Int,
        activatedOnlyCount: Int,
        missedCount: Int
    ) -> String {
        var parts = ["Loaded \(loadedCount) window(s)."]

        if reconnectedCount > 0 {
            parts.append("Reconnected \(reconnectedCount).")
        }

        if restoredCount > 0 {
            parts.append("Restored \(restoredCount).")
        }

        if activatedOnlyCount > 0 {
            parts.append("Activated \(activatedOnlyCount) app(s) only.")
        }

        if missedCount > 0 {
            parts.append("\(missedCount) unavailable.")
        }

        return parts.joined(separator: " ")
    }

    private static func minimizeStatus(minimizedCount: Int, restoredAttachedCount: Int, failedCount: Int) -> String {
        var message = "Minimized \(minimizedCount) unattached window(s)."

        if restoredAttachedCount > 0 {
            message += " Restored \(restoredAttachedCount) attached window(s)."
        }

        if failedCount > 0 {
            message += " \(failedCount) operation(s) failed."
        }

        return message
    }

    private static func mergeWindows(_ newWindows: [WindowInfo], into cachedWindows: [WindowInfo]) -> [WindowInfo] {
        var mergedWindows = cachedWindows
        for window in newWindows where !mergedWindows.contains(where: { $0.id == window.id }) {
            mergedWindows.append(window)
        }

        return mergedWindows.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    private static func uniqueAttachments(_ attachments: [AttachedWindow]) -> [AttachedWindow] {
        var seenIDs = Set<AttachedWindow.ID>()
        var uniqueAttachments: [AttachedWindow] = []

        for attachment in attachments where !seenIDs.contains(attachment.id) {
            seenIDs.insert(attachment.id)
            uniqueAttachments.append(attachment)
        }

        return uniqueAttachments
    }

    private static func uniqueReferences(_ references: [SavedWindowReference]) -> [SavedWindowReference] {
        var seenIDs: Set<SavedWindowReference.ID> = []
        return references.filter { seenIDs.insert($0.id).inserted }
    }

    private static func logDuration(_ operation: String, since startDate: Date) {
        #if DEBUG
        let elapsedMilliseconds = Date().timeIntervalSince(startDate) * 1_000
        workspaceSessionLogger.debug("\(operation, privacy: .public) took \(elapsedMilliseconds, format: .fixed(precision: 1), privacy: .public) ms")
        #endif
    }

    private static func logEvent(_ message: String) {
        #if DEBUG
        workspaceSessionLogger.debug("\(message, privacy: .public)")
        #endif
    }

    private static func logWindowApplicationResult(
        _ result: SessionWindowApplicationResult,
        targetCount: Int
    ) {
        #if DEBUG
        workspaceSessionLogger.debug(
            "applyWorkspaceWindowPositions target=\(targetCount, privacy: .public) applied=\(result.appliedWindows.count, privacy: .public) skippedPosition=\(result.skippedPositionCount, privacy: .public) setPosition=\(result.setPositionCount, privacy: .public) setSize=\(result.setSizeCount, privacy: .public) failed=\(result.failedAttachments.count, privacy: .public) failedLayout=\(result.failedLayoutCount, privacy: .public)"
        )
        #endif
    }

    private static func logDeferredRecoveryResult(recoveredCount: Int, failedCount: Int) {
        #if DEBUG
        if recoveredCount > 0 {
            workspaceSessionLogger.debug("missing deferred recovery success count=\(recoveredCount, privacy: .public)")
        }
        if failedCount > 0 {
            workspaceSessionLogger.debug("missing deferred recovery failed count=\(failedCount, privacy: .public)")
        }
        #endif
    }
}
