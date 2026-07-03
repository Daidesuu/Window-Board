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
}

private func bestReplacementWindow(for originalWindow: WindowInfo, in candidates: [WindowInfo]) -> WindowInfo? {
    let appCandidates = candidates.filter { candidate in
        if let originalBundleIdentifier = originalWindow.bundleIdentifier,
           let candidateBundleIdentifier = candidate.bundleIdentifier {
            return originalBundleIdentifier == candidateBundleIdentifier
        }

        return candidate.appName == originalWindow.appName
    }

    if let originalDocumentURL = originalWindow.documentURL,
       let documentMatch = appCandidates.first(where: { $0.documentURL == originalDocumentURL }) {
        return documentMatch
    }

    let trimmedTitle = originalWindow.title.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmedTitle.isEmpty,
       let titleMatch = appCandidates.first(where: {
           $0.title.trimmingCharacters(in: .whitespacesAndNewlines) == trimmedTitle
       }) {
        return titleMatch
    }

    return appCandidates.first
}

private func bestSavedWorkspaceWindow(
    for reference: SavedWindowReference,
    in candidates: [WindowInfo],
    excluding usedWindowIDs: Set<WindowInfo.ID>
) -> WindowInfo? {
    let appCandidates = candidates.filter { candidate in
        guard !usedWindowIDs.contains(candidate.id) else {
            return false
        }

        if let referenceBundleIdentifier = reference.bundleIdentifier,
           let candidateBundleIdentifier = candidate.bundleIdentifier {
            return referenceBundleIdentifier == candidateBundleIdentifier
        }

        return candidate.appName == reference.appName
    }

    if !reference.isVisualStudioCode,
       let referenceDocumentURL = reference.documentURL,
       let documentMatch = appCandidates.first(where: { $0.documentURL == referenceDocumentURL }) {
        return documentMatch
    }

    let trimmedTitle = reference.title.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmedTitle.isEmpty,
       let titleMatch = appCandidates.first(where: {
           $0.title.trimmingCharacters(in: .whitespacesAndNewlines) == trimmedTitle
       }) {
        return titleMatch
    }

    return appCandidates.first
}

private func placeholderWindowInfo(for reference: SavedWindowReference) -> WindowInfo {
    WindowInfo(
        id: "saved-placeholder-\(reference.id.uuidString)",
        appName: reference.appName,
        title: reference.title,
        pid: 0,
        bundleIdentifier: reference.bundleIdentifier,
        bundleURL: reference.bundleURL,
        documentURL: reference.documentURL,
        axWindow: AXUIElementCreateApplication(0),
        windowNumber: nil,
        position: nil
    )
}

final class WorkspaceSessionController: ObservableObject {
    let workspaceStore: WorkspaceStore

    @Published var selectedWorkspaceID: SavedWorkspace.ID?
    @Published var activeWorkspaceID: SavedWorkspace.ID? {
        didSet {
            if let activeWorkspaceID {
                defaults.set(activeWorkspaceID.uuidString, forKey: "activeWorkspaceID")
            } else {
                defaults.removeObject(forKey: "activeWorkspaceID")
            }
        }
    }
    @Published var workspaceName = ""
    @Published var attachedWindows: [AttachedWindow] = []
    @Published var unavailableAttachedWindowIDs: Set<AttachedWindow.ID> = []
    @Published var reconnectingAttachedWindowIDs: Set<AttachedWindow.ID> = []
    @Published var minimizedWindows: [WindowInfo] = []
    @Published var isLoadingWorkspace = false
    @Published var isMinimizingUnattached = false
    @Published var isRestoringMinimized = false
    @Published var statusMessage = "Select a window to attach it to the board."

    private var loadedWindowIDsByWorkspaceID: [SavedWorkspace.ID: [SavedWindowReference.ID: WindowInfo.ID]] = [:]
    private var pendingWorkspaceID: SavedWorkspace.ID?
    private let defaults: UserDefaults
    private let minimizeUnattachedOnWorkspaceSwitchKey = "minimizeUnattachedOnWorkspaceSwitch"
    private let restoreMissingWindowsOnWorkspaceSwitchKey = "restoreMissingWindowsOnWorkspaceSwitch"

    init(workspaceStore: WorkspaceStore, defaults: UserDefaults = .standard) {
        self.workspaceStore = workspaceStore
        self.defaults = defaults
        workspaceStore.ensureDefaultWorkspace()
        let storedActiveWorkspaceID = defaults.string(forKey: "activeWorkspaceID").flatMap(UUID.init(uuidString:))
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

    func saveCurrentWorkspace(name: String, boardOrigin: CGPoint?) {
        guard !attachedWindows.isEmpty,
              let references = currentWorkspaceReferences(boardOrigin: boardOrigin) else {
            return
        }

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = trimmedName.isEmpty
            ? "Workspace \(workspaceStore.workspaces.count + 1)"
            : trimmedName
        let workspace = workspaceStore.saveWorkspace(name: resolvedName, windows: references)
        selectedWorkspaceID = workspace.id
        activeWorkspaceID = workspace.id
        workspaceName = workspace.name
        rememberLoadedWindowIDs(for: workspace.id, attachedWindows: attachedWindows)
        statusMessage = "Saved \(workspace.displayName)."
    }

    func createWorkspace(boardOrigin: CGPoint?) {
        if !attachedWindows.isEmpty {
            persistActiveWorkspaceState(boardOrigin: boardOrigin)
        }

        let workspace = workspaceStore.saveWorkspace(name: nextWorkspaceName(), windows: [])
        selectedWorkspaceID = workspace.id
        activeWorkspaceID = workspace.id
        workspaceName = workspace.name
        attachedWindows = []
        unavailableAttachedWindowIDs.removeAll()
        reconnectingAttachedWindowIDs.removeAll()
        loadedWindowIDsByWorkspaceID[workspace.id] = [:]
        statusMessage = "Created \(workspace.displayName)."
    }

    func overwriteSelectedWorkspace(name: String, boardOrigin: CGPoint?) {
        guard let selectedWorkspaceID,
              !attachedWindows.isEmpty,
              let references = currentWorkspaceReferences(boardOrigin: boardOrigin) else {
            return
        }

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName: String?
        if selectedWorkspace?.isDefault == true {
            resolvedName = WorkspaceStore.defaultWorkspaceName
        } else {
            resolvedName = trimmedName.isEmpty ? selectedWorkspace?.name : trimmedName
        }
        guard let workspace = workspaceStore.updateWorkspace(
            id: selectedWorkspaceID,
            name: resolvedName,
            windows: references
        ) else {
            return
        }

        workspaceName = workspace.name
        activeWorkspaceID = workspace.id
        rememberLoadedWindowIDs(for: workspace.id, attachedWindows: attachedWindows)
        statusMessage = "Overwrote \(workspace.displayName)."
    }

    func renameSelectedWorkspace(name: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let selectedWorkspaceID,
              !trimmedName.isEmpty else {
            return
        }

        guard selectedWorkspace?.isDefault != true else {
            workspaceName = WorkspaceStore.defaultWorkspaceName
            statusMessage = "Default workspace cannot be renamed."
            return
        }

        guard let workspace = workspaceStore.updateWorkspace(id: selectedWorkspaceID, name: trimmedName) else {
            return
        }

        workspaceName = workspace.name
        statusMessage = "Renamed workspace to \(workspace.name)."
    }

    private func nextWorkspaceName() -> String {
        let existingNames = Set(workspaceStore.workspaces.map(\.name))
        var index = workspaceStore.workspaces.count + 1

        while existingNames.contains("Workspace \(index)") {
            index += 1
        }

        return "Workspace \(index)"
    }

    func deleteSelectedWorkspace() {
        guard let selectedWorkspaceID else {
            return
        }

        guard selectedWorkspace?.isDefault != true else {
            statusMessage = "Default workspace cannot be deleted."
            return
        }

        workspaceStore.deleteWorkspace(id: selectedWorkspaceID)
        if activeWorkspaceID == selectedWorkspaceID {
            activeWorkspaceID = nil
        }
        self.selectedWorkspaceID = workspaceStore.defaultWorkspace?.id
        workspaceName = workspaceStore.defaultWorkspace?.name ?? ""
        statusMessage = "Deleted workspace."
    }

    @discardableResult
    func persistActiveWorkspaceState(boardOrigin: CGPoint?) -> SavedWorkspace? {
        guard let activeWorkspaceID,
              let references = currentWorkspaceReferences(boardOrigin: boardOrigin) else {
            return nil
        }

        let workspace = workspaceStore.updateWorkspace(id: activeWorkspaceID, windows: references)
        if let workspace {
            rememberLoadedWindowIDs(for: workspace.id, attachedWindows: attachedWindows)
        }
        return workspace
    }

    func persistActiveWorkspaceSnapshot(sizeByAttachmentID: [AttachedWindow.ID: CGSize] = [:]) -> SavedWorkspace? {
        guard let activeWorkspaceID,
              !attachedWindows.isEmpty else {
            return nil
        }

        let references = attachedWindows.map {
            SavedWindowReference.makePreservingOffset(
                from: $0,
                size: sizeByAttachmentID[$0.id]
            )
        }
        let workspace = workspaceStore.updateWorkspace(id: activeWorkspaceID, windows: references)
        if let workspace {
            rememberLoadedWindowIDs(for: workspace.id, attachedWindows: attachedWindows)
        }
        return workspace
    }

    @discardableResult
    func persistActiveWorkspaceSnapshotForSwitch(boardOrigin: CGPoint?) -> SavedWorkspace? {
        guard let activeWorkspaceID else {
            return nil
        }

        let references = attachedWindows.map { attachedWindow in
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
            rememberLoadedWindowIDs(for: workspace.id, attachedWindows: attachedWindows)
        }
        return workspace
    }

    func switchWorkspace(
        id workspaceID: SavedWorkspace.ID,
        boardOrigin: CGPoint?,
        source: WorkspaceSwitchSource,
        followMode: FollowMode,
        windowCache: [WindowInfo]? = nil,
        mergeWindows: @escaping @MainActor ([WindowInfo]) -> Void = { _ in },
        completion: @escaping @MainActor (_ shouldBringBoardToFront: Bool) -> Void = { _ in },
        deferredWindowApplicationCompletion: @escaping @MainActor () -> Void = {},
        minimizeAfterSwitchCompletion: @escaping @MainActor () -> Void = {}
    ) {
        guard let workspace = workspaceStore.workspaces.first(where: { $0.id == workspaceID }) else {
            statusMessage = "Workspace not found."
            return
        }

        if isLoadingWorkspace {
            pendingWorkspaceID = workspaceID
            selectedWorkspaceID = workspaceID
            activeWorkspaceID = workspaceID
            workspaceName = workspace.name
            statusMessage = "Queued \(workspace.name)."
            return
        }

        if !attachedWindows.isEmpty {
            persistActiveWorkspaceSnapshotForSwitch(boardOrigin: boardOrigin)
        }
        selectedWorkspaceID = workspaceID
        workspaceName = workspace.name
        isLoadingWorkspace = true
        statusMessage = "Loading \(workspace.name)..."

        let shouldRestoreSavedOrigin = source == .statusItem || followMode == .none
        let effectiveBoardOrigin = boardOrigin ?? .zero
        let targetLoadedWindowIDs = loadedWindowIDsByWorkspaceID[workspaceID] ?? [:]
        let shouldMinimizeAfterSwitch = defaults.bool(forKey: minimizeUnattachedOnWorkspaceSwitchKey)
        let shouldRestoreMissingWindows = defaults.bool(forKey: restoreMissingWindowsOnWorkspaceSwitchKey)
        let shouldDeferWindowApplication = windowCache != nil
        let plannedAttachedWindows = Self.placeholderAttachedWindows(
            for: workspace.windows,
            boardOrigin: effectiveBoardOrigin,
            useSavedOrigin: shouldRestoreSavedOrigin
        )
        let plannedAttachmentIDs = Set(plannedAttachedWindows.map(\.id))

        attachedWindows = plannedAttachedWindows
        unavailableAttachedWindowIDs = plannedAttachmentIDs
        reconnectingAttachedWindowIDs = plannedAttachmentIDs
        activeWorkspaceID = workspace.id
        selectedWorkspaceID = workspace.id
        loadedWindowIDsByWorkspaceID[workspace.id] = [:]

        Task.detached(priority: .userInitiated) {
            let service = AccessibilityWindowService()
            var availableWindows = windowCache ?? []
            var usedWindowIDs = Set<WindowInfo.ID>()
            var loadedAttachedWindows: [AttachedWindow] = []
            var loadedWindowIDs: [SavedWindowReference.ID: WindowInfo.ID] = [:]
            var unavailableAttachmentIDs = Set<AttachedWindow.ID>()
            var unresolvedReferences: [SavedWindowReference] = []
            var reconnectedCount = 0
            var restoredCount = 0
            var activatedOnlyCount = 0
            var missedCount = 0

            for reference in workspace.windows {
                guard !Task.isCancelled else { return }

                guard let replacement = Self.workspaceWindow(
                    for: reference,
                    cachedWindowID: targetLoadedWindowIDs[reference.id],
                    in: availableWindows,
                    excluding: usedWindowIDs
                ) else {
                    unresolvedReferences.append(reference)
                    continue
                }

                let attached = Self.makeAttachedWindow(
                    replacement,
                    attachmentID: reference.id,
                    reference: reference,
                    boardOrigin: effectiveBoardOrigin,
                    useSavedOrigin: shouldRestoreSavedOrigin,
                    applyImmediately: !shouldDeferWindowApplication,
                    raiseImmediately: false,
                    service: service
                )
                usedWindowIDs.insert(replacement.id)
                loadedWindowIDs[reference.id] = replacement.id
                loadedAttachedWindows.append(attached)
                reconnectedCount += 1
                await MainActor.run {
                    self.applyResolvedWorkspaceAttachment(
                        attached,
                        referenceID: reference.id,
                        workspaceID: workspace.id
                    )
                }
            }

            if windowCache == nil || !unresolvedReferences.isEmpty {
                let listWindowsStart = Date()
                availableWindows = service.listWindows()
                Self.logDuration("workspace listWindows", since: listWindowsStart)
            }

            if !unresolvedReferences.isEmpty {
                var stillUnresolved: [SavedWindowReference] = []

                for reference in unresolvedReferences {
                    guard let replacement = Self.workspaceWindow(
                        for: reference,
                        cachedWindowID: targetLoadedWindowIDs[reference.id],
                        in: availableWindows,
                        excluding: usedWindowIDs
                    ) else {
                        stillUnresolved.append(reference)
                        continue
                    }

                    let attached = Self.makeAttachedWindow(
                        replacement,
                        attachmentID: reference.id,
                        reference: reference,
                        boardOrigin: effectiveBoardOrigin,
                        useSavedOrigin: shouldRestoreSavedOrigin,
                        applyImmediately: !shouldDeferWindowApplication,
                        raiseImmediately: false,
                        service: service
                    )
                    usedWindowIDs.insert(replacement.id)
                    loadedWindowIDs[reference.id] = replacement.id
                    loadedAttachedWindows.append(attached)
                    reconnectedCount += 1
                    await MainActor.run {
                        self.applyResolvedWorkspaceAttachment(
                            attached,
                            referenceID: reference.id,
                            workspaceID: workspace.id
                        )
                    }
                }

                unresolvedReferences = stillUnresolved
            }

            if shouldRestoreMissingWindows, !unresolvedReferences.isEmpty {
                for reference in unresolvedReferences {
                    if reference.canRestoreWindow {
                        if service.openSavedWindowReference(reference) {
                            restoredCount += 1
                        }
                    } else if service.activateSavedApplication(reference) {
                        activatedOnlyCount += 1
                    }
                }

                let attempts = unresolvedReferences.contains(where: \.canRestoreWindow) ? 18 : 10
                for attempt in 0..<attempts {
                    guard !Task.isCancelled, !unresolvedReferences.isEmpty else { break }

                    if attempt > 0 {
                        try? await Task.sleep(for: .milliseconds(120))
                    }

                    if attempt == 8 {
                        for reference in unresolvedReferences {
                            if reference.canRestoreWindow {
                                _ = service.openSavedWindowReference(reference)
                            } else {
                                _ = service.activateSavedApplication(reference)
                            }
                        }
                    }

                    availableWindows = service.listWindows()
                    var stillUnresolved: [SavedWindowReference] = []

                    for reference in unresolvedReferences {
                        guard let replacement = Self.workspaceWindow(
                            for: reference,
                            cachedWindowID: nil,
                            in: availableWindows,
                            excluding: usedWindowIDs
                        ) else {
                            stillUnresolved.append(reference)
                            continue
                        }

                        let attached = Self.makeAttachedWindow(
                            replacement,
                            attachmentID: reference.id,
                            reference: reference,
                            boardOrigin: effectiveBoardOrigin,
                            useSavedOrigin: shouldRestoreSavedOrigin,
                            applyImmediately: !shouldDeferWindowApplication,
                            raiseImmediately: false,
                            service: service
                        )
                        usedWindowIDs.insert(replacement.id)
                        loadedWindowIDs[reference.id] = replacement.id
                        loadedAttachedWindows.append(attached)
                        reconnectedCount += 1
                        await MainActor.run {
                            self.applyResolvedWorkspaceAttachment(
                                attached,
                                referenceID: reference.id,
                                workspaceID: workspace.id
                            )
                        }
                    }

                    unresolvedReferences = stillUnresolved
                }
            }

            for reference in unresolvedReferences {
                let targetOrigin = reference.targetOrigin(
                    from: effectiveBoardOrigin,
                    useSavedOrigin: shouldRestoreSavedOrigin
                )
                let placeholder = placeholderWindowInfo(for: reference)
                let unavailableAttachment = AttachedWindow(
                    attachmentID: reference.id,
                    window: placeholder,
                    savedReference: reference,
                    lastBoardOrigin: effectiveBoardOrigin,
                    lastWindowOrigin: targetOrigin,
                    lastAppliedOrigin: nil,
                    pendingReleaseOrigin: nil
                )
                loadedAttachedWindows.append(unavailableAttachment)
                unavailableAttachmentIDs.insert(unavailableAttachment.id)
                missedCount += 1
            }

            let resolvedAvailableWindows = availableWindows
            let resolvedAttachedWindows = Self.orderedWorkspaceAttachments(
                references: workspace.windows,
                resolvedAttachments: loadedAttachedWindows,
                fallbackAttachments: plannedAttachedWindows
            )
            let resolvedUnavailableAttachmentIDs = unavailableAttachmentIDs
            let resolvedLoadedWindowIDs = loadedWindowIDs
            let resolvedReconnectedCount = reconnectedCount
            let resolvedRestoredCount = restoredCount
            let resolvedActivatedOnlyCount = activatedOnlyCount
            let resolvedMissedCount = missedCount
            var minimizeCandidateWindows = Self.mergeWindows(resolvedAvailableWindows, into: windowCache ?? [])
            var minimizeUnavailableAttachmentIDs = resolvedUnavailableAttachmentIDs

            await MainActor.run {
                self.attachedWindows = resolvedAttachedWindows
                self.unavailableAttachedWindowIDs = resolvedUnavailableAttachmentIDs
                self.reconnectingAttachedWindowIDs.subtract(resolvedLoadedWindowIDs.keys)
                self.isLoadingWorkspace = false
                self.activeWorkspaceID = workspace.id
                self.selectedWorkspaceID = workspace.id
                self.workspaceName = workspace.name
                self.loadedWindowIDsByWorkspaceID[workspace.id] = resolvedLoadedWindowIDs

                self.statusMessage = Self.workspaceLoadStatus(
                    loadedCount: resolvedAttachedWindows.count,
                    reconnectedCount: resolvedReconnectedCount,
                    restoredCount: resolvedRestoredCount,
                    activatedOnlyCount: resolvedActivatedOnlyCount,
                    missedCount: resolvedMissedCount
                )

                mergeWindows(resolvedAvailableWindows)
                completion(source == .mainWindow)

                if let pendingWorkspaceID = self.pendingWorkspaceID,
                   pendingWorkspaceID != workspace.id {
                    self.pendingWorkspaceID = nil
                    self.switchWorkspace(
                        id: pendingWorkspaceID,
                        boardOrigin: boardOrigin,
                        source: source,
                        followMode: followMode,
                        windowCache: windowCache,
                        mergeWindows: mergeWindows,
                        completion: completion,
                        deferredWindowApplicationCompletion: deferredWindowApplicationCompletion,
                        minimizeAfterSwitchCompletion: minimizeAfterSwitchCompletion
                    )
                } else {
                    self.pendingWorkspaceID = nil
                }
            }

            if shouldDeferWindowApplication {
                let applyPositionsStart = Date()
                let applicationResult = Self.applyWorkspaceWindowPositions(resolvedAttachedWindows, service: service)
                Self.logDuration("applyWorkspaceWindowPositions", since: applyPositionsStart)
                var windowsToRaise = applicationResult.appliedWindows
                let failedAttachments = applicationResult.failedAttachments
                if shouldRestoreMissingWindows, !failedAttachments.isEmpty {
                    let recoveryStart = Date()
                    let recoveredAttachments = await Self.recoverDeferredAttachments(
                        failedAttachments,
                        boardOrigin: effectiveBoardOrigin,
                        useSavedOrigin: shouldRestoreSavedOrigin,
                        service: service
                    )
                    Self.logDuration("recoverDeferredAttachments", since: recoveryStart)
                    await MainActor.run {
                        self.applyDeferredRecovery(
                            recoveredAttachments,
                            failedAttachments: failedAttachments,
                            workspaceID: workspace.id
                        )
                    }
                    windowsToRaise.append(contentsOf: recoveredAttachments.values)
                    let unrecoveredAttachmentIDs = Set(failedAttachments.map(\.id))
                        .subtracting(Set(recoveredAttachments.keys))
                    minimizeUnavailableAttachmentIDs.formUnion(unrecoveredAttachmentIDs)
                    minimizeCandidateWindows = Self.mergeWindows(
                        recoveredAttachments.values.map(\.window),
                        into: minimizeCandidateWindows
                    )
                } else if !failedAttachments.isEmpty {
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
                }
            } else {
                if !shouldMinimizeAfterSwitch {
                    Self.raiseWorkspaceWindows(resolvedAttachedWindows, service: service)
                }
            }

            if shouldMinimizeAfterSwitch {
                let attachedWindowsToKeep = resolvedAttachedWindows
                let candidateWindowsToMinimize = minimizeCandidateWindows
                let unavailableAttachmentIDsToProtect = minimizeUnavailableAttachmentIDs
                await MainActor.run {
                    minimizeAfterSwitchCompletion()
                }
                Task.detached(priority: .utility) {
                    let minimizeService = AccessibilityWindowService()
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
        statusMessage = "Preparing unattached windows..."

        Task.detached(priority: .userInitiated) {
            let service = AccessibilityWindowService()
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

                if let replacement = bestReplacementWindow(for: attachedWindow.window, in: candidates) {
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
                    Self.shouldMinimizeWindow($0, attachedSnapshots: attachedSnapshots)
                }

                guard !windowsToMinimize.isEmpty else {
                    self.isMinimizingUnattached = false
                    self.statusMessage = "No unattached windows to minimize."
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

    func restoreMinimizedWindows(mergeWindows: @escaping @MainActor ([WindowInfo]) -> Void = { _ in }) {
        guard !isRestoringMinimized, !minimizedWindows.isEmpty else {
            return
        }

        let windowsToRestore = minimizedWindows
        isRestoringMinimized = true
        statusMessage = "Restoring \(windowsToRestore.count) minimized window(s)..."

        Task.detached(priority: .userInitiated) {
            let service = AccessibilityWindowService()
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
        service: AccessibilityWindowService,
        completion: @escaping @MainActor () -> Void
    ) async {
        let shouldStart = await MainActor.run {
            guard self.activeWorkspaceID == workspaceID,
                  !self.isMinimizingUnattached,
                  !attachedWindows.isEmpty else {
                return false
            }

            self.isMinimizingUnattached = true
            self.statusMessage = "Minimizing unattached windows..."
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
        attachedWindows.removeAll { $0.id == id }
        unavailableAttachedWindowIDs.remove(id)
        reconnectingAttachedWindowIDs.remove(id)
        _ = persistActiveWorkspaceState(boardOrigin: boardOrigin)
        statusMessage = "Detached window."
    }

    func detachAll(boardOrigin: CGPoint?, message: String) {
        attachedWindows.removeAll()
        unavailableAttachedWindowIDs.removeAll()
        reconnectingAttachedWindowIDs.removeAll()
        _ = persistActiveWorkspaceState(boardOrigin: boardOrigin)
        statusMessage = message
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
            } else {
                unavailableAttachedWindowIDs.insert(failedAttachment.id)
                failedCount += 1
            }
        }

        rememberLoadedWindowIDs(for: workspaceID, attachedWindows: attachedWindows)

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
        loadedWindowIDsByWorkspaceID[workspaceID, default: [:]][referenceID] = attachedWindow.window.id
    }

    private func currentWorkspaceReferences(boardOrigin: CGPoint?) -> [SavedWindowReference]? {
        let service = AccessibilityWindowService()
        return attachedWindows.map { attachedWindow in
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

    private func beginMinimizing(
        _ windowsToMinimize: [WindowInfo],
        attachedSnapshots: [SessionAttachedWindowSnapshot],
        mergeWindows: @escaping @MainActor ([WindowInfo]) -> Void,
        removeWindows: @escaping @MainActor (Set<WindowInfo.ID>) -> Void
    ) {
        statusMessage = "Minimizing \(windowsToMinimize.count) unattached window(s)..."

        Task.detached(priority: .userInitiated) {
            let service = AccessibilityWindowService()
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
        service: AccessibilityWindowService
    ) -> AttachedWindow {
        let targetOrigin = reference.targetOrigin(from: boardOrigin, useSavedOrigin: useSavedOrigin)
        let resolvedOrigin: CGPoint
        if applyImmediately {
            do {
                if service.isMinimized(window) {
                    try? service.setMinimized(false, for: window)
                }
                applySavedSizeIfNeeded(reference.savedSize, to: window, service: service)
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

    private static func placeholderAttachedWindows(
        for references: [SavedWindowReference],
        boardOrigin: CGPoint,
        useSavedOrigin: Bool
    ) -> [AttachedWindow] {
        references.map { reference in
            let targetOrigin = reference.targetOrigin(from: boardOrigin, useSavedOrigin: useSavedOrigin)
            return AttachedWindow(
                attachmentID: reference.id,
                window: placeholderWindowInfo(for: reference),
                savedReference: reference,
                lastBoardOrigin: boardOrigin,
                lastWindowOrigin: targetOrigin,
                lastAppliedOrigin: nil,
                pendingReleaseOrigin: nil
            )
        }
    }

    private static func orderedWorkspaceAttachments(
        references: [SavedWindowReference],
        resolvedAttachments: [AttachedWindow],
        fallbackAttachments: [AttachedWindow]
    ) -> [AttachedWindow] {
        let resolvedByID = Dictionary(uniqueKeysWithValues: resolvedAttachments.map { ($0.id, $0) })
        let fallbackByID = Dictionary(uniqueKeysWithValues: fallbackAttachments.map { ($0.id, $0) })

        return references.compactMap { reference in
            resolvedByID[reference.id] ?? fallbackByID[reference.id]
        }
    }

    private static func applyWorkspaceWindowPositions(
        _ attachedWindows: [AttachedWindow],
        service: AccessibilityWindowService
    ) -> SessionWindowApplicationResult {
        var appliedWindows: [AttachedWindow] = []
        var failedAttachments: [AttachedWindow] = []

        for attachedWindow in attachedWindows where attachedWindow.window.pid != 0 {
            do {
                if service.isMinimized(attachedWindow.window) {
                    try? service.setMinimized(false, for: attachedWindow.window)
                }
                applySavedSizeIfNeeded(
                    attachedWindow.savedReference?.savedSize,
                    to: attachedWindow.window,
                    service: service
                )
                let currentOrigin = try? service.position(of: attachedWindow.window)
                if let currentOrigin, originsMatch(currentOrigin, attachedWindow.lastWindowOrigin) {
                    appliedWindows.append(attachedWindow)
                    continue
                }

                try service.setPosition(attachedWindow.lastWindowOrigin, for: attachedWindow.window)
                appliedWindows.append(attachedWindow)
            } catch {
                failedAttachments.append(attachedWindow)
            }
        }

        return SessionWindowApplicationResult(
            appliedWindows: appliedWindows,
            failedAttachments: failedAttachments
        )
    }

    private static func raiseWorkspaceWindows(
        _ attachedWindows: [AttachedWindow],
        service: AccessibilityWindowService
    ) {
        for attachedWindow in attachedWindows where attachedWindow.window.pid != 0 {
            service.raise(attachedWindow.window)
        }
    }

    private static func applySavedSizeIfNeeded(
        _ savedSize: CGSize?,
        to window: WindowInfo,
        service: AccessibilityWindowService
    ) {
        guard let savedSize, savedSize.width > 40, savedSize.height > 40 else {
            return
        }

        let currentSize = try? service.size(of: window)
        if let currentSize, sizesMatch(currentSize, savedSize) {
            return
        }

        try? service.setSize(savedSize, for: window)
    }

    private static func recoverDeferredAttachments(
        _ failedAttachments: [AttachedWindow],
        boardOrigin: CGPoint,
        useSavedOrigin: Bool,
        service: AccessibilityWindowService
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
                guard let replacement = workspaceWindow(
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

    private static func workspaceWindow(
        for reference: SavedWindowReference,
        cachedWindowID: WindowInfo.ID?,
        in candidates: [WindowInfo],
        excluding usedWindowIDs: Set<WindowInfo.ID>
    ) -> WindowInfo? {
        if let cachedWindowID,
           !usedWindowIDs.contains(cachedWindowID),
           let exactWindow = candidates.first(where: { $0.id == cachedWindowID }) {
            return exactWindow
        }

        return bestSavedWorkspaceWindow(
            for: reference,
            in: candidates,
            excluding: usedWindowIDs
        )
    }

    private static func minimizeUnattachedWindows(
        keeping attachedWindows: [AttachedWindow],
        candidateWindows: [WindowInfo],
        unavailableAttachmentIDs: Set<AttachedWindow.ID>,
        service: AccessibilityWindowService
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
            shouldMinimizeWindow($0, attachedSnapshots: snapshots)
        }
        return minimizeWindows(windowsToMinimize, attachedSnapshots: snapshots, service: service)
    }

    private static func minimizeWindows(
        _ windowsToMinimize: [WindowInfo],
        attachedSnapshots: [SessionAttachedWindowSnapshot],
        service: AccessibilityWindowService
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

    private static func logDuration(_ operation: String, since startDate: Date) {
        #if DEBUG
        let elapsedMilliseconds = Date().timeIntervalSince(startDate) * 1_000
        workspaceSessionLogger.debug("\(operation, privacy: .public) took \(elapsedMilliseconds, format: .fixed(precision: 1), privacy: .public) ms")
        #endif
    }
}
