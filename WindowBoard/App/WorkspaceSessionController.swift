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

private struct SessionAttachedWindowSnapshot {
    let windowID: WindowInfo.ID
    let appName: String
    let title: String
    let pid: pid_t
    let bundleIdentifier: String?
    let documentURL: URL?
    let windowNumber: CGWindowID?
    let origin: CGPoint
    let window: WindowInfo
    let isUnavailable: Bool
    let isReconnecting: Bool
    let protectsSameApplicationFromMinimize: Bool
}

private struct SessionMinimizeWindowsResult {
    let minimizedWindows: [WindowInfo]
    let restoredAttachedWindows: [WindowInfo]
    let failedCount: Int
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
    @Published var minimizedWindows: [WindowInfo] = []
    @Published var isLoadingWorkspace = false
    @Published var isApplyingWorkspaceWindows = false
    @Published var isMinimizingUnattached = false
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
              let workspace = workspaceStore.workspaces.first(where: { $0.id == memberBoardID }) else {
            return false
        }
        if isLoadingWorkspace {
            pendingWorkspaceSwitch = PendingWorkspaceSwitch(
                workspaceID: groupPrimaryID,
                selectedBoardID: memberBoardID,
                boardOrigin: nil,
                source: .statusItem,
                followMode: .none,
                windowCache: nil,
                mergeWindows: { _ in },
                completion: { _ in },
                deferredWindowApplicationCompletion: {},
                minimizeAfterSwitchCompletion: {}
            )
            selectedWorkspaceID = memberBoardID
            workspaceName = workspace.name
            return true
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
        guard let workspace = workspaceStore.workspaces.first(where: { $0.id == workspaceID }) else {
            statusMessage = "Board not found."
            return
        }

        if isLoadingWorkspace {
            pendingWorkspaceSwitch = PendingWorkspaceSwitch(
                workspaceID: workspaceID,
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
        let shouldMinimizeAfterSwitch = defaults.bool(forKey: minimizeUnattachedOnWorkspaceSwitchKey)
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
            var resolution = WorkspaceWindowResolver.resolve(
                references: composedReferences,
                candidates: availableWindows,
                cachedWindowIDs: targetLoadedWindowIDs
            )

            if windowCache == nil || !resolution.unresolvedReferences.isEmpty {
                let listWindowsStart = Date()
                availableWindows = service.listWindows()
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
            let minimizeCandidateWindows = Self.mergeWindows(resolvedAvailableWindows, into: windowCache ?? [])
            var minimizeUnavailableAttachmentIDs = resolvedUnavailableAttachmentIDs
            Self.logDuration("workspace resolve", since: resolveStart)

            let batchUpdateStart = Date()
            await MainActor.run {
                var selectedBoardIDForBatch = resolvedSelectedBoardID
                if let pendingSwitch = self.pendingWorkspaceSwitch {
                    self.pendingWorkspaceSwitch = nil
                    if pendingSwitch.workspaceID == workspace.id {
                        if let pendingSelectedWorkspaceID = pendingSwitch.selectedBoardID,
                           boardComposition.uniqueBoards.contains(where: { $0.id == pendingSelectedWorkspaceID }) {
                            selectedBoardIDForBatch = pendingSelectedWorkspaceID
                        }
                    } else {
                        self.isLoadingWorkspace = false
                        self.switchWorkspace(
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
                            persistCurrentWorkspaceBeforeSwitch: false
                        )
                        return
                    }
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
                    minimizeUnavailableAttachmentIDs.formUnion(failedAttachments.map(\.id))
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
                let attachedWindowsToKeep = resolvedAttachedWindows
                let candidateWindowsToMinimize = minimizeCandidateWindows
                let unavailableAttachmentIDsToProtect = minimizeUnavailableAttachmentIDs
                await MainActor.run {
                    minimizeAfterSwitchCompletion()
                }
                Task.detached(priority: .utility) {
                    try? await Task.sleep(for: .milliseconds(150))
                    Self.logEvent("deferred minimize start")
                    let minimizeService = self.windowServiceFactory()
                    await self.minimizeUnattachedAfterWorkspaceSwitch(
                        keeping: attachedWindowsToKeep,
                        candidateWindows: candidateWindowsToMinimize,
                        unavailableAttachmentIDs: unavailableAttachmentIDsToProtect,
                        workspaceID: workspace.id,
                        service: minimizeService,
                        completion: {}
                    )
                }
            }
        }
    }

    @MainActor
    func minimizeUnattachedWindows(
        knownWindows: [WindowInfo],
        recentWindows: [WindowInfo] = [],
        refreshWindowList: Bool = false,
        mergeWindows: @escaping @MainActor ([WindowInfo]) -> Void = { _ in },
        removeWindows: @escaping @MainActor (Set<WindowInfo.ID>) -> Void = { _ in }
    ) {
        guard !isMinimizingUnattached else {
            return
        }

        let attachedWindowsToRefresh = attachedWindows
        isMinimizingUnattached = true
        statusMessage = "Preparing other windows..."

        Task.detached(priority: .userInitiated) {
            let service = self.windowServiceFactory()
            let baseWindows = Self.mergeWindows(recentWindows, into: knownWindows)
            let allWindows = refreshWindowList
                ? Self.mergeWindows(baseWindows, into: service.listWindows())
                : baseWindows
            var refreshedAttachedWindows: [AttachedWindow.ID: WindowInfo] = [:]
            var attachedCandidateWindows: [WindowInfo] = []

            for attachedWindow in attachedWindowsToRefresh where refreshWindowList && attachedWindow.window.pid != 0 {
                guard !Task.isCancelled else { return }

                let candidates = service.windows(matching: attachedWindow.window)
                attachedCandidateWindows.append(contentsOf: candidates)

                if let replacement = WindowMatching.bestReplacement(for: attachedWindow.window, in: candidates) {
                    refreshedAttachedWindows[attachedWindow.id] = replacement
                }
            }

            let resolvedAttachedCandidateWindows = attachedCandidateWindows
            let resolvedRefreshedAttachedWindows = refreshedAttachedWindows
            await MainActor.run {
                var effectiveWindows = Self.mergeWindows(recentWindows, into: allWindows)
                effectiveWindows = Self.mergeWindows(resolvedAttachedCandidateWindows, into: effectiveWindows)
                effectiveWindows = Self.mergeWindows(knownWindows, into: effectiveWindows)

                for (attachmentID, replacement) in resolvedRefreshedAttachedWindows {
                    guard let index = self.attachedWindows.firstIndex(where: { $0.id == attachmentID }) else {
                        continue
                    }

                    let origin = replacement.position ?? self.attachedWindows[index].lastWindowOrigin
                    self.attachedWindows[index].window = replacement
                    self.attachedWindows[index].lastWindowOrigin = origin
                    self.attachedWindows[index].lastAppliedOrigin = origin
                    self.markAttachedWindowAvailable(attachmentID)
                }

                let attachedSnapshots = self.attachedWindowSnapshots()
                let windowsToMinimize = effectiveWindows.filter {
                    Self.shouldMinimizeWindow(
                        $0,
                        attachedSnapshots: attachedSnapshots
                    )
                }

                guard !windowsToMinimize.isEmpty else {
                    self.isMinimizingUnattached = false
                    self.statusMessage = "No other windows to minimize."
                    return
                }

                self.beginMinimizing(
                    windowsToMinimize,
                    attachedSnapshots: attachedSnapshots,
                    mergeWindows: mergeWindows,
                    removeWindows: removeWindows
                )
            }
        }
    }

    @MainActor
    func restoreMinimizedWindows(mergeWindows: @escaping @MainActor ([WindowInfo]) -> Void = { _ in }) {
        guard !isRestoringMinimized, !minimizedWindows.isEmpty else {
            return
        }

        let windowsToRestore = minimizedWindows
        isRestoringMinimized = true
        statusMessage = "Restoring \(windowsToRestore.count) minimized window(s)..."

        Task.detached(priority: .userInitiated) {
            let service = self.windowServiceFactory()
            var restoredWindows: [WindowInfo] = []
            var failedWindows: [WindowInfo] = []

            for window in windowsToRestore {
                do {
                    try service.setMinimized(false, for: window)
                    restoredWindows.append(window)
                } catch {
                    if service.isMinimized(window) {
                        failedWindows.append(window)
                    }
                }
            }

            let resolvedRestoredWindows = restoredWindows
            let resolvedFailedWindows = failedWindows
            await MainActor.run {
                self.isRestoringMinimized = false
                self.minimizedWindows = resolvedFailedWindows
                mergeWindows(resolvedRestoredWindows)

                if resolvedFailedWindows.isEmpty {
                    self.statusMessage = "Restored \(resolvedRestoredWindows.count) minimized window(s)."
                } else {
                    self.statusMessage = "Restored \(resolvedRestoredWindows.count) window(s). \(resolvedFailedWindows.count) could not be restored."
                }
            }
        }
    }

    private func minimizeUnattachedAfterWorkspaceSwitch(
        keeping attachedWindows: [AttachedWindow],
        candidateWindows: [WindowInfo],
        unavailableAttachmentIDs: Set<AttachedWindow.ID>,
        workspaceID: SavedWorkspace.ID,
        service: any WorkspaceWindowOperating,
        completion: @escaping @MainActor () -> Void
    ) async {
        let shouldStart = await MainActor.run {
            guard self.activeWorkspaceID == workspaceID,
                  !self.isMinimizingUnattached,
                  !attachedWindows.isEmpty else {
                return false
            }

            self.isMinimizingUnattached = true
            self.statusMessage = "Minimizing other windows..."
            return true
        }

        guard shouldStart else {
            return
        }

        let minimizeStart = Date()
        let result = Self.minimizeUnattachedWindows(
            keeping: attachedWindows,
            candidateWindows: candidateWindows,
            unavailableAttachmentIDs: unavailableAttachmentIDs,
            service: service
        )
        Self.logDuration("minimizeUnattachedAfterWorkspaceSwitch", since: minimizeStart)

        await MainActor.run {
            guard self.activeWorkspaceID == workspaceID else {
                self.isMinimizingUnattached = false
                return
            }

            self.isMinimizingUnattached = false
            for window in result.minimizedWindows {
                self.rememberMinimizedWindow(window)
            }
            self.statusMessage = Self.minimizeStatus(
                minimizedCount: result.minimizedWindows.count,
                restoredAttachedCount: result.restoredAttachedWindows.count,
                failedCount: result.failedCount
            )
            completion()
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
        guard !minimizedWindows.contains(where: { $0.id == window.id }) else {
            return
        }

        minimizedWindows.append(window)
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
    private func applyDeferredRecovery(
        _ recoveredAttachments: [AttachedWindow.ID: AttachedWindow],
        failedAttachments: [AttachedWindow],
        workspaceID: SavedWorkspace.ID
    ) {
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
    }

    private func recoverMissingAttachmentsAfterWorkspaceSwitch(
        _ attachments: [AttachedWindow],
        workspaceID: SavedWorkspace.ID,
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
            guard self.activeWorkspaceID == workspaceID else {
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
            guard self.activeWorkspaceID == workspaceID else {
                return
            }

            self.applyDeferredRecovery(
                recoveredAttachments,
                failedAttachments: attachments,
                workspaceID: workspaceID
            )
            self.reconnectingAttachedWindowIDs.subtract(attachmentIDs)
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

    private func attachedWindowSnapshots() -> [SessionAttachedWindowSnapshot] {
        attachedWindows.map { attachedWindow in
            SessionAttachedWindowSnapshot(
                windowID: attachedWindow.window.id,
                appName: attachedWindow.window.appName,
                title: attachedWindow.window.title,
                pid: attachedWindow.window.pid,
                bundleIdentifier: attachedWindow.window.bundleIdentifier,
                documentURL: attachedWindow.window.documentURL,
                windowNumber: attachedWindow.window.windowNumber,
                origin: attachedWindow.lastWindowOrigin,
                window: attachedWindow.window,
                isUnavailable: isUnavailable(attachedWindow.id),
                isReconnecting: isReconnecting(attachedWindow.id),
                protectsSameApplicationFromMinimize: Self.shouldProtectSameApplicationFromMinimize(attachedWindow.window)
            )
        }
    }

    @MainActor
    private func beginMinimizing(
        _ windowsToMinimize: [WindowInfo],
        attachedSnapshots: [SessionAttachedWindowSnapshot],
        mergeWindows: @escaping @MainActor ([WindowInfo]) -> Void,
        removeWindows: @escaping @MainActor (Set<WindowInfo.ID>) -> Void
    ) {
        statusMessage = "Minimizing \(windowsToMinimize.count) unattached window(s)..."

        Task.detached(priority: .userInitiated) {
            let service = self.windowServiceFactory()
            let result = Self.minimizeWindows(windowsToMinimize, attachedSnapshots: attachedSnapshots, service: service)

            await MainActor.run {
                self.isMinimizingUnattached = false
                let minimizedIDs = Set(result.minimizedWindows.map(\.id))
                for window in result.minimizedWindows {
                    self.rememberMinimizedWindow(window)
                }
                removeWindows(minimizedIDs)
                self.statusMessage = Self.minimizeStatus(
                    minimizedCount: result.minimizedWindows.count,
                    restoredAttachedCount: result.restoredAttachedWindows.count,
                    failedCount: result.failedCount
                )
            }
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

    private static func minimizeUnattachedWindows(
        keeping attachedWindows: [AttachedWindow],
        candidateWindows: [WindowInfo],
        unavailableAttachmentIDs: Set<AttachedWindow.ID>,
        service: any WorkspaceWindowOperating
    ) -> SessionMinimizeWindowsResult {
        let snapshots = attachedWindows.map {
            let isUnavailable = $0.window.pid == 0 || unavailableAttachmentIDs.contains($0.id)
            return SessionAttachedWindowSnapshot(
                windowID: $0.window.id,
                appName: $0.window.appName,
                title: $0.window.title,
                pid: $0.window.pid,
                bundleIdentifier: $0.window.bundleIdentifier,
                documentURL: $0.window.documentURL,
                windowNumber: $0.window.windowNumber,
                origin: $0.lastWindowOrigin,
                window: $0.window,
                isUnavailable: isUnavailable,
                isReconnecting: false,
                protectsSameApplicationFromMinimize: shouldProtectSameApplicationFromMinimize($0.window)
            )
        }
        let windowsToMinimize = candidateWindows.filter {
            shouldMinimizeWindow(
                $0,
                attachedSnapshots: snapshots
            )
        }
        return minimizeWindows(windowsToMinimize, attachedSnapshots: snapshots, service: service)
    }

    private static func minimizeWindows(
        _ windowsToMinimize: [WindowInfo],
        attachedSnapshots: [SessionAttachedWindowSnapshot],
        service: any WorkspaceWindowOperating
    ) -> SessionMinimizeWindowsResult {
        var minimizedWindows: [WindowInfo] = []
        var restoredAttachedWindows: [WindowInfo] = []
        var failedCount = 0

        for window in windowsToMinimize {
            guard !service.isMinimized(window) else {
                continue
            }

            do {
                try service.setMinimized(true, for: window)
                minimizedWindows.append(window)
            } catch {
                failedCount += 1
            }
        }

        for snapshot in attachedSnapshots {
            guard !snapshot.isUnavailable, !snapshot.isReconnecting else {
                continue
            }

            guard service.isMinimized(snapshot.window) else {
                continue
            }

            do {
                try service.setMinimized(false, for: snapshot.window)
                restoredAttachedWindows.append(snapshot.window)
            } catch {
                failedCount += 1
            }
        }

        return SessionMinimizeWindowsResult(
            minimizedWindows: minimizedWindows,
            restoredAttachedWindows: restoredAttachedWindows,
            failedCount: failedCount
        )
    }

    private static func shouldMinimizeWindow(
        _ window: WindowInfo,
        attachedSnapshots: [SessionAttachedWindowSnapshot]
    ) -> Bool {
        guard !isAttachedWindow(window, attachedSnapshots: attachedSnapshots) else {
            return false
        }

        return !isAmbiguousSameAppWindow(window, attachedSnapshots: attachedSnapshots)
    }

    private static func isAttachedWindow(
        _ window: WindowInfo,
        attachedSnapshots: [SessionAttachedWindowSnapshot]
    ) -> Bool {
        for snapshot in attachedSnapshots {
            if snapshot.windowID == window.id {
                return true
            }

            if let snapshotWindowNumber = snapshot.windowNumber,
               let windowNumber = window.windowNumber,
               snapshot.pid == window.pid,
               snapshotWindowNumber == windowNumber {
                return true
            }

            guard snapshot.pid == window.pid,
                  snapshot.appName == window.appName,
                  snapshot.title == window.title,
                  let candidateOrigin = window.position else {
                continue
            }

            if originsMatch(snapshot.origin, candidateOrigin) {
                return true
            }
        }

        return false
    }

    private static func isAmbiguousSameAppWindow(
        _ window: WindowInfo,
        attachedSnapshots: [SessionAttachedWindowSnapshot]
    ) -> Bool {
        attachedSnapshots.contains { snapshot in
            guard !snapshot.isUnavailable, !snapshot.isReconnecting else {
                return false
            }

            guard isSameApplication(window, snapshot: snapshot) else {
                return false
            }

            if isStrictMultiWindowApplication(window.bundleIdentifier)
                || isStrictMultiWindowApplication(snapshot.bundleIdentifier) {
                return false
            }

            if snapshot.protectsSameApplicationFromMinimize {
                return true
            }

            if window.windowNumber != nil, snapshot.windowNumber != nil {
                return false
            }

            if window.documentURL != nil, snapshot.documentURL != nil {
                return false
            }

            let windowTitle = window.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let snapshotTitle = snapshot.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !windowTitle.isEmpty,
               !snapshotTitle.isEmpty,
               windowTitle != snapshotTitle {
                return false
            }

            return true
        }
    }

    private static func isSameApplication(_ window: WindowInfo, snapshot: SessionAttachedWindowSnapshot) -> Bool {
        if let windowBundleIdentifier = window.bundleIdentifier,
           let snapshotBundleIdentifier = snapshot.bundleIdentifier {
            return windowBundleIdentifier == snapshotBundleIdentifier
        }

        return window.pid == snapshot.pid || window.appName == snapshot.appName
    }

    private static func isStrictMultiWindowApplication(_ bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else {
            return false
        }

        return SavedWindowReference.isVisualStudioCode(bundleIdentifier: bundleIdentifier)
    }

    private static func shouldProtectSameApplicationFromMinimize(_ window: WindowInfo) -> Bool {
        let protectedBundleIdentifiers: Set<String> = [
            "com.apple.Terminal"
        ]

        guard let bundleIdentifier = window.bundleIdentifier else {
            return false
        }

        return protectedBundleIdentifiers.contains(bundleIdentifier)
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
