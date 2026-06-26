import AppKit
import Combine
import Foundation

private struct StatusAttachedWindowSnapshot {
    let windowID: WindowInfo.ID
    let appName: String
    let title: String
    let pid: pid_t
    let bundleIdentifier: String?
    let documentURL: URL?
    let windowNumber: CGWindowID?
    let origin: CGPoint
    let window: WindowInfo
    let protectsSameApplicationFromMinimize: Bool
}

private struct StatusMinimizeWindowsResult {
    let minimizedWindows: [WindowInfo]
    let restoredAttachedWindows: [WindowInfo]
    let failedCount: Int
}

enum WindowBoardStatusCommand {
    case showWindow
    case loadWorkspace(SavedWorkspace.ID)
    case loadWorkspaceFromStatusItem(SavedWorkspace.ID)
    case bringAttachedToFront
    case minimizeUnattached
    case restoreMinimized
}

final class WindowBoardAppState: ObservableObject {
    let workspaceStore = WorkspaceStore()
    let commandSubject = PassthroughSubject<WindowBoardStatusCommand, Never>()
    weak var mainWindow: NSWindow?

    @Published var followModeRawValue: String {
        didSet {
            defaults.set(followModeRawValue, forKey: "followMode")
            followMode = FollowMode(rawValue: followModeRawValue) ?? .none
        }
    }
    @Published var positionUpdateModeRawValue: String {
        didSet {
            defaults.set(positionUpdateModeRawValue, forKey: "positionUpdateMode")
            positionUpdateMode = PositionUpdateMode(rawValue: positionUpdateModeRawValue) ?? .manual
        }
    }
    @Published var autoFrontModeRawValue: String {
        didSet {
            defaults.set(autoFrontModeRawValue, forKey: "autoFrontMode")
            autoFrontMode = AutoFrontMode(rawValue: autoFrontModeRawValue) ?? .off
        }
    }
    @Published var boardClickActionRawValue: String {
        didSet {
            defaults.set(boardClickActionRawValue, forKey: "boardClickAction")
            boardClickAction = BoardClickAction(rawValue: boardClickActionRawValue) ?? .none
        }
    }

    @Published private(set) var followMode: FollowMode
    @Published private(set) var positionUpdateMode: PositionUpdateMode
    @Published private(set) var autoFrontMode: AutoFrontMode
    @Published private(set) var boardClickAction: BoardClickAction

    @Published var activeWorkspaceID: SavedWorkspace.ID? {
        didSet {
            if let activeWorkspaceID {
                defaults.set(activeWorkspaceID.uuidString, forKey: "activeWorkspaceID")
            } else {
                defaults.removeObject(forKey: "activeWorkspaceID")
            }
        }
    }
    @Published var hasAttachedWindows = false
    @Published var hasMinimizedWindows = false
    @Published var isMinimizingUnattached = false
    @Published var isRestoringMinimized = false
    @Published var isLoadingWorkspaceFromStatusItem = false
    @Published var statusItemMessage = "Ready"

    private var loadedWindowIDsByWorkspaceID: [SavedWorkspace.ID: [SavedWindowReference.ID: WindowInfo.ID]] = [:]
    private var pendingStatusWorkspaceID: SavedWorkspace.ID?
    private var statusItemMinimizedWindows: [WindowInfo] = []
    private let defaults: UserDefaults
    private let minimizeUnattachedOnWorkspaceSwitchKey = "minimizeUnattachedOnWorkspaceSwitch"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let storedFollowModeRawValue = defaults.string(forKey: "followMode") ?? FollowMode.none.rawValue
        let storedPositionUpdateModeRawValue = defaults.string(forKey: "positionUpdateMode") ?? PositionUpdateMode.manual.rawValue
        let storedAutoFrontModeRawValue = defaults.string(forKey: "autoFrontMode") ?? AutoFrontMode.off.rawValue
        let storedBoardClickActionRawValue = defaults.string(forKey: "boardClickAction") ?? BoardClickAction.none.rawValue
        let storedActiveWorkspaceID = defaults.string(forKey: "activeWorkspaceID").flatMap(UUID.init(uuidString:))

        followModeRawValue = storedFollowModeRawValue
        positionUpdateModeRawValue = storedPositionUpdateModeRawValue
        autoFrontModeRawValue = storedAutoFrontModeRawValue
        boardClickActionRawValue = storedBoardClickActionRawValue
        followMode = FollowMode(rawValue: storedFollowModeRawValue) ?? .none
        positionUpdateMode = PositionUpdateMode(rawValue: storedPositionUpdateModeRawValue) ?? .manual
        autoFrontMode = AutoFrontMode(rawValue: storedAutoFrontModeRawValue) ?? .off
        boardClickAction = BoardClickAction(rawValue: storedBoardClickActionRawValue) ?? .none
        activeWorkspaceID = storedActiveWorkspaceID

        if let activeWorkspaceID,
           !workspaceStore.workspaces.contains(where: { $0.id == activeWorkspaceID }) {
            self.activeWorkspaceID = nil
        }
    }

    var canBringAttachedToFront: Bool {
        hasAttachedWindows
    }

    var canMinimizeUnattached: Bool {
        hasAttachedWindows && !isMinimizingUnattached && !isRestoringMinimized
    }

    var canRestoreMinimized: Bool {
        hasMinimizedWindows && !isMinimizingUnattached && !isRestoringMinimized
    }

    var hasVisibleMainWindow: Bool {
        mainWindow?.isVisible == true || existingMainWindow?.isVisible == true
    }

    var hasMainWindow: Bool {
        mainWindow != nil || existingMainWindow != nil
    }

    func send(_ command: WindowBoardStatusCommand) {
        commandSubject.send(command)
    }

    func loadWorkspaceFromStatusItem(id workspaceID: SavedWorkspace.ID) {
        guard let workspace = workspaceStore.workspaces.first(where: { $0.id == workspaceID }) else {
            statusItemMessage = "Workspace not found"
            return
        }

        statusItemMessage = "Switching to \(workspace.name)..."
        loadWorkspaceWithoutBoard(id: workspaceID)
    }

    func loadWorkspaceWithoutBoard(id workspaceID: SavedWorkspace.ID) {
        guard let workspace = workspaceStore.workspaces.first(where: { $0.id == workspaceID }) else {
            statusItemMessage = "Workspace not found"
            return
        }

        if isLoadingWorkspaceFromStatusItem {
            pendingStatusWorkspaceID = workspaceID
            activeWorkspaceID = workspaceID
            statusItemMessage = "Queued \(workspace.name)"
            return
        }

        let previousWorkspaceID = activeWorkspaceID
        isLoadingWorkspaceFromStatusItem = true
        activeWorkspaceID = workspace.id

        Task.detached(priority: .userInitiated) {
            let service = AccessibilityWindowService()
            if let previousWorkspaceID {
                let previousLoadedWindowIDs = await MainActor.run {
                    self.loadedWindowIDsByWorkspaceID[previousWorkspaceID] ?? [:]
                }
                let previousWorkspace = await MainActor.run {
                    self.workspaceStore.workspaces.first(where: { $0.id == previousWorkspaceID })
                }
                let updatedReferences = previousWorkspace.map {
                    Self.updatedWorkspaceWindowOriginsWithoutBoard(
                        workspace: $0,
                        loadedWindowIDs: previousLoadedWindowIDs,
                        service: service
                    )
                }
                if let updatedReferences {
                    await MainActor.run {
                        _ = self.workspaceStore.updateWorkspace(id: previousWorkspaceID, windows: updatedReferences)
                    }
                }
            }

            guard let workspaceToLoad = await MainActor.run(body: {
                self.workspaceStore.workspaces.first(where: { $0.id == workspaceID })
            }) else {
                await MainActor.run {
                    self.statusItemMessage = "Workspace not found"
                    self.finishStatusWorkspaceLoad()
                }
                return
            }

            let targetLoadedWindowIDs = await MainActor.run {
                self.loadedWindowIDsByWorkspaceID[workspaceID] ?? [:]
            }
            var availableWindows = service.listWindows()
            var usedWindowIDs = Set<WindowInfo.ID>()
            var loadedWindowIDs: [SavedWindowReference.ID: WindowInfo.ID] = [:]
            var loadedWindows: [WindowInfo] = []
            var loadedCount = 0
            var unresolvedReferences: [SavedWindowReference] = []

            for reference in workspaceToLoad.windows {
                if Task.isCancelled {
                    return
                }

                guard let replacement = Self.workspaceWindow(
                    for: reference,
                    cachedWindowID: targetLoadedWindowIDs[reference.id],
                    in: availableWindows,
                    excluding: usedWindowIDs
                ) else {
                    unresolvedReferences.append(reference)
                    continue
                }

                Self.applyLoadedWorkspaceWindow(replacement, reference: reference, service: service)
                usedWindowIDs.insert(replacement.id)
                loadedWindowIDs[reference.id] = replacement.id
                loadedWindows.append(replacement)
                loadedCount += 1
            }

            if !unresolvedReferences.isEmpty {
                for reference in unresolvedReferences {
                    if reference.canRestoreWindow {
                        _ = service.openSavedWindowReference(reference)
                    } else {
                        _ = service.activateSavedApplication(reference)
                    }
                }

                let attempts = unresolvedReferences.contains(where: \.canRestoreWindow) ? 18 : 10
                for attempt in 0..<attempts {
                    if Task.isCancelled || unresolvedReferences.isEmpty {
                        break
                    }

                    if attempt > 0 {
                        try? await Task.sleep(for: .milliseconds(120))
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

                        Self.applyLoadedWorkspaceWindow(replacement, reference: reference, service: service)
                        usedWindowIDs.insert(replacement.id)
                        loadedWindowIDs[reference.id] = replacement.id
                        loadedWindows.append(replacement)
                        loadedCount += 1
                    }

                    unresolvedReferences = stillUnresolved
                }

                if !unresolvedReferences.isEmpty {
                    let unresolvedCount = unresolvedReferences.count
                    await MainActor.run {
                        self.statusItemMessage = "Still reconnecting \(unresolvedCount) window(s)"
                    }
                }
            }

            let minimizeResult = await MainActor.run {
                self.shouldMinimizeUnattachedOnWorkspaceSwitch
            }
                ? Self.minimizeUnattachedWindows(keeping: loadedWindows, service: service)
                : nil

            let resolvedLoadedWindowIDs = loadedWindowIDs
            let resolvedLoadedCount = loadedCount
            await MainActor.run {
                self.activeWorkspaceID = workspaceToLoad.id
                self.loadedWindowIDsByWorkspaceID[workspaceToLoad.id] = resolvedLoadedWindowIDs
                if let minimizeResult {
                    self.statusItemMinimizedWindows.append(contentsOf: minimizeResult.minimizedWindows)
                    self.hasMinimizedWindows = !self.statusItemMinimizedWindows.isEmpty
                }
                self.statusItemMessage = self.statusItemLoadMessage(
                    workspaceName: workspaceToLoad.name,
                    loadedCount: resolvedLoadedCount,
                    totalCount: workspaceToLoad.windows.count,
                    minimizedCount: minimizeResult?.minimizedWindows.count
                )
                self.finishStatusWorkspaceLoad(completedWorkspaceID: workspaceToLoad.id)
            }
        }
    }

    func minimizeUnattachedFromStatusItem() {
        let activeWindows = activeWorkspaceID.flatMap { workspaceID in
            loadedWindowIDsByWorkspaceID[workspaceID]
        }

        statusItemMessage = "Minimizing unattached windows..."
        isMinimizingUnattached = true

        Task.detached(priority: .userInitiated) {
            let service = AccessibilityWindowService()
            let availableWindows = service.listWindows()
            let protectedWindows = activeWindows.map { loadedWindowIDs in
                availableWindows.filter { loadedWindowIDs.values.contains($0.id) }
            } ?? []
            let result = Self.minimizeUnattachedWindows(keeping: protectedWindows, service: service)

            await MainActor.run {
                self.isMinimizingUnattached = false
                self.statusItemMinimizedWindows.append(contentsOf: result.minimizedWindows)
                self.hasMinimizedWindows = !self.statusItemMinimizedWindows.isEmpty
                self.statusItemMessage = "Minimized \(result.minimizedWindows.count) unattached window(s)"
            }
        }
    }

    func restoreMinimizedFromStatusItem() {
        guard !statusItemMinimizedWindows.isEmpty else {
            statusItemMessage = "No minimized windows to restore"
            hasMinimizedWindows = false
            return
        }

        let windowsToRestore = statusItemMinimizedWindows
        statusItemMessage = "Restoring minimized windows..."
        isRestoringMinimized = true

        Task.detached(priority: .userInitiated) {
            let service = AccessibilityWindowService()
            var failedWindows: [WindowInfo] = []
            var restoredCount = 0

            for window in windowsToRestore {
                do {
                    try service.setMinimized(false, for: window)
                    restoredCount += 1
                } catch {
                    failedWindows.append(window)
                }
            }

            let resolvedFailedWindows = failedWindows
            let resolvedRestoredCount = restoredCount
            await MainActor.run {
                self.isRestoringMinimized = false
                self.statusItemMinimizedWindows = resolvedFailedWindows
                self.hasMinimizedWindows = !resolvedFailedWindows.isEmpty
                self.statusItemMessage = "Restored \(resolvedRestoredCount) minimized window(s)"
            }
        }
    }

    private func finishStatusWorkspaceLoad(completedWorkspaceID: SavedWorkspace.ID? = nil) {
        isLoadingWorkspaceFromStatusItem = false

        guard let pendingStatusWorkspaceID else {
            return
        }

        self.pendingStatusWorkspaceID = nil
        if pendingStatusWorkspaceID != completedWorkspaceID {
            loadWorkspaceWithoutBoard(id: pendingStatusWorkspaceID)
        }
    }

    @discardableResult
    func focusMainWindowIfAvailable() -> Bool {
        NSApp.activate(ignoringOtherApps: true)

        if let mainWindow {
            mainWindow.makeKeyAndOrderFront(nil)
            return true
        }

        if let window = existingMainWindow {
            mainWindow = window
            window.makeKeyAndOrderFront(nil)
            return true
        }

        return false
    }

    private var existingMainWindow: NSWindow? {
        NSApp.windows.first { window in
            window.title == "Window Board"
        }
    }

    private var shouldMinimizeUnattachedOnWorkspaceSwitch: Bool {
        defaults.bool(forKey: minimizeUnattachedOnWorkspaceSwitchKey)
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

    private func statusItemLoadMessage(
        workspaceName: String,
        loadedCount: Int,
        totalCount: Int,
        minimizedCount: Int?
    ) -> String {
        var message = "Loaded \(workspaceName) (\(loadedCount)/\(totalCount))"
        if let minimizedCount {
            message += ", minimized \(minimizedCount)"
        }
        return message
    }

    private static func minimizeUnattachedWindows(
        keeping protectedWindows: [WindowInfo],
        service: AccessibilityWindowService
    ) -> StatusMinimizeWindowsResult {
        guard !protectedWindows.isEmpty else {
            return StatusMinimizeWindowsResult(minimizedWindows: [], restoredAttachedWindows: [], failedCount: 0)
        }

        let protectedSnapshots = statusAttachedWindowSnapshots(for: protectedWindows)
        let windowsToMinimize = service.listWindows().filter {
            shouldMinimizeWindow($0, protectedSnapshots: protectedSnapshots)
        }
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

        for snapshot in protectedSnapshots {
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

        return StatusMinimizeWindowsResult(
            minimizedWindows: minimizedWindows,
            restoredAttachedWindows: restoredAttachedWindows,
            failedCount: failedCount
        )
    }

    private static func statusAttachedWindowSnapshots(for windows: [WindowInfo]) -> [StatusAttachedWindowSnapshot] {
        windows.map { window in
            StatusAttachedWindowSnapshot(
                windowID: window.id,
                appName: window.appName,
                title: window.title,
                pid: window.pid,
                bundleIdentifier: window.bundleIdentifier,
                documentURL: window.documentURL,
                windowNumber: window.windowNumber,
                origin: window.position ?? .zero,
                window: window,
                protectsSameApplicationFromMinimize: shouldProtectSameApplicationFromMinimize(window)
            )
        }
    }

    private static func shouldMinimizeWindow(
        _ window: WindowInfo,
        protectedSnapshots: [StatusAttachedWindowSnapshot]
    ) -> Bool {
        guard !isProtectedWindow(window, protectedSnapshots: protectedSnapshots) else {
            return false
        }

        return !isAmbiguousSameAppWindow(window, protectedSnapshots: protectedSnapshots)
    }

    private static func isProtectedWindow(
        _ window: WindowInfo,
        protectedSnapshots: [StatusAttachedWindowSnapshot]
    ) -> Bool {
        for snapshot in protectedSnapshots {
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
        protectedSnapshots: [StatusAttachedWindowSnapshot]
    ) -> Bool {
        protectedSnapshots.contains { snapshot in
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

    private static func isSameApplication(_ window: WindowInfo, snapshot: StatusAttachedWindowSnapshot) -> Bool {
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

    private static func bestWorkspaceWindow(
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

        return bestWorkspaceWindow(
            for: reference,
            in: candidates,
            excluding: usedWindowIDs
        )
    }

    private static func applyLoadedWorkspaceWindow(
        _ window: WindowInfo,
        reference: SavedWindowReference,
        service: AccessibilityWindowService
    ) {
        let targetOrigin = reference.savedOrigin ?? window.position
        if let targetOrigin {
            try? service.setPosition(targetOrigin, for: window)
        }
        service.raise(window)
    }

    private static func updatedWorkspaceWindowOriginsWithoutBoard(
        workspace: SavedWorkspace,
        loadedWindowIDs: [SavedWindowReference.ID: WindowInfo.ID],
        service: AccessibilityWindowService
    ) -> [SavedWindowReference] {
        let availableWindows = service.listWindows()
        var usedWindowIDs = Set<WindowInfo.ID>()
        return workspace.windows.map { reference in
            var updatedReference = reference

            let exactWindow = loadedWindowIDs[reference.id].flatMap { loadedWindowID in
                availableWindows.first { $0.id == loadedWindowID }
            }
            let window = exactWindow ?? bestWorkspaceWindow(
                for: reference,
                in: availableWindows,
                excluding: usedWindowIDs
            )

            guard let window else {
                return updatedReference
            }

            usedWindowIDs.insert(window.id)

            let origin = window.position ?? (try? service.position(of: window))
            if let origin {
                updatedReference.originX = origin.x
                updatedReference.originY = origin.y
            }

            return updatedReference
        }
    }
}
