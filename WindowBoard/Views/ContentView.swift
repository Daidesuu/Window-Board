import AppKit
import ApplicationServices
import OSLog
import SwiftUI

#if DEBUG
private let contentEnergyLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "WindowBoard",
    category: "Energy"
)
#endif

private enum AttachedWindowInsertion {
    case start
    case end
}

private func raiseAttachedWindowsOffMainThread(
    _ windows: [AttachedWindow],
    activationSettleNanoseconds: UInt64,
    windowSettleNanoseconds: UInt64,
    serviceFactory: @Sendable () -> any ContentWindowOperating
) async {
    let service = serviceFactory()

    for attachedWindow in windows {
        if Task.isCancelled {
            return
        }

        service.activateApplication(for: attachedWindow.window)
        waitForFrontmostApplicationOffMainThread(pid: attachedWindow.window.pid, timeout: 0.5)

        if Task.isCancelled {
            return
        }

        try? await Task.sleep(nanoseconds: activationSettleNanoseconds)
        service.focusWindow(attachedWindow.window)
        service.raiseWindowOnly(attachedWindow.window)
        try? await Task.sleep(nanoseconds: windowSettleNanoseconds)
    }
}

private func waitForFrontmostApplicationOffMainThread(pid: pid_t, timeout: TimeInterval) {
    let deadline = Date().addingTimeInterval(timeout)

    while Date() < deadline {
        if Task.isCancelled {
            return
        }

        if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid {
            return
        }

        Thread.sleep(forTimeInterval: 0.02)
    }
}

private final class BoardMotionState: ObservableObject {
    var currentOrigin: CGPoint?
}

struct ContentView: View {
    private static let baselineRefreshInterval: Duration = .seconds(3)
    private static let baselineIdleDelay: TimeInterval = 3.0
    private static let applicationRefreshDebounce: Duration = .milliseconds(180)

    nonisolated private let windowServiceFactory: @Sendable () -> any ContentWindowOperating
    private let service: any ContentWindowOperating
    private let windowCatalog: ApplicationWindowCatalog
    private let recoveryCoordinator: AttachedWindowRecoveryCoordinator
    private let moveScheduler = WindowMoveScheduler.shared
    @ObservedObject private var appState: WindowBoardAppState
    @ObservedObject private var workspaceStore: WorkspaceStore
    @ObservedObject private var session: WorkspaceSessionController

    @StateObject private var boardMotion = BoardMotionState()
    @State private var followCoordinator: BoardFollowCoordinator
    @State private var frontingCoordinator: BoardFrontingCoordinator
    @State private var snapshotCoordinator: AttachedWindowSnapshotCoordinator
    @State private var isTrusted = false
    @State private var windows: [WindowInfo] = []
    @State private var selectedWindowID: WindowInfo.ID?
    @State private var boardWindow: NSWindow?
    @State private var isLoadingWindows = false
    @AppStorage("boardAlwaysOnTop") private var isBoardAlwaysOnTop = false
    @AppStorage("minimizeUnattachedOnWorkspaceSwitch") private var shouldMinimizeUnattachedOnWorkspaceSwitch = false
    @AppStorage("restoreMissingWindowsOnWorkspaceSwitch") private var shouldRestoreMissingWindowsOnWorkspaceSwitch = false
    @State private var lastExternalApplication: NSRunningApplication?
    @State private var attachedWindowFailureCounts: [AttachedWindow.ID: Int] = [:]
    @State private var recoveryIssueByAttachmentID: [AttachedWindow.ID: AttachedWindowRecoveryIssue] = [:]
    @State private var recoveryRevisionByAttachmentID: [AttachedWindow.ID: Int] = [:]
    @State private var activePositionReadIDs: Set<AttachedWindow.ID> = []
    @State private var minimizedAttachedWindowIDs: Set<AttachedWindow.ID> = []
    @State private var workspaceStatusTextInput = ""
    @State private var isWorkspaceSettingsPresented = false
    @State private var recentlyAddedAttachedWindowID: AttachedWindow.ID?
    @State private var recentlyAddedNeverMinimizeWindowID: NeverMinimizeWindow.ID?
    @State private var workspaceCardTransitionToken: UUID?
    @State private var detachingAttachedWindowIDs: Set<AttachedWindow.ID> = []
    @State private var detachingNeverMinimizeWindowIDs: Set<NeverMinimizeWindow.ID> = []
    @State private var detachAnimationTasks: [AttachedWindow.ID: Task<Void, Never>] = [:]
    @State private var permanentDetachAnimationTasks: [NeverMinimizeWindow.ID: Task<Void, Never>] = [:]
    @State private var applicationWindowRefreshTasksByPID: [pid_t: Task<Void, Never>] = [:]

    init(
        appState: WindowBoardAppState,
        windowServiceFactory: @escaping @Sendable () -> any ContentWindowOperating = { AccessibilityWindowService() }
    ) {
        self.windowServiceFactory = windowServiceFactory
        service = windowServiceFactory()
        windowCatalog = ApplicationWindowCatalog(serviceFactory: windowServiceFactory)
        recoveryCoordinator = AttachedWindowRecoveryCoordinator(serviceFactory: windowServiceFactory)
        _followCoordinator = State(initialValue: BoardFollowCoordinator())
        _frontingCoordinator = State(initialValue: BoardFrontingCoordinator())
        _snapshotCoordinator = State(
            initialValue: AttachedWindowSnapshotCoordinator(serviceFactory: windowServiceFactory)
        )
        _appState = ObservedObject(initialValue: appState)
        _workspaceStore = ObservedObject(initialValue: appState.workspaceStore)
        _session = ObservedObject(initialValue: appState.session)
    }

    var body: some View {
        Group {
            if isTrusted {
                NavigationSplitView {
                    workspaceSidebar
                        .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 300)
                } detail: {
                    workspaceDetail
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                permissionRoot
            }
        }
        .background(
            ZStack {
                BoardClickObserver(onClick: handleBoardSelected)
                BoardWindowObserver(
                    onWindowAvailable: { window in
                        boardWindow = window
                        appState.mainWindow = window
                        boardMotion.currentOrigin = window.frame.origin
                        configureBoardWindowTransparency(window)
                        applyBoardWindowLevel(to: window)
                        loadActiveWorkspaceFromAppStateIfNeeded()
                    },
                    onOriginChanged: handleBoardOriginChanged
                )
                .frame(width: 0, height: 0)
            }
        )
        .toolbar {
            toolbarContent
        }
        .onAppear {
            refreshTrustAndWindows()
            syncStatusMenuState()
            restartAttachedWindowSnapshotTask()
        }
        .onDisappear {
            stopAttachedWindowSnapshotTask()
            cancelEnergyTasks()
        }
        .onReceive(appState.commandSubject) { command in
            handleStatusCommand(command)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshTrustAndWindows()
            scheduleBoardSelectedAction()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)) { notification in
            rememberActivatedApplication(from: notification)
            refreshWindowsForApplication(from: notification, retry: true)
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)) { notification in
            refreshWindowsForApplication(from: notification, retry: true)
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)) { notification in
            removeWindowsForApplication(from: notification)
        }
        .onChange(of: appState.followMode) { _, _ in
            resetAttachedBoardBaselineToCurrentOrigin()
        }
        .onChange(of: session.selectedWorkspaceID) { _, _ in
            session.workspaceName = selectedWorkspace?.name ?? ""
            workspaceStatusTextInput = WorkspaceStatusItemIcon.title(from: selectedWorkspace?.statusItemSymbolName) ?? ""
            loadSelectedWorkspaceIfNeeded()
        }
        .onChange(of: session.attachedWindows.count) { _, _ in
            syncStatusMenuState()
            restartAttachedWindowSnapshotTask()
        }
        .onChange(of: session.minimizedWindows.count) { _, _ in
            syncStatusMenuState()
        }
        .onChange(of: session.isLoadingWorkspace) { _, _ in
            syncStatusMenuState()
            updateAttachedWindowSnapshotTaskForActivity()
        }
        .onChange(of: session.isApplyingWorkspaceWindows) { _, _ in
            updateAttachedWindowSnapshotTaskForActivity()
        }
        .onChange(of: session.isMinimizingUnattached) { _, _ in
            syncStatusMenuState()
            updateAttachedWindowSnapshotTaskForActivity()
        }
        .onChange(of: session.isRestoringMinimized) { _, _ in
            syncStatusMenuState()
            updateAttachedWindowSnapshotTaskForActivity()
        }
        .onChange(of: isBoardAlwaysOnTop) { _, _ in
            applyBoardWindowLevel()
            session.statusMessage = isBoardAlwaysOnTop
                ? "Window Board will stay above normal windows."
                : "Window Board uses normal window level."
        }
        .task {
            while !Task.isCancelled {
                let interval: Duration = isTrusted ? .seconds(10) : .seconds(1)
                try? await Task.sleep(for: interval)
                refreshTrustAndWindows()
            }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.baselineRefreshInterval)
                refreshAttachedWindowBaselineIfIdle()
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
            BoardToolbarControls(
                state: BoardToolbarState(
                    boardTitle: selectedWorkspace?.name ?? "Window Board",
                    isTrusted: isTrusted,
                    hasSelectedBoard: selectedWorkspace != nil,
                    canAttachFrontmost: boardWindow != nil,
                    hasAttachedWindows: !session.attachedWindows.isEmpty,
                    hasMinimizedWindows: !session.minimizedWindows.isEmpty,
                    hasRecoverableWindows: hasRecoverableAttachedWindows,
                    isMinimizing: session.isMinimizingUnattached,
                    isRestoring: session.isRestoringMinimized,
                    hasKnownWindows: !windows.isEmpty,
                    isLoadingWindows: isLoadingWindows,
                    canRestoreLayout: canReloadSelectedWorkspace
                ),
                actions: BoardToolbarActions(
                    createBoard: createWorkspace,
                    attachFrontmost: attachFrontmostWindow,
                    focusBoard: { bringAllAttachedWindowsToFront() },
                    recoverMissing: recoverMissingAttachedWindows,
                    minimizeOthers: minimizeUnattachedWindows,
                    restoreWindows: restoreMinimizedWindows,
                    refreshWindowList: refreshWindowsAsync,
                    restoreLayout: loadSelectedWorkspace,
                    removeAllWindows: detachAllFromMainView
                ),
                isSettingsPresented: $isWorkspaceSettingsPresented
            ) {
                WorkspaceSettingsControls(
                    selectedWorkspace: selectedWorkspace,
                    workspaceName: $session.workspaceName,
                    workspaceStatusText: $workspaceStatusTextInput,
                    minimizeUnattachedOnSwitch: $shouldMinimizeUnattachedOnWorkspaceSwitch,
                    restoreMissingWindowsOnSwitch: $shouldRestoreMissingWindowsOnWorkspaceSwitch,
                    boardAlwaysOnTop: $isBoardAlwaysOnTop,
                    canSaveWorkspace: !session.attachedWindows.isEmpty && boardMotion.currentOrigin != nil,
                    canOverwriteWorkspace: selectedWorkspace != nil && !session.attachedWindows.isEmpty && boardMotion.currentOrigin != nil,
                    canEditWorkspaceName: selectedWorkspace?.isDefault != true,
                    canRenameWorkspace: selectedWorkspace != nil && selectedWorkspace?.isDefault != true && !trimmedWorkspaceName.isEmpty,
                    canDeleteWorkspace: selectedWorkspace != nil && selectedWorkspace?.isDefault != true && !session.isLoadingWorkspace,
                    canDetachAll: !session.attachedWindows.isEmpty,
                    saveWorkspace: saveCurrentWorkspace,
                    overwriteWorkspace: overwriteSelectedWorkspace,
                    renameWorkspace: renameSelectedWorkspace,
                    deleteWorkspace: deleteSelectedWorkspace,
                    updateStatusItemIcon: updateSelectedWorkspaceIcon,
                    updateStatusItemText: updateSelectedWorkspaceStatusText,
                    detachAll: detachAllFromMainView
                )
                .padding(18)
                .frame(width: 420)
            }
    }

    private var workspaceSidebar: some View {
        WorkspaceSidebarView(
            workspaces: workspaceStore.workspaces,
            activeWorkspaceID: session.activeWorkspaceID,
            showBoardSettings: showBoardSettingsFromSidebar,
            restoreBoardLayout: restoreBoardLayoutFromSidebar,
            removeBoardWindows: removeBoardWindowsFromSidebar,
            deleteBoard: deleteBoardFromSidebar,
            selection: $session.selectedWorkspaceID
        )
    }

    private var workspaceDetail: some View {
        WorkspaceDetailView(
            attachedWindows: session.attachedWindows,
            isLoadingWorkspace: session.isLoadingWorkspace,
            isMinimizingUnattached: session.isMinimizingUnattached,
            isRestoringMinimized: session.isRestoringMinimized,
            canAttachFrontmost: boardWindow != nil,
            attachedState: attachedDisplayState(for:),
            recoveryIssue: { recoveryIssueByAttachmentID[$0] },
            actions: WorkspaceDetailActions(
                attachFromAddCard: attachFrontmostWindowFromAddCard,
                clearRecentlyAddedWindowID: { recentlyAddedAttachedWindowID = nil },
                recoverAttached: recoverAttachedWindow,
                useFrontWindowForAttached: useFrontWindowForAttached,
                updateAttached: updateAttachedPositionFromMainView(id:),
                detachAttached: detachWindowFromMainView(id:),
                bringForwardAttached: { bringAttachedWindowToFrontFromMainView($0) },
                bringAndMoveAttachedBelowCard: bringAndMoveAttachedWindowBelowCard(_:cursorScreenLocation:),
                addNeverMinimizeWindow: addNeverMinimizeWindow(_:),
                moveAttachedWindowToPermanentBoard: moveAttachedWindowToPermanentBoard(id:),
                rejectPermanentBoardDrop: rejectPermanentBoardDrop,
                movePermanentWindowToMainBoard: movePermanentWindowToMainBoard(id:),
                rejectMainBoardDrop: rejectMainBoardDrop,
                addNeverMinimizeRunningWindow: addNeverMinimizeWindow(_:),
                removeNeverMinimizeWindow: removeNeverMinimizeWindowFromCard(id:),
                clearRecentlyAddedNeverMinimizeWindowID: { recentlyAddedNeverMinimizeWindowID = nil },
                showNeverMinimizeWindow: showNeverMinimizeWindow(_:),
                showAndMoveNeverMinimizeWindowBelowCard: bringAndMovePermanentWindowBelowCard(_:cursorScreenLocation:)
            ),
            recentlyAddedWindowID: recentlyAddedAttachedWindowID,
            workspaceTransitionToken: workspaceCardTransitionToken,
            detachingAttachedWindowIDs: detachingAttachedWindowIDs,
            isNeverMinimizedWindow: { appState.isNeverMinimized(window: $0) },
            neverMinimizeWindows: appState.neverMinimizeWindows,
            runningNeverMinimizeWindowCandidates: runningNeverMinimizeWindowCandidates,
            recentlyAddedNeverMinimizeWindowID: recentlyAddedNeverMinimizeWindowID,
            detachingNeverMinimizeWindowIDs: detachingNeverMinimizeWindowIDs,
            liveNeverMinimizeWindow: liveNeverMinimizeWindow(for:)
        )
    }

    private var runningNeverMinimizeWindowCandidates: [WindowInfo] {
        windows
            .filter { window in
                !appState.isNeverMinimized(window: window)
            }
            .sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
    }

    private var recoverableAttachedWindows: [AttachedWindow] {
        session.attachedWindows.filter { attachedWindow in
            let state = attachedDisplayState(for: attachedWindow)
            return state.needsAttention && state != .reconnecting && state.recoveryActionTitle != nil
        }
    }

    private var hasRecoverableAttachedWindows: Bool {
        !recoverableAttachedWindows.isEmpty
    }

    private var canReloadSelectedWorkspace: Bool {
        selectedWorkspace != nil && !session.isLoadingWorkspace && boardWindow != nil
    }

    private func recoverMissingAttachedWindows() {
        for attachedWindow in recoverableAttachedWindows {
            recoverAttachedWindow(attachedWindow)
        }
    }

    private func selectWorkspaceForSidebarAction(_ workspace: SavedWorkspace) {
        session.selectedWorkspaceID = workspace.id
        session.workspaceName = workspace.name
        workspaceStatusTextInput = WorkspaceStatusItemIcon.title(from: workspace.statusItemSymbolName) ?? ""
    }

    private func showBoardSettingsFromSidebar(_ workspace: SavedWorkspace) {
        selectWorkspaceForSidebarAction(workspace)
        isWorkspaceSettingsPresented = true
    }

    private func restoreBoardLayoutFromSidebar(_ workspace: SavedWorkspace) {
        selectWorkspaceForSidebarAction(workspace)
        guard boardWindow != nil, !session.isLoadingWorkspace else {
            return
        }

        loadWorkspace(id: workspace.id)
    }

    private func removeBoardWindowsFromSidebar(_ workspace: SavedWorkspace) {
        if workspace.id == session.activeWorkspaceID {
            selectWorkspaceForSidebarAction(workspace)
            detachAllFromMainView()
            return
        }

        _ = workspaceStore.updateWorkspace(id: workspace.id, windows: [])
        selectWorkspaceForSidebarAction(workspace)
        session.statusMessage = "Removed all windows from \(workspace.name)."
    }

    private func deleteBoardFromSidebar(_ workspace: SavedWorkspace) {
        selectWorkspaceForSidebarAction(workspace)
        deleteSelectedWorkspace()
    }

    private func detachAllFromMainView() {
        cancelDetachAnimations()
        detachAll(message: "Detached all windows.")
    }

    private func bringAttachedWindowToFrontFromMainView(_ attachedWindow: AttachedWindow) {
        guard !isUnavailable(attachedWindow.id) else {
            session.statusMessage = "\(attachedWindow.window.appName) is not available."
            return
        }

        bringAttachedWindowsToFrontSmoothly([attachedWindow], updateStatus: true)
    }

    private func addNeverMinimizeWindow(_ window: WindowInfo) {
        let existingIDs = Set(appState.neverMinimizeWindows.map(\.id))
        withAnimation(.spring(response: 0.32, dampingFraction: 0.88, blendDuration: 0.06)) {
            appState.addNeverMinimizeWindow(window)
        }
        recentlyAddedNeverMinimizeWindowID = appState.neverMinimizeWindows.first {
            !existingIDs.contains($0.id) && $0.matches(window)
        }?.id
        session.statusMessage = "Window added to Permanent Board."
    }

    private func removeNeverMinimizeWindow(id: NeverMinimizeWindow.ID) {
        permanentDetachAnimationTasks[id]?.cancel()
        permanentDetachAnimationTasks[id] = nil
        detachingNeverMinimizeWindowIDs.remove(id)
        withAnimation(.spring(response: 0.24, dampingFraction: 0.86, blendDuration: 0.04)) {
            appState.removeNeverMinimizeWindow(id: id)
        }
        session.statusMessage = "Window removed from Permanent Board."
    }

    private func removeNeverMinimizeWindowFromCard(id: NeverMinimizeWindow.ID) {
        scheduleNeverMinimizeWindowRemoval(id: id, finalStatus: "Window removed from Permanent Board.")
    }

    private func scheduleNeverMinimizeWindowRemoval(id: NeverMinimizeWindow.ID, finalStatus: String) {
        guard appState.neverMinimizeWindows.contains(where: { $0.id == id }),
              !detachingNeverMinimizeWindowIDs.contains(id) else {
            return
        }

        permanentDetachAnimationTasks[id]?.cancel()
        detachingNeverMinimizeWindowIDs.insert(id)

        permanentDetachAnimationTasks[id] = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(260))
            guard !Task.isCancelled else {
                return
            }

            removeNeverMinimizeWindow(id: id)
            session.statusMessage = finalStatus
            permanentDetachAnimationTasks[id] = nil
        }
    }

    private func moveAttachedWindowToPermanentBoard(id: AttachedWindow.ID) {
        guard let attachedWindow = session.attachedWindows.first(where: { $0.id == id }) else {
            session.statusMessage = "That card is no longer on the Main Board."
            return
        }

        guard attachedDisplayState(for: attachedWindow) == .available,
              attachedWindow.window.pid != 0 else {
            session.statusMessage = "Only available windows can be moved to Permanent Board."
            return
        }

        if !appState.isNeverMinimized(window: attachedWindow.window) {
            let existingIDs = Set(appState.neverMinimizeWindows.map(\.id))
            withAnimation(.spring(response: 0.32, dampingFraction: 0.88, blendDuration: 0.06)) {
                appState.addNeverMinimizeWindow(attachedWindow.window)
            }
            recentlyAddedNeverMinimizeWindowID = appState.neverMinimizeWindows.first {
                !existingIDs.contains($0.id) && $0.matches(attachedWindow.window)
            }?.id
        }

        detachWindowFromMainView(id: id)
        session.statusMessage = "Moved window to Permanent Board."
    }

    private func rejectPermanentBoardDrop() {
        session.statusMessage = "That card cannot be moved to Permanent Board."
    }

    private func movePermanentWindowToMainBoard(id: NeverMinimizeWindow.ID) {
        guard let permanentWindow = appState.neverMinimizeWindows.first(where: { $0.id == id }) else {
            session.statusMessage = "That card is no longer on the Permanent Board."
            return
        }

        guard let window = liveNeverMinimizeWindow(for: permanentWindow) else {
            session.statusMessage = "Only available permanent windows can be moved to Main Board."
            return
        }

        guard let boardOrigin = boardMotion.currentOrigin else {
            session.statusMessage = "Window Board position is not available."
            return
        }

        guard attachWindow(
            window,
            boardOrigin: boardOrigin,
            insertion: .end,
            markRecentlyAdded: true,
            bringToFrontAfterAttach: false
        ) else {
            return
        }

        scheduleNeverMinimizeWindowRemoval(id: id, finalStatus: "Moved window to Main Board.")
        session.statusMessage = "Moved window to Main Board."
    }

    private func rejectMainBoardDrop() {
        session.statusMessage = "That card cannot be moved to Main Board."
    }

    private func liveNeverMinimizeWindow(for window: NeverMinimizeWindow) -> WindowInfo? {
        windows.first { window.matches($0) }
    }

    private func showNeverMinimizeWindow(_ window: WindowInfo) {
        session.statusMessage = "Bringing \(window.displayName) to front..."
        let service = service

        Task.detached(priority: .utility) {
            service.raise(window)

            await MainActor.run {
                session.statusMessage = "Brought \(window.displayName) to front."
            }
        }
    }

    private func bringAndMoveAttachedWindowBelowCard(_ attachedWindow: AttachedWindow, cursorScreenLocation: CGPoint) {
        guard attachedDisplayState(for: attachedWindow) == .available else {
            session.statusMessage = "\(attachedWindow.window.appName) is not available to move."
            return
        }

        bringAndMoveWindowBelowCursor(attachedWindow.window, cursorScreenLocation: cursorScreenLocation)
    }

    private func bringAndMovePermanentWindowBelowCard(_ window: WindowInfo, cursorScreenLocation: CGPoint) {
        bringAndMoveWindowBelowCursor(window, cursorScreenLocation: cursorScreenLocation)
    }

    private func bringAndMoveWindowBelowCursor(_ window: WindowInfo, cursorScreenLocation: CGPoint) {
        session.statusMessage = "Moving \(window.displayName) below cursor..."
        let service = service
        let displayName = window.displayName

        Task.detached(priority: .utility) {
            do {
                service.raise(window)
                let windowSize = try? service.size(of: window)
                let targetOrigin = await MainActor.run {
                    Self.targetWindowOriginBelowCursor(
                        cursorScreenLocation: cursorScreenLocation,
                        windowSize: windowSize
                    )
                }
                try service.setPosition(targetOrigin, for: window)

                await MainActor.run {
                    session.statusMessage = "Moved \(displayName) below cursor."
                }
            } catch {
                await MainActor.run {
                    session.statusMessage = "Window could not be moved."
                }
            }
        }
    }

    private static func targetWindowOriginBelowCursor(cursorScreenLocation: CGPoint, windowSize: CGSize?) -> CGPoint {
        guard let screen = screen(containing: cursorScreenLocation) else {
            return CGPoint(x: cursorScreenLocation.x, y: cursorScreenLocation.y + 12)
        }

        let cursorAXY = screen.frame.maxY - cursorScreenLocation.y
        var targetOrigin = CGPoint(
            x: cursorScreenLocation.x,
            y: cursorAXY + 64
        )

        guard let windowSize,
              windowSize.width > 0,
              windowSize.height > 0 else {
            return targetOrigin
        }

        targetOrigin.x = cursorScreenLocation.x - (windowSize.width / 2)

        let visibleAXFrame = axFrame(forAppKitScreenFrame: screen.visibleFrame, on: screen)
        targetOrigin.x = clamped(
            targetOrigin.x,
            min: visibleAXFrame.minX,
            max: max(visibleAXFrame.minX, visibleAXFrame.maxX - windowSize.width)
        )
        targetOrigin.y = max(targetOrigin.y, visibleAXFrame.minY)
        return targetOrigin
    }

    private static func screen(containing point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
    }

    private static func axFrame(forAppKitScreenFrame rect: CGRect, on screen: NSScreen) -> CGRect {
        let minY = screen.frame.maxY - rect.maxY
        let maxY = screen.frame.maxY - rect.minY
        return CGRect(x: rect.minX, y: minY, width: rect.width, height: maxY - minY)
    }

    private static func clamped(_ value: CGFloat, min minimum: CGFloat, max maximum: CGFloat) -> CGFloat {
        Swift.min(Swift.max(value, minimum), maximum)
    }

    private func updateAttachedPositionFromMainView(id: AttachedWindow.ID) {
        updateAttachedPosition(for: id)
    }

    private func detachWindowFromMainView(id: AttachedWindow.ID) {
        detachWindowFromCard(id: id)
    }

    private func detachWindowFromCard(id: AttachedWindow.ID) {
        guard session.attachedWindows.contains(where: { $0.id == id }),
              !detachingAttachedWindowIDs.contains(id) else {
            return
        }

        detachAnimationTasks[id]?.cancel()
        detachingAttachedWindowIDs.insert(id)

        detachAnimationTasks[id] = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(260))
            guard !Task.isCancelled else {
                return
            }

            detachWindow(id: id)
            detachingAttachedWindowIDs.remove(id)
            detachAnimationTasks[id] = nil
        }
    }

    private func cancelDetachAnimations() {
        for task in detachAnimationTasks.values {
            task.cancel()
        }
        detachAnimationTasks.removeAll()
        detachingAttachedWindowIDs.removeAll()
    }

    private func updateAttachedPositionsFromMainView() {
        updateAttachedPosition()
    }

    private func bringAllAttachedWindowsToFrontFromMainView() {
        bringAllAttachedWindowsToFront()
    }

    private var permissionRoot: some View {
        Form {
            Section {
                permissionView
            }
        }
        .formStyle(.grouped)
        .padding(24)
        .frame(maxWidth: 640, maxHeight: .infinity, alignment: .topLeading)
    }

    private var permissionView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Accessibility permission is required.", systemImage: "hand.raised")
                .font(.headline)

            Text("Window Board needs Accessibility access to read and move other app windows.")
                .foregroundStyle(.secondary)

            HStack {
                Button("Request Permission") {
                    service.requestAccessPrompt()
                    refreshTrustAndWindows()
                }

                Button("Open System Settings") {
                    service.openAccessibilitySettings()
                }

                Button("Recheck") {
                    refreshTrustAndWindows()
                }
            }
        }
    }

    private func attachedDisplayState(for attachedWindow: AttachedWindow) -> AttachedWindowDisplayState {
        if session.isLoadingWorkspace {
            return .resolving
        }

        if isReconnecting(attachedWindow.id) {
            return .reconnecting
        }

        if isUnavailable(attachedWindow.id) {
            return .unavailable
        }

        if isMinimized(attachedWindow.id) {
            return .minimized
        }

        return .available
    }

    private var selectedWindow: WindowInfo? {
        guard let selectedWindowID else {
            return nil
        }
        return windows.first { $0.id == selectedWindowID }
    }

    private var selectedWorkspace: SavedWorkspace? {
        guard let selectedWorkspaceID = session.selectedWorkspaceID else {
            return nil
        }
        return workspaceStore.workspaces.first { $0.id == selectedWorkspaceID }
    }

    private var trimmedWorkspaceName: String {
        session.workspaceName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var followMode: FollowMode {
        appState.followMode
    }

    private var positionUpdateMode: PositionUpdateMode {
        appState.positionUpdateMode
    }

    private var autoFrontMode: AutoFrontMode {
        appState.autoFrontMode
    }

    private var boardClickAction: BoardClickAction {
        appState.boardClickAction
    }

    private func handleStatusCommand(_ command: WindowBoardStatusCommand) {
        switch command {
        case .showWindow:
            bringBoardWindowToFront()

        case let .loadWorkspace(workspaceID):
            bringBoardWindowToFront()
            loadWorkspace(id: workspaceID)

        case .bringAttachedToFront:
            bringAllAttachedWindowsToFront()

        case .minimizeUnattached:
            minimizeUnattachedWindows()

        case .restoreMinimized:
            restoreMinimizedWindows()
        }
    }

    private func syncStatusMenuState() {
        if let activeWorkspaceID = session.activeWorkspaceID {
            session.rememberLoadedWindowIDs(for: activeWorkspaceID, attachedWindows: session.attachedWindows)
        }
    }

    private func loadActiveWorkspaceFromAppStateIfNeeded() {
        guard let appActiveWorkspaceID = appState.session.activeWorkspaceID,
              !session.isLoadingWorkspace,
              boardWindow != nil else {
            return
        }

        let savedWorkspace = workspaceStore.workspaces.first { $0.id == appActiveWorkspaceID }
        let shouldLoadActiveWorkspace = appActiveWorkspaceID != session.activeWorkspaceID
            || (session.attachedWindows.isEmpty && savedWorkspace?.windows.isEmpty == false)

        guard shouldLoadActiveWorkspace else {
            return
        }

        loadWorkspace(
            id: appActiveWorkspaceID,
            restoreSavedOrigin: true,
            shouldBringBoardToFrontAfterLoad: false
        )
    }

    private func refreshTrustAndWindows() {
        let trusted = service.isTrusted()
        let didBecomeTrusted = trusted && !isTrusted
        isTrusted = trusted

        if didBecomeTrusted || (trusted && windows.isEmpty && !isLoadingWindows) {
            refreshWindowsAsync()
        }
    }

    private func refreshWindowsAsync() {
        guard !isLoadingWindows else {
            return
        }

        isLoadingWindows = true
        session.statusMessage = "Loading windows..."

        Task.detached(priority: .userInitiated) {
            let loadedWindows = windowCatalog.allWindows()

            await MainActor.run {
                windows = loadedWindows
                isLoadingWindows = false

                if let selectedWindowID, !loadedWindows.contains(where: { $0.id == selectedWindowID }) {
                    self.selectedWindowID = nil
                }

                session.statusMessage = loadedWindows.isEmpty
                    ? "No attachable windows found."
                    : "Select a window to attach it to the board."
            }
        }
    }

    private func refreshWindowsForApplication(from notification: Notification, retry: Bool) {
        guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
            return
        }

        refreshWindows(for: application, retry: retry)
    }

    private func refreshWindows(for application: NSRunningApplication, retry: Bool = false) {
        guard application.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return
        }

        guard shouldRefreshWindows(for: application) else {
            return
        }

        let pid = application.processIdentifier
        applicationWindowRefreshTasksByPID[pid]?.cancel()
        applicationWindowRefreshTasksByPID[pid] = Task {
            if retry {
                try? await Task.sleep(for: Self.applicationRefreshDebounce)
            }

            guard !Task.isCancelled else {
                applicationWindowRefreshTasksByPID[pid] = nil
                return
            }

            let appWindows = await Task.detached(priority: .utility) {
                let attempts = retry ? 3 : 1
                let appWindows = await windowCatalog.windows(
                    for: application,
                    attempts: attempts,
                    retryDelay: .milliseconds(120)
                )

                #if DEBUG
                contentEnergyLogger.debug(
                    "application window refresh pid=\(pid, privacy: .public) attempts=\(attempts, privacy: .public) windows=\(appWindows.count, privacy: .public)"
                )
                #endif

                return appWindows
            }.value

            guard !Task.isCancelled else {
                applicationWindowRefreshTasksByPID[pid] = nil
                return
            }

            mergeWindows(appWindows, replacingApplication: application)
            applicationWindowRefreshTasksByPID[pid] = nil
        }
    }

    private func shouldRefreshWindows(for application: NSRunningApplication) -> Bool {
        if windows.isEmpty {
            return true
        }

        let pid = application.processIdentifier
        if windows.contains(where: { $0.pid == pid }) {
            return true
        }

        if session.attachedWindows.contains(where: { attachedWindow in
            if attachedWindow.window.pid == pid {
                return true
            }

            guard let applicationBundleIdentifier = application.bundleIdentifier else {
                return false
            }

            return attachedWindow.window.bundleIdentifier == applicationBundleIdentifier
        }) {
            return true
        }

        if appState.neverMinimizeWindows.contains(where: { permanentWindow in
            if let applicationBundleIdentifier = application.bundleIdentifier,
               permanentWindow.bundleIdentifier == applicationBundleIdentifier {
                return true
            }

            return permanentWindow.appName == application.localizedName
        }) {
            return true
        }

        return false
    }

    private func removeWindowsForApplication(from notification: Notification) {
        guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
            return
        }

        removeCachedWindows(for: application)
    }

    private func attachSelectedWindow() {
        guard let selectedWindow, let boardOrigin = boardMotion.currentOrigin else {
            return
        }

        cancelScheduledBoardSelectedAction()
        attachWindow(selectedWindow, boardOrigin: boardOrigin)
    }

    private func attachFrontmostWindow() {
        cancelScheduledBoardSelectedAction()

        guard let boardOrigin = boardMotion.currentOrigin else {
            session.statusMessage = "Activate another app window first."
            return
        }

        guard let frontmostWindow = attachableFrontmostWindow() else {
            session.statusMessage = "No attachable frontmost window found."
            return
        }

        attachWindow(frontmostWindow, boardOrigin: boardOrigin)
    }

    private func attachFrontmostWindowFromAddCard() {
        cancelScheduledBoardSelectedAction()

        guard let boardOrigin = boardMotion.currentOrigin else {
            recentlyAddedAttachedWindowID = nil
            session.statusMessage = "Activate another app window first."
            return
        }

        guard let frontmostWindow = attachableFrontmostWindow() else {
            recentlyAddedAttachedWindowID = nil
            session.statusMessage = "No attachable frontmost window found."
            return
        }

        attachWindow(
            frontmostWindow,
            boardOrigin: boardOrigin,
            insertion: .end,
            markRecentlyAdded: true
        )
    }

    private func attachableFrontmostWindow() -> WindowInfo? {
        if let visibleFrontWindow = service.frontmostVisibleExternalWindow() {
            return visibleFrontWindow
        }

        guard let lastExternalApplication else {
            return nil
        }

        return service.frontmostWindow(for: lastExternalApplication)
    }

    @discardableResult
    private func attachWindow(
        _ window: WindowInfo,
        boardOrigin: CGPoint,
        insertion: AttachedWindowInsertion = .start,
        markRecentlyAdded: Bool = false,
        bringToFrontAfterAttach: Bool = true
    ) -> Bool {
        do {
            let targetOrigin = try service.position(of: window)
            let attachedWindow = AttachedWindow(
                window: window,
                lastBoardOrigin: boardOrigin,
                lastWindowOrigin: targetOrigin,
                lastAppliedOrigin: targetOrigin,
                pendingReleaseOrigin: nil
            )
            let matchingAttachedWindowIDs = Set<AttachedWindow.ID>(session.attachedWindows.compactMap { attachedWindow in
                guard !detachingAttachedWindowIDs.contains(attachedWindow.id),
                      isSameAttachedWindow(attachedWindow.window, as: window) else {
                    return nil
                }

                return attachedWindow.id
            })
            let wasAlreadyAttached = !matchingAttachedWindowIDs.isEmpty
            session.attachedWindows.removeAll {
                matchingAttachedWindowIDs.contains($0.id)
            }
            clearAttachedWindowAccessFailure(for: attachedWindow.id)
            recoveryIssueByAttachmentID.removeValue(forKey: attachedWindow.id)
            markAttachedWindowAvailable(attachedWindow.id)
            switch insertion {
            case .start:
                session.attachedWindows.insert(attachedWindow, at: session.attachedWindows.startIndex)
            case .end:
                session.attachedWindows.append(attachedWindow)
            }
            if markRecentlyAdded {
                recentlyAddedAttachedWindowID = attachedWindow.id
            }
            _ = session.persistActiveWorkspaceState(boardOrigin: boardOrigin)
            session.statusMessage = wasAlreadyAttached
                ? "Already attached. Updated \(window.displayName)."
                : "Attached \(window.displayName)."
            if bringToFrontAfterAttach {
                bringAllAttachedWindowsToFront(updateStatus: false)
            }
            return true
        } catch {
            if markRecentlyAdded {
                recentlyAddedAttachedWindowID = nil
            }
            session.statusMessage = "Could not attach selected window. \(error.localizedDescription)"
            return false
        }
    }

    private func saveCurrentWorkspace() {
        session.saveCurrentWorkspace(name: session.workspaceName, boardOrigin: boardMotion.currentOrigin)
    }

    private func createWorkspace() {
        session.createWorkspace(boardOrigin: boardMotion.currentOrigin)
        attachedWindowFailureCounts.removeAll()
        recoveryIssueByAttachmentID.removeAll()
        recoveryRevisionByAttachmentID.removeAll()
        activePositionReadIDs.removeAll()
        minimizedAttachedWindowIDs.removeAll()
        workspaceStatusTextInput = ""
        followCoordinator.cancelAll()
    }

    private func overwriteSelectedWorkspace() {
        session.overwriteSelectedWorkspace(name: session.workspaceName, boardOrigin: boardMotion.currentOrigin)
    }

    private func renameSelectedWorkspace() {
        session.renameSelectedWorkspace(name: session.workspaceName)
    }

    private func updateSelectedWorkspaceIcon(_ symbolName: String) {
        guard let selectedWorkspaceID = session.selectedWorkspaceID else {
            return
        }

        let resolvedSymbolName = symbolName == WorkspaceStatusItemIcon.defaultSymbolName ? nil : symbolName
        _ = workspaceStore.updateWorkspaceIcon(id: selectedWorkspaceID, statusItemSymbolName: resolvedSymbolName)
        workspaceStatusTextInput = WorkspaceStatusItemIcon.title(from: resolvedSymbolName) ?? ""
    }

    private func updateSelectedWorkspaceStatusText() {
        guard let selectedWorkspaceID = session.selectedWorkspaceID else {
            return
        }

        let trimmedText = workspaceStatusTextInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            _ = workspaceStore.updateWorkspaceIcon(id: selectedWorkspaceID, statusItemSymbolName: nil)
            workspaceStatusTextInput = ""
            return
        }

        let statusText = String(trimmedText.prefix(8))
        workspaceStatusTextInput = statusText
        _ = workspaceStore.updateWorkspaceIcon(
            id: selectedWorkspaceID,
            statusItemSymbolName: WorkspaceStatusItemIcon.textPrefix + statusText
        )
    }

    private func loadSelectedWorkspaceIfNeeded() {
        guard let selectedWorkspaceID = session.selectedWorkspaceID,
              selectedWorkspaceID != session.activeWorkspaceID,
              !session.isLoadingWorkspace,
              boardWindow != nil else {
            return
        }

        loadSelectedWorkspace()
    }

    private func loadWorkspace(
        id workspaceID: SavedWorkspace.ID,
        restoreSavedOrigin: Bool = false,
        shouldBringBoardToFrontAfterLoad: Bool = true
    ) {
        let shouldTemporarilyFrontBoard = autoFrontMode == .off && shouldBringBoardToFrontAfterLoad
        let usesDeferredWindowApplication = true
        let workspaceFrontingToken = shouldTemporarilyFrontBoard
            ? beginTemporaryBoardWorkspaceFronting()
            : nil
        recentlyAddedAttachedWindowID = nil
        cancelDetachAnimations()
        session.switchWorkspace(
            id: workspaceID,
            boardOrigin: boardMotion.currentOrigin,
            source: .mainWindow,
            followMode: restoreSavedOrigin ? .none : followMode,
            windowCache: windows,
            mergeWindows: { loadedWindows in
                windows = mergeWindows(loadedWindows, into: windows)
            },
            completion: { shouldBringBoardToFront in
                attachedWindowFailureCounts.removeAll()
                recoveryIssueByAttachmentID.removeAll()
                recoveryRevisionByAttachmentID.removeAll()
                activePositionReadIDs.removeAll()
                followCoordinator.cancelRelease()
                if autoFrontMode == .off {
                    if shouldBringBoardToFrontAfterLoad && shouldBringBoardToFront {
                        bringBoardWindowToFront()
                    }
                } else if !shouldMinimizeUnattachedOnWorkspaceSwitch {
                    bringAllAttachedWindowsToFront(updateStatus: false)
                }

                if !usesDeferredWindowApplication, let workspaceFrontingToken {
                    endTemporaryBoardWorkspaceFronting(token: workspaceFrontingToken)
                }
            },
            deferredWindowApplicationCompletion: {
                guard autoFrontMode == .off,
                      shouldBringBoardToFrontAfterLoad,
                      let workspaceFrontingToken else {
                    return
                }

                bringBoardWindowToFront()
                endTemporaryBoardWorkspaceFronting(token: workspaceFrontingToken)
            },
            minimizeAfterSwitchCompletion: {
                guard shouldMinimizeUnattachedOnWorkspaceSwitch,
                      shouldBringBoardToFrontAfterLoad else {
                    return
                }

                bringBoardWindowToFront()
            }
        )
        let transitionToken = UUID()
        workspaceCardTransitionToken = transitionToken
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(900))
            if workspaceCardTransitionToken == transitionToken {
                workspaceCardTransitionToken = nil
            }
        }
    }

    private func loadSelectedWorkspace() {
        guard let workspaceID = session.selectedWorkspaceID,
              boardMotion.currentOrigin != nil,
              !session.isLoadingWorkspace else {
            return
        }

        loadWorkspace(id: workspaceID)
    }

    private func deleteSelectedWorkspace() {
        session.deleteSelectedWorkspace()
    }

    private func rememberActivatedApplication(from notification: Notification) {
        guard frontingCoordinator.shouldAcceptExternalActivation() else {
            return
        }

        guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return
        }

        lastExternalApplication = application
    }

    private func handleBoardOriginChanged(_ origin: CGPoint) {
        boardMotion.currentOrigin = origin
        followCoordinator.recordMovement(
            to: origin,
            mode: followMode,
            hasAttachedWindows: !session.attachedWindows.isEmpty,
            currentMode: { followMode },
            applySmoothMove: { boardOrigin in
                applyBoardFollowMovement(to: boardOrigin, style: .immediate)
            },
            applyReleaseMove: { boardOrigin, style in
                applyBoardFollowMovement(to: boardOrigin, style: style)
            }
        )
    }

    private func applyBoardFollowMovement(to boardOrigin: CGPoint, style: BoardFollowMoveStyle) {
        let updates = BoardFollowPlanner.updates(
            for: boardOrigin,
            attachedWindows: session.attachedWindows,
            unavailableAttachmentIDs: session.unavailableAttachedWindowIDs
        )

        for update in updates {
            guard let index = session.attachedWindows.firstIndex(where: { $0.id == update.attachmentID }) else {
                continue
            }

            session.attachedWindows[index].lastBoardOrigin = update.boardOrigin
            guard let targetOrigin = update.targetOrigin else { continue }

            let window = session.attachedWindows[index].window
            session.attachedWindows[index].lastWindowOrigin = targetOrigin
            session.attachedWindows[index].lastAppliedOrigin = targetOrigin

            switch style {
            case .immediate:
                moveAttachedWindow(window, attachmentID: update.attachmentID, to: targetOrigin)
            case .animated:
                animateAttachedWindow(window, attachmentID: update.attachmentID, to: targetOrigin)
            }
        }
    }

    private func moveAttachedWindow(_ window: WindowInfo, attachmentID: AttachedWindow.ID, to position: CGPoint) {
        moveScheduler.scheduleMove(
            window: window,
            to: position,
            onComplete: {
                clearAttachedWindowAccessFailure(for: attachmentID)
                markAutoFrontPendingIfNeeded()
            }
        ) { error in
            handleAttachedWindowAccessFailure(for: attachmentID, error: error)
        }
    }

    private func animateAttachedWindow(_ window: WindowInfo, attachmentID: AttachedWindow.ID, to position: CGPoint) {
        moveScheduler.scheduleAnimatedMove(
            window: window,
            to: position,
            onComplete: {
                clearAttachedWindowAccessFailure(for: attachmentID)
                markAutoFrontPendingIfNeeded()
            }
        ) { error in
            handleAttachedWindowAccessFailure(for: attachmentID, error: error)
        }
    }

    private func markAutoFrontPendingIfNeeded() {
        followCoordinator.markAutoFrontPending(
            mode: autoFrontMode,
            currentMode: { autoFrontMode },
            hasAttachedWindows: { !session.attachedWindows.isEmpty },
            applyAutoFront: { bringAllAttachedWindowsToFront(updateStatus: false) }
        )
    }

    private func refreshAttachedWindowBaselineIfIdle() {
        guard followCoordinator.isIdle(for: Self.baselineIdleDelay),
              !session.attachedWindows.isEmpty else {
            return
        }

        guard positionUpdateMode == .automatic else {
            return
        }

        #if DEBUG
        contentEnergyLogger.debug("automatic baseline refresh attached=\(session.attachedWindows.count, privacy: .public)")
        #endif

        updateAttachedPosition(showStatus: false)
    }

    private func resetAttachedBoardBaselineToCurrentOrigin() {
        followCoordinator.cancelRelease()

        guard let boardOrigin = boardMotion.currentOrigin else {
            return
        }

        for index in session.attachedWindows.indices {
            session.attachedWindows[index].lastBoardOrigin = boardOrigin
            session.attachedWindows[index].pendingReleaseOrigin = nil
        }
    }

    private func updateAttachedPosition(showStatus: Bool = true) {
        let attachedWindowIDs = session.attachedWindows.map(\.id)
        for id in attachedWindowIDs {
            updateAttachedPosition(for: id, showStatus: showStatus)
        }
    }

    private func updateAttachedPosition(for id: AttachedWindow.ID, showStatus: Bool = true) {
        guard let boardOrigin = boardMotion.currentOrigin,
              let attachedWindow = session.attachedWindows.first(where: { $0.id == id }),
              !activePositionReadIDs.contains(id) else {
            return
        }

        let sampledWindowID = attachedWindow.window.id
        activePositionReadIDs.insert(id)

        Task.detached(priority: .utility) {
            let result = Result {
                try windowServiceFactory().position(of: attachedWindow.window)
            }

            await MainActor.run {
                activePositionReadIDs.remove(id)

                guard let index = session.attachedWindows.firstIndex(where: { $0.id == id }) else {
                    return
                }

                guard session.attachedWindows[index].window.id == sampledWindowID else {
                    return
                }

                guard !isReconnecting(id) else {
                    return
                }

                switch result {
                case let .success(currentWindowOrigin):
                    session.attachedWindows[index].lastBoardOrigin = boardOrigin
                    session.attachedWindows[index].lastWindowOrigin = currentWindowOrigin
                    session.attachedWindows[index].lastAppliedOrigin = currentWindowOrigin
                    session.attachedWindows[index].pendingReleaseOrigin = nil
                    clearAttachedWindowAccessFailure(for: id)
                    markAttachedWindowAvailable(id)
                    if showStatus {
                        session.statusMessage = "Updated position for \(attachedWindow.window.displayName)."
                    }
                case let .failure(error):
                    handleAttachedWindowAccessFailure(for: id, error: error)
                }
            }
        }
    }

    private func restartAttachedWindowSnapshotTask() {
        snapshotCoordinator.restart(
            activity: snapshotActivity,
            requestProvider: {
                guard !session.attachedWindows.isEmpty else {
                    return nil
                }

                return AttachedWindowSnapshotBatch(
                    workspaceID: session.activeWorkspaceID,
                    requests: session.attachedWindows.map {
                        AttachedWindowSnapshotRequest(attachmentID: $0.id, window: $0.window)
                    }
                )
            },
            consume: { result in
                applyAttachedWindowSnapshots(result)
            }
        )
    }

    private func stopAttachedWindowSnapshotTask() {
        snapshotCoordinator.stop()
    }

    private func cancelEnergyTasks() {
        followCoordinator.cancelTasksForDisappearance()
        frontingCoordinator.cancelTasksForDisappearance()
        applicationWindowRefreshTasksByPID.values.forEach { $0.cancel() }
        applicationWindowRefreshTasksByPID.removeAll()
    }

    private func updateAttachedWindowSnapshotTaskForActivity() {
        if session.isLoadingWorkspace ||
            session.isApplyingWorkspaceWindows ||
            session.isMinimizingUnattached ||
            session.isRestoringMinimized {
            stopAttachedWindowSnapshotTask()
        } else {
            restartAttachedWindowSnapshotTask()
        }
    }

    private var snapshotActivity: AttachedWindowSnapshotCoordinator.Activity {
        AttachedWindowSnapshotCoordinator.Activity(
            hasAttachments: !session.attachedWindows.isEmpty,
            isLoadingWorkspace: session.isLoadingWorkspace,
            isApplyingWorkspaceWindows: session.isApplyingWorkspaceWindows,
            isMinimizingUnattached: session.isMinimizingUnattached,
            isRestoringMinimized: session.isRestoringMinimized
        )
    }

    private func applyAttachedWindowSnapshots(_ result: AttachedWindowSnapshotBatchResult) {
        guard result.workspaceID == session.activeWorkspaceID else {
            return
        }

        #if DEBUG
        contentEnergyLogger.debug("attached snapshot windows=\(result.snapshots.count, privacy: .public)")
        #endif

        var didChange = false

        for snapshot in result.snapshots {
            guard let index = session.attachedWindows.firstIndex(where: { $0.id == snapshot.attachmentID }) else {
                continue
            }

            guard session.attachedWindows[index].window.id == snapshot.windowID else {
                continue
            }

            guard !isReconnecting(snapshot.attachmentID) else {
                continue
            }

            if let title = snapshot.title,
               title != session.attachedWindows[index].window.title {
                session.attachedWindows[index].window = session.attachedWindows[index].window.updatingTitle(title)
                didChange = true
            }

            if snapshot.isMinimized {
                minimizedAttachedWindowIDs.insert(snapshot.attachmentID)
                clearAttachedWindowAccessFailure(for: snapshot.attachmentID)
                markAttachedWindowAvailable(snapshot.attachmentID)
                continue
            } else {
                minimizedAttachedWindowIDs.remove(snapshot.attachmentID)
            }

            if let origin = snapshot.origin {
                if !originsMatch(session.attachedWindows[index].lastWindowOrigin, origin) {
                    session.attachedWindows[index].lastWindowOrigin = origin
                    session.attachedWindows[index].lastAppliedOrigin = origin
                    session.attachedWindows[index].pendingReleaseOrigin = nil
                    didChange = true
                }
                clearAttachedWindowAccessFailure(for: snapshot.attachmentID)
                markAttachedWindowAvailable(snapshot.attachmentID)
            } else {
                if session.attachedWindows[index].window.pid == 0 {
                    session.unavailableAttachedWindowIDs.insert(snapshot.attachmentID)
                    didChange = true
                    continue
                }

                let failureCount = (attachedWindowFailureCounts[snapshot.attachmentID] ?? 0) + 1
                attachedWindowFailureCounts[snapshot.attachmentID] = failureCount
                if failureCount >= 3, !isUnavailable(snapshot.attachmentID) {
                    session.unavailableAttachedWindowIDs.insert(snapshot.attachmentID)
                    didChange = true
                }
            }
        }

        if didChange {
            _ = session.persistActiveWorkspaceSnapshot()
        }
    }

    private func minimizeUnattachedWindows() {
        let recentWindows = lastExternalApplication.map { service.windows(for: $0) } ?? []
        session.minimizeUnattachedWindows(
            knownWindows: windows,
            recentWindows: recentWindows,
            refreshWindowList: false,
            mergeWindows: { effectiveWindows in
                windows = effectiveWindows
            },
            removeWindows: { minimizedIDs in
                windows.removeAll { minimizedIDs.contains($0.id) }
                if let selectedWindowID, minimizedIDs.contains(selectedWindowID) {
                    self.selectedWindowID = nil
                }
            }
        )
    }

    private func restoreMinimizedWindows() {
        session.restoreMinimizedWindows { restoredWindows in
            appendRestoredWindows(restoredWindows)
        }
    }

    private func originsMatch(_ lhs: CGPoint, _ rhs: CGPoint) -> Bool {
        abs(lhs.x - rhs.x) < 3 && abs(lhs.y - rhs.y) < 3
    }

    private func appendRestoredWindows(_ restoredWindows: [WindowInfo]) {
        windows = windowCatalog.merging(restoredWindows, into: windows)
    }

    private func mergeWindows(_ appWindows: [WindowInfo], replacingApplication application: NSRunningApplication) {
        removeCachedWindows(for: application)
        appendRestoredWindows(appWindows)
    }

    private func mergeWindows(_ newWindows: [WindowInfo], into cachedWindows: [WindowInfo]) -> [WindowInfo] {
        windowCatalog.merging(newWindows, into: cachedWindows)
    }

    private func removeCachedWindows(for application: NSRunningApplication) {
        windows = windowCatalog.removingWindows(for: application, from: windows)
        clearInvalidSelectedWindow()
    }

    private func clearInvalidSelectedWindow() {
        if let selectedWindowID, !windows.contains(where: { $0.id == selectedWindowID }) {
            self.selectedWindowID = nil
        }
    }

    private func isSameAttachedWindow(_ lhs: WindowInfo, as rhs: WindowInfo) -> Bool {
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

    private func bringAllAttachedWindowsToFront(updateStatus: Bool = true) {
        guard !session.attachedWindows.isEmpty else {
            return
        }

        let availableWindows = session.attachedWindows.filter { !isUnavailable($0.id) }
        guard !availableWindows.isEmpty else {
            session.statusMessage = "No available board windows to bring to front."
            return
        }

        bringAttachedWindowsToFrontSmoothly(availableWindows, updateStatus: updateStatus)
    }

    private func bringAttachedWindowsToFrontSmoothly(_ windows: [AttachedWindow], updateStatus: Bool) {
        guard !windows.isEmpty else {
            return
        }

        let frontingWindows = windows
        let activationSettleNanoseconds: UInt64 = 45_000_000
        let windowSettleNanoseconds: UInt64 = 65_000_000
        frontingCoordinator.frontAttachedWindows(
            count: frontingWindows.count,
            operation: {
            await raiseAttachedWindowsOffMainThread(
                frontingWindows,
                activationSettleNanoseconds: activationSettleNanoseconds,
                windowSettleNanoseconds: windowSettleNanoseconds,
                serviceFactory: windowServiceFactory
            )
            },
            completion: {
                if updateStatus {
                    session.statusMessage = "Brought \(frontingWindows.count) attached window(s) to front."
                }
            }
        )
    }

    private func bringBoardWindowToFront() {
        NSApp.activate(ignoringOtherApps: true)
        boardWindow?.makeKeyAndOrderFront(nil)
    }

    private func beginTemporaryBoardWorkspaceFronting() -> BoardFrontingCoordinator.WorkspaceToken {
        frontingCoordinator.beginWorkspaceFronting {
            boardWindow?.level = .floating
            bringBoardWindowToFront()
        }
    }

    private func endTemporaryBoardWorkspaceFronting(token: BoardFrontingCoordinator.WorkspaceToken) {
        frontingCoordinator.endWorkspaceFronting(token: token) {
            bringBoardWindowToFront()
            applyBoardWindowLevel()
        }
    }

    private func applyBoardWindowLevel(to window: NSWindow? = nil) {
        let targetWindow = window ?? boardWindow
        targetWindow?.level = isBoardAlwaysOnTop ? .floating : .normal
    }

    private func configureBoardWindowTransparency(_ window: NSWindow) {
        window.isOpaque = false
        let baseBackgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.68)
        window.backgroundColor = baseBackgroundColor
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        window.toolbar?.showsBaselineSeparator = false
        window.styleMask.insert(.fullSizeContentView)
        window.hasShadow = true
        window.contentView?.wantsLayer = true
        window.contentView?.layer?.backgroundColor = baseBackgroundColor.cgColor
    }

    private func scheduleBoardSelectedAction() {
        frontingCoordinator.scheduleBoardSelection(
            isEnabled: { boardClickAction == .bringAttachedToFront },
            hasAvailableWindows: {
                session.attachedWindows.contains(where: { !isUnavailable($0.id) })
            },
            perform: { bringAllAttachedWindowsToFront(updateStatus: false) }
        )
    }

    private func cancelScheduledBoardSelectedAction() {
        frontingCoordinator.cancelBoardSelection()
    }

    private func handleBoardSelected() {
        frontingCoordinator.performBoardSelection(
            isEnabled: { boardClickAction == .bringAttachedToFront },
            hasAvailableWindows: {
                session.attachedWindows.contains(where: { !isUnavailable($0.id) })
            },
            perform: { bringAllAttachedWindowsToFront(updateStatus: false) }
        )
    }

    private func suppressExternalActivationBriefly() {
        suppressExternalActivation(for: 0.7)
    }

    private func suppressExternalActivation(for duration: TimeInterval) {
        frontingCoordinator.suppressExternalActivation(for: duration)
    }

    private func clearAttachedWindowAccessFailure(for id: AttachedWindow.ID) {
        attachedWindowFailureCounts[id] = nil
    }

    private func isUnavailable(_ id: AttachedWindow.ID) -> Bool {
        session.unavailableAttachedWindowIDs.contains(id)
    }

    private func isReconnecting(_ id: AttachedWindow.ID) -> Bool {
        session.reconnectingAttachedWindowIDs.contains(id)
    }

    private func isMinimized(_ id: AttachedWindow.ID) -> Bool {
        minimizedAttachedWindowIDs.contains(id)
    }

    private func markAttachedWindowAvailable(_ id: AttachedWindow.ID) {
        session.unavailableAttachedWindowIDs.remove(id)
        session.reconnectingAttachedWindowIDs.remove(id)
        recoveryIssueByAttachmentID.removeValue(forKey: id)
        recoveryRevisionByAttachmentID.removeValue(forKey: id)
    }

    private func clearAttachedWindowRecoveryActivity(for id: AttachedWindow.ID, matchingRevision: Int? = nil) {
        if let matchingRevision,
           recoveryRevisionByAttachmentID[id] != matchingRevision {
            return
        }

        session.reconnectingAttachedWindowIDs.remove(id)
        activePositionReadIDs.remove(id)
    }

    private func beginAttachedWindowRecovery(
        for id: AttachedWindow.ID,
        message: String,
        marksReconnecting: Bool = true
    ) -> Int {
        let recoveryRevision = (recoveryRevisionByAttachmentID[id] ?? 0) + 1
        recoveryRevisionByAttachmentID[id] = recoveryRevision
        if marksReconnecting {
            session.reconnectingAttachedWindowIDs.insert(id)
        }
        session.statusMessage = message
        return recoveryRevision
    }

    private func finishAttachedWindowRecoveryAsUnavailable(
        for id: AttachedWindow.ID,
        revision: Int,
        issue: AttachedWindowRecoveryIssue,
        message: String
    ) {
        guard recoveryRevisionByAttachmentID[id] == revision else {
            return
        }

        guard session.attachedWindows.contains(where: { $0.id == id }) else {
            recoveryIssueByAttachmentID.removeValue(forKey: id)
            clearAttachedWindowRecoveryActivity(for: id, matchingRevision: revision)
            return
        }

        recoveryIssueByAttachmentID[id] = issue
        handleAttachedWindowAccessFailure(
            for: id,
            error: WindowBoardAXError.operationFailed("Read window position", .invalidUIElement),
            force: true
        )
        session.statusMessage = message
    }

    private func recoverAttachedWindow(_ attachedWindow: AttachedWindow) {
        let attachmentID = attachedWindow.id
        let originalWindow = attachedWindow.window
        let savedReference = attachedWindow.savedReference
        let shouldTryMinimizedRestore = isMinimized(attachmentID)

        guard !isReconnecting(attachmentID) || shouldTryMinimizedRestore else {
            return
        }

        let recoveryRevision = beginAttachedWindowRecovery(
            for: attachmentID,
            message: shouldTryMinimizedRestore
                ? "Restoring \(originalWindow.appName)..."
                : "Checking \(originalWindow.appName)...",
            marksReconnecting: !shouldTryMinimizedRestore
        )

        let coordinator = recoveryCoordinator
        Task.detached(priority: .userInitiated) {
            let result = await coordinator.recover(
                AttachedWindowRecoveryRequest(
                    originalWindow: originalWindow,
                    savedReference: savedReference,
                    shouldTryMinimizedRestore: shouldTryMinimizedRestore
                )
            ) { progress in
                await MainActor.run {
                    applyAttachedWindowRecoveryProgress(
                        progress,
                        attachmentID: attachmentID,
                        revision: recoveryRevision,
                        appName: originalWindow.appName
                    )
                }
            }
            await MainActor.run {
                applyAttachedWindowRecoveryResult(
                    result,
                    attachmentID: attachmentID,
                    revision: recoveryRevision,
                    originalWindow: originalWindow,
                    savedReference: savedReference
                )
            }
        }
    }

    private func applyAttachedWindowRecoveryProgress(
        _ progress: AttachedWindowRecoveryProgress,
        attachmentID: AttachedWindow.ID,
        revision: Int,
        appName: String
    ) {
        guard recoveryRevisionByAttachmentID[attachmentID] == revision,
              session.attachedWindows.contains(where: { $0.id == attachmentID }) else {
            return
        }

        switch progress {
        case .checkingAfterRestoreFailure:
            minimizedAttachedWindowIDs.remove(attachmentID)
            session.reconnectingAttachedWindowIDs.insert(attachmentID)
            session.statusMessage = "Checking \(appName)..."
        case let .lookingForMatch(issue):
            recoveryIssueByAttachmentID[attachmentID] = issue
            session.statusMessage = issue == .openedButNotMatched
                ? "App opened. Looking for a matching window..."
                : "App activated. Looking for a matching window..."
        }
    }

    private func applyAttachedWindowRecoveryResult(
        _ result: AttachedWindowRecoveryResult,
        attachmentID: AttachedWindow.ID,
        revision: Int,
        originalWindow: WindowInfo,
        savedReference: SavedWindowReference?
    ) {
        if case .cancelled = result {
            clearAttachedWindowRecoveryActivity(for: attachmentID, matchingRevision: revision)
            return
        }

        guard recoveryRevisionByAttachmentID[attachmentID] == revision,
              let index = session.attachedWindows.firstIndex(where: { $0.id == attachmentID }) else {
            clearAttachedWindowRecoveryActivity(for: attachmentID, matchingRevision: revision)
            return
        }

        let boardOrigin = boardMotion.currentOrigin ?? session.attachedWindows[index].lastBoardOrigin

        switch result {
        case let .restoredOriginal(position):
            let origin = position ?? session.attachedWindows[index].lastWindowOrigin
            updateRecoveredAttachment(at: index, boardOrigin: boardOrigin, origin: origin)
            session.statusMessage = "Restored \(originalWindow.displayName)."
        case let .alreadyConnected(position):
            updateRecoveredAttachment(at: index, boardOrigin: boardOrigin, origin: position)
            session.statusMessage = "\(originalWindow.appName) is already connected."
        case let .reconnected(replacement, discoveredWindows):
            let origin = replacement.position ?? session.attachedWindows[index].lastWindowOrigin
            session.attachedWindows[index].window = replacement
            session.attachedWindows[index].savedReference = savedReference
            updateRecoveredAttachment(at: index, boardOrigin: boardOrigin, origin: origin)
            appendRestoredWindows(discoveredWindows)
            session.statusMessage = "Reconnected \(replacement.displayName)."
        case let .notMatched(issue, _):
            finishAttachedWindowRecoveryAsUnavailable(
                for: attachmentID,
                revision: revision,
                issue: issue,
                message: issue.failureMessage
            )
        case .cancelled:
            break
        }
    }

    private func updateRecoveredAttachment(at index: Int, boardOrigin: CGPoint, origin: CGPoint) {
        let attachmentID = session.attachedWindows[index].id
        session.attachedWindows[index].lastBoardOrigin = boardOrigin
        session.attachedWindows[index].lastWindowOrigin = origin
        session.attachedWindows[index].lastAppliedOrigin = origin
        session.attachedWindows[index].pendingReleaseOrigin = nil
        minimizedAttachedWindowIDs.remove(attachmentID)
        clearAttachedWindowAccessFailure(for: attachmentID)
        activePositionReadIDs.remove(attachmentID)
        markAttachedWindowAvailable(attachmentID)
    }

    private func useFrontWindowForAttached(_ attachedWindow: AttachedWindow) {
        let attachmentID = attachedWindow.id
        let application = frontWindowReplacementApplication(for: attachedWindow)
        let expectedBundleIdentifier = attachedWindow.savedReference?.bundleIdentifier ?? attachedWindow.window.bundleIdentifier
        let expectedAppName = attachedWindow.savedReference?.appName ?? attachedWindow.window.appName
        let recoveryRevision = beginAttachedWindowRecovery(
            for: attachmentID,
            message: "Checking front window..."
        )

        let coordinator = recoveryCoordinator
        Task.detached(priority: .userInitiated) {
            let result = await coordinator.findFrontWindow(
                application: application,
                expectedBundleIdentifier: expectedBundleIdentifier,
                expectedAppName: expectedAppName
            )
            await MainActor.run {
                applyFrontWindowRecoveryResult(
                    result,
                    attachmentID: attachmentID,
                    revision: recoveryRevision,
                    expectedAppName: expectedAppName
                )
            }
        }
    }

    private func applyFrontWindowRecoveryResult(
        _ result: AttachedFrontWindowResult,
        attachmentID: AttachedWindow.ID,
        revision: Int,
        expectedAppName: String
    ) {
        guard recoveryRevisionByAttachmentID[attachmentID] == revision else {
            return
        }

        guard let index = session.attachedWindows.firstIndex(where: { $0.id == attachmentID }) else {
            recoveryIssueByAttachmentID.removeValue(forKey: attachmentID)
            clearAttachedWindowRecoveryActivity(for: attachmentID, matchingRevision: revision)
            session.statusMessage = "Attached window is no longer on this board."
            return
        }

        switch result {
        case let .matched(replacementWindow, position, size):
            let boardOrigin = boardMotion.currentOrigin ?? session.attachedWindows[index].lastBoardOrigin
            let origin = position ?? session.attachedWindows[index].lastWindowOrigin
            session.attachedWindows[index].window = replacementWindow
            session.attachedWindows[index].lastBoardOrigin = boardOrigin
            session.attachedWindows[index].lastWindowOrigin = origin
            session.attachedWindows[index].lastAppliedOrigin = origin
            session.attachedWindows[index].pendingReleaseOrigin = nil
            session.attachedWindows[index].savedReference = SavedWindowReference.make(
                from: session.attachedWindows[index],
                boardOrigin: boardOrigin,
                size: size
            )
            clearAttachedWindowAccessFailure(for: attachmentID)
            clearAttachedWindowRecoveryActivity(for: attachmentID, matchingRevision: revision)
            minimizedAttachedWindowIDs.remove(attachmentID)
            markAttachedWindowAvailable(attachmentID)
            _ = session.persistActiveWorkspaceSnapshot(
                sizeByAttachmentID: size.map { [attachmentID: $0] } ?? [:]
            )
            windows = mergeWindows([replacementWindow], into: windows)
            session.statusMessage = "Using \(replacementWindow.displayName) for this board."
        case let .notMatched(hadVisibleFrontWindow, candidateCount):
            let message = hadVisibleFrontWindow
                ? "Front window does not match this app."
                : "No matching front window found for \(expectedAppName). Checked \(candidateCount) window(s)."
            finishAttachedWindowRecoveryAsUnavailable(
                for: attachmentID,
                revision: revision,
                issue: recoveryIssueByAttachmentID[attachmentID] ?? .activatedButNotMatched,
                message: message
            )
        case .cancelled:
            clearAttachedWindowRecoveryActivity(for: attachmentID, matchingRevision: revision)
        }
    }

    private func frontWindowReplacementApplication(for attachedWindow: AttachedWindow) -> NSRunningApplication? {
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let runningApplications = NSWorkspace.shared.runningApplications
            .filter { $0.processIdentifier != currentPID }
            .filter { $0.activationPolicy == .regular || $0.activationPolicy == .accessory }

        let matchingApplication: (NSRunningApplication) -> Bool = { application in
            if let expectedBundleIdentifier = attachedWindow.savedReference?.bundleIdentifier ?? attachedWindow.window.bundleIdentifier,
               let applicationBundleIdentifier = application.bundleIdentifier {
                if expectedBundleIdentifier == applicationBundleIdentifier {
                    return true
                }
            }

            let expectedAppName = attachedWindow.savedReference?.appName ?? attachedWindow.window.appName
            return WindowMatching.appNamesMatch(application.localizedName ?? "", expectedAppName)
        }

        if let frontmostApplication = NSWorkspace.shared.frontmostApplication,
           matchingApplication(frontmostApplication) {
            return frontmostApplication
        }

        if let lastExternalApplication,
           matchingApplication(lastExternalApplication) {
            return lastExternalApplication
        }

        return runningApplications.first(where: matchingApplication)
    }

    private func handleAttachedWindowAccessFailure(for id: AttachedWindow.ID, error: Error, force: Bool = false) {
        guard session.attachedWindows.contains(where: { $0.id == id }) else {
            clearAttachedWindowRecoveryActivity(for: id)
            return
        }

        guard force || !isReconnecting(id) else {
            return
        }

        let failureCount = (attachedWindowFailureCounts[id] ?? 0) + 1
        attachedWindowFailureCounts[id] = failureCount
        clearAttachedWindowRecoveryActivity(for: id)
        session.unavailableAttachedWindowIDs.insert(id)

        session.statusMessage = "Attached window is unavailable. Use Activate App or Detach."
    }

    private func detachWindow(id: AttachedWindow.ID, message: String? = nil) {
        session.detachWindow(id: id, boardOrigin: boardMotion.currentOrigin)
        clearAttachedWindowAccessFailure(for: id)
        recoveryIssueByAttachmentID.removeValue(forKey: id)
        recoveryRevisionByAttachmentID.removeValue(forKey: id)
        activePositionReadIDs.remove(id)
        minimizedAttachedWindowIDs.remove(id)
        detachingAttachedWindowIDs.remove(id)
        detachAnimationTasks[id]?.cancel()
        detachAnimationTasks[id] = nil
        if session.attachedWindows.isEmpty {
            followCoordinator.cancelAll()
        }
        if let message {
            session.statusMessage = message
        }
    }

    private func detachAll(message: String) {
        cancelDetachAnimations()
        session.detachAll(boardOrigin: boardMotion.currentOrigin, message: message)
        frontingCoordinator.cancelAttachedWindowFronting()
        attachedWindowFailureCounts.removeAll()
        recoveryIssueByAttachmentID.removeAll()
        recoveryRevisionByAttachmentID.removeAll()
        activePositionReadIDs.removeAll()
        minimizedAttachedWindowIDs.removeAll()
        followCoordinator.cancelAll()
    }
}
