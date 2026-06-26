import AppKit
import ApplicationServices
import SwiftUI

private struct MinimizeWindowsResult {
    let minimizedWindows: [WindowInfo]
    let restoredAttachedWindows: [WindowInfo]
    let failedCount: Int
}

private struct RestoreWindowsResult {
    let restoredWindows: [WindowInfo]
    let failedWindows: [WindowInfo]
}

private struct AttachedWindowSnapshot {
    let attachmentID: AttachedWindow.ID
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

private func raiseAttachedWindowsOffMainThread(
    _ windows: [AttachedWindow],
    activationSettleNanoseconds: UInt64,
    windowSettleNanoseconds: UInt64
) async {
    let service = AccessibilityWindowService()

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
    var pendingReleaseOrigin: CGPoint?
    var lastMoveDate = Date.distantPast
}

struct ContentView: View {
    private let service = AccessibilityWindowService()
    private let moveScheduler = WindowMoveScheduler.shared
    @ObservedObject private var appState: WindowBoardAppState
    @ObservedObject private var workspaceStore: WorkspaceStore

    @StateObject private var boardMotion = BoardMotionState()
    @State private var isTrusted = false
    @State private var windows: [WindowInfo] = []
    @State private var selectedWindowID: WindowInfo.ID?
    @State private var selectedWorkspaceID: SavedWorkspace.ID?
    @State private var activeWorkspaceID: SavedWorkspace.ID?
    @State private var workspaceName = ""
    @State private var attachedWindows: [AttachedWindow] = []
    @State private var boardWindow: NSWindow?
    @State private var isLoadingWindows = false
    @State private var isLoadingWorkspace = false
    @AppStorage("boardAlwaysOnTop") private var isBoardAlwaysOnTop = false
    @AppStorage("minimizeUnattachedOnWorkspaceSwitch") private var shouldMinimizeUnattachedOnWorkspaceSwitch = false
    @State private var pendingAutoFront = false
    @State private var lastBoardClickFrontDate = Date.distantPast
    @State private var boardSelectionTask: Task<Void, Never>?
    @State private var frontingTask: Task<Void, Never>?
    @State private var frontingRevision = 0
    @State private var suppressExternalActivationUntil = Date.distantPast
    @State private var lastExternalApplication: NSRunningApplication?
    @State private var attachedWindowFailureCounts: [AttachedWindow.ID: Int] = [:]
    @State private var unavailableAttachedWindowIDs: Set<AttachedWindow.ID> = []
    @State private var reconnectingAttachedWindowIDs: Set<AttachedWindow.ID> = []
    @State private var activePositionReadIDs: Set<AttachedWindow.ID> = []
    @State private var minimizedWindows: [WindowInfo] = []
    @State private var isMinimizingUnattached = false
    @State private var isRestoringMinimized = false
    @State private var statusMessage = "Select a window to attach it to the board."

    init(appState: WindowBoardAppState) {
        _appState = ObservedObject(initialValue: appState)
        _workspaceStore = ObservedObject(initialValue: appState.workspaceStore)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            if isTrusted {
                windowPicker
                boardAlwaysOnTopToggle
                workspaceSection
                attachedSection
                actionRow
                Text(statusMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                permissionView
            }

            Spacer(minLength: 0)
        }
        .padding(22)
        .background(
            ZStack {
                BoardClickObserver(onClick: handleBoardSelected)
                BoardWindowObserver(
                    onWindowAvailable: { window in
                        boardWindow = window
                        appState.mainWindow = window
                        boardMotion.currentOrigin = window.frame.origin
                        applyBoardWindowLevel(to: window)
                    },
                    onOriginChanged: handleBoardOriginChanged
                )
                .frame(width: 0, height: 0)
            }
        )
        .onAppear {
            refreshTrustAndWindows()
            syncStatusMenuState()
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
        .onChange(of: selectedWorkspaceID) { _, _ in
            workspaceName = selectedWorkspace?.name ?? ""
            loadSelectedWorkspaceIfNeeded()
        }
        .onChange(of: activeWorkspaceID) { _, newValue in
            appState.activeWorkspaceID = newValue
        }
        .onChange(of: attachedWindows.count) { _, _ in
            syncStatusMenuState()
        }
        .onChange(of: minimizedWindows.count) { _, _ in
            syncStatusMenuState()
        }
        .onChange(of: isMinimizingUnattached) { _, _ in
            syncStatusMenuState()
        }
        .onChange(of: isRestoringMinimized) { _, _ in
            syncStatusMenuState()
        }
        .onChange(of: isBoardAlwaysOnTop) { _, _ in
            applyBoardWindowLevel()
            statusMessage = isBoardAlwaysOnTop
                ? "Window Board will stay above normal windows."
                : "Window Board uses normal window level."
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                refreshTrustAndWindows()
            }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                refreshAttachedWindowBaselineIfIdle()
            }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(120))
                applyPendingReleaseMoveIfIdle()
                applyPendingAutoFrontIfIdle()
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Window Board")
                .font(.title2.weight(.semibold))
            Text("Attach windows, then choose whether they follow this board.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
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

    private var windowPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Select Window")
                    .font(.headline)

                Spacer()

                Button {
                    refreshWindowsAsync()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .labelStyle(.iconOnly)
                .help("Refresh window list")
                .disabled(isLoadingWindows)
            }

            if isLoadingWindows {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading windows...")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Picker("Window", selection: $selectedWindowID) {
                    Text("Choose a window").tag(WindowInfo.ID?.none)
                    ForEach(windows) { window in
                        Text(window.displayName).tag(WindowInfo.ID?.some(window.id))
                    }
                }
            }

            Button("Attach Selected Window") {
                attachSelectedWindow()
            }
            .disabled(selectedWindow == nil || boardWindow == nil)

            Button("Attach Frontmost Window") {
                attachFrontmostWindow()
            }
            .disabled(lastExternalApplication == nil || boardWindow == nil)
        }
    }

    private var attachedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Attached")
                .font(.headline)

            if attachedWindows.isEmpty {
                Text("No windows attached")
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(attachedWindows) { attachedWindow in
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(attachedWindow.window.displayName)
                                    .font(.body)
                                    .lineLimit(2)

                                if isReconnecting(attachedWindow.id) {
                                    Text("Reconnecting...")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                } else if isUnavailable(attachedWindow.id) {
                                    Text("Unavailable")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }

                            Spacer()

                            Button("Open / Reconnect") {
                                recoverAttachedWindow(attachedWindow)
                            }

                            Button("Update") {
                                updateAttachedPosition(for: attachedWindow.id)
                            }

                            Button("Detach") {
                                detachWindow(id: attachedWindow.id)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var workspaceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Workspace")
                .font(.headline)

            HStack(spacing: 8) {
                Picker("Saved Workspace", selection: $selectedWorkspaceID) {
                    Text("Choose a workspace").tag(SavedWorkspace.ID?.none)
                    ForEach(workspaceStore.workspaces) { workspace in
                        Text(workspace.displayName).tag(SavedWorkspace.ID?.some(workspace.id))
                    }
                }
                .disabled(isLoadingWorkspace || boardWindow == nil)

                TextField("Name", text: $workspaceName)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 120)

                Button("Save") {
                    saveCurrentWorkspace()
                }
                .disabled(attachedWindows.isEmpty || boardMotion.currentOrigin == nil)

                Button("Overwrite") {
                    overwriteSelectedWorkspace()
                }
                .disabled(selectedWorkspace == nil || attachedWindows.isEmpty || boardMotion.currentOrigin == nil)

                Button("Rename") {
                    renameSelectedWorkspace()
                }
                .disabled(selectedWorkspace == nil || trimmedWorkspaceName.isEmpty)

                Button("Reload") {
                    loadSelectedWorkspace()
                }
                .disabled(selectedWorkspace == nil || isLoadingWorkspace || boardWindow == nil)

                Button("Delete") {
                    deleteSelectedWorkspace()
                }
                .disabled(selectedWorkspace == nil || isLoadingWorkspace)
            }

            if isLoadingWorkspace {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading workspace...")
                        .foregroundStyle(.secondary)
                }
            }

            Toggle("Minimize Unattached On Workspace Switch", isOn: $shouldMinimizeUnattachedOnWorkspaceSwitch)
        }
    }

    private var boardAlwaysOnTopToggle: some View {
        Toggle("Keep Window Board On Top", isOn: $isBoardAlwaysOnTop)
    }

    private var actionRow: some View {
        HStack {
            Button("Update Position") {
                updateAttachedPosition()
            }
            .disabled(attachedWindows.isEmpty || boardWindow == nil)

            Button("Bring To Front") {
                bringAllAttachedWindowsToFront()
            }
            .disabled(attachedWindows.isEmpty)

            Button("Minimize Unattached") {
                minimizeUnattachedWindows()
            }
            .disabled(isMinimizingUnattached || isRestoringMinimized || windows.isEmpty)

            Button("Restore Minimized") {
                restoreMinimizedWindows()
            }
            .disabled(isMinimizingUnattached || isRestoringMinimized || minimizedWindows.isEmpty)

            Button("Detach All") {
                detachAll(message: "Detached all windows.")
            }
            .disabled(attachedWindows.isEmpty)
        }
    }

    private var selectedWindow: WindowInfo? {
        guard let selectedWindowID else {
            return nil
        }
        return windows.first { $0.id == selectedWindowID }
    }

    private var selectedWorkspace: SavedWorkspace? {
        guard let selectedWorkspaceID else {
            return nil
        }
        return workspaceStore.workspaces.first { $0.id == selectedWorkspaceID }
    }

    private var trimmedWorkspaceName: String {
        workspaceName.trimmingCharacters(in: .whitespacesAndNewlines)
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
        appState.activeWorkspaceID = activeWorkspaceID
        appState.hasAttachedWindows = !attachedWindows.isEmpty
        appState.hasMinimizedWindows = !minimizedWindows.isEmpty
        appState.isMinimizingUnattached = isMinimizingUnattached
        appState.isRestoringMinimized = isRestoringMinimized
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
        statusMessage = "Loading windows..."

        Task.detached(priority: .userInitiated) {
            let loadedWindows = AccessibilityWindowService().listWindows()

            await MainActor.run {
                windows = loadedWindows
                isLoadingWindows = false

                if let selectedWindowID, !loadedWindows.contains(where: { $0.id == selectedWindowID }) {
                    self.selectedWindowID = nil
                }

                statusMessage = loadedWindows.isEmpty
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

        Task.detached(priority: .utility) {
            let service = AccessibilityWindowService()
            var appWindows: [WindowInfo] = []
            let attempts = retry ? 6 : 1

            for attempt in 0..<attempts {
                if Task.isCancelled {
                    return
                }

                if attempt > 0 {
                    try? await Task.sleep(for: .milliseconds(120))
                }

                appWindows = service.windows(for: application)
                if !appWindows.isEmpty {
                    break
                }
            }

            let resolvedAppWindows = appWindows

            await MainActor.run {
                mergeWindows(resolvedAppWindows, replacingApplication: application)
            }
        }
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

        guard let lastExternalApplication,
              let boardOrigin = boardMotion.currentOrigin else {
            statusMessage = "Activate another app window first."
            return
        }

        guard let frontmostWindow = service.frontmostWindow(for: lastExternalApplication) else {
            statusMessage = "No attachable frontmost window found for \(lastExternalApplication.localizedName ?? "the selected app")."
            return
        }

        attachWindow(frontmostWindow, boardOrigin: boardOrigin)
    }

    private func attachWindow(_ window: WindowInfo, boardOrigin: CGPoint) {
        do {
            let targetOrigin = try service.position(of: window)
            let attachedWindow = AttachedWindow(
                window: window,
                lastBoardOrigin: boardOrigin,
                lastWindowOrigin: targetOrigin,
                lastAppliedOrigin: targetOrigin,
                pendingReleaseOrigin: nil
            )
            if let existingIndex = attachedWindows.firstIndex(where: { $0.window.id == window.id }) {
                attachedWindows.remove(at: existingIndex)
            }
            clearAttachedWindowAccessFailure(for: attachedWindow.id)
            markAttachedWindowAvailable(attachedWindow.id)
            attachedWindows.insert(attachedWindow, at: attachedWindows.startIndex)
            statusMessage = "Attached \(window.displayName)."
            bringAllAttachedWindowsToFront(updateStatus: false)
        } catch {
            statusMessage = "Could not attach selected window. \(error.localizedDescription)"
        }
    }

    private func saveCurrentWorkspace() {
        guard !attachedWindows.isEmpty,
              let references = currentWorkspaceReferences() else {
            return
        }

        let name = trimmedWorkspaceName.isEmpty
            ? "Workspace \(workspaceStore.workspaces.count + 1)"
            : trimmedWorkspaceName
        let workspace = workspaceStore.saveWorkspace(name: name, windows: references)
        selectedWorkspaceID = workspace.id
        activeWorkspaceID = workspace.id
        workspaceName = workspace.name
        statusMessage = "Saved \(workspace.displayName)."
    }

    private func overwriteSelectedWorkspace() {
        guard let selectedWorkspaceID,
              !attachedWindows.isEmpty,
              let references = currentWorkspaceReferences() else {
            return
        }

        let name = trimmedWorkspaceName.isEmpty ? selectedWorkspace?.name : trimmedWorkspaceName
        guard let workspace = workspaceStore.updateWorkspace(
            id: selectedWorkspaceID,
            name: name,
            windows: references
        ) else {
            return
        }

        workspaceName = workspace.name
        activeWorkspaceID = workspace.id
        statusMessage = "Overwrote \(workspace.displayName)."
    }

    private func renameSelectedWorkspace() {
        guard let selectedWorkspaceID,
              !trimmedWorkspaceName.isEmpty,
              let workspace = workspaceStore.updateWorkspace(id: selectedWorkspaceID, name: trimmedWorkspaceName) else {
            return
        }

        workspaceName = workspace.name
        statusMessage = "Renamed workspace to \(workspace.name)."
    }

    private func currentWorkspaceReferences() -> [SavedWindowReference]? {
        guard let boardOrigin = boardMotion.currentOrigin else {
            return nil
        }

        return attachedWindows.map {
            SavedWindowReference.make(from: $0, boardOrigin: boardOrigin)
        }
    }

    private func loadSelectedWorkspaceIfNeeded() {
        guard let selectedWorkspaceID,
              selectedWorkspaceID != activeWorkspaceID,
              !isLoadingWorkspace,
              boardWindow != nil else {
            return
        }

        loadSelectedWorkspace()
    }

    private func loadWorkspace(id workspaceID: SavedWorkspace.ID) {
        guard let workspace = workspaceStore.workspaces.first(where: { $0.id == workspaceID }),
              boardWindow != nil,
              !isLoadingWorkspace else {
            selectedWorkspaceID = workspaceID
            workspaceName = selectedWorkspace?.name ?? workspaceName
            return
        }

        selectedWorkspaceID = workspaceID
        activeWorkspaceID = workspaceID
        appState.activeWorkspaceID = workspaceID
        workspaceName = workspace.name
        loadWorkspace(workspace)
    }

    @discardableResult
    private func persistActiveWorkspaceState() -> SavedWorkspace? {
        guard let activeWorkspaceID,
              !attachedWindows.isEmpty,
              let references = currentWorkspaceReferences() else {
            return nil
        }

        return workspaceStore.updateWorkspace(id: activeWorkspaceID, windows: references)
    }

    private func loadSelectedWorkspace() {
        guard let workspace = selectedWorkspace,
              let boardOrigin = boardMotion.currentOrigin,
              !isLoadingWorkspace else {
            return
        }

        loadWorkspace(workspace, boardOrigin: boardOrigin)
    }

    private func loadWorkspace(_ workspace: SavedWorkspace) {
        guard let boardOrigin = boardMotion.currentOrigin,
              !isLoadingWorkspace else {
            return
        }

        loadWorkspace(workspace, boardOrigin: boardOrigin)
    }

    private func loadWorkspace(_ workspace: SavedWorkspace, boardOrigin: CGPoint) {
        guard !isLoadingWorkspace else {
            return
        }

        persistActiveWorkspaceState()

        let shouldRestoreSavedOrigin = followMode == .none
        appState.activeWorkspaceID = workspace.id
        isLoadingWorkspace = true
        statusMessage = "Loading \(workspace.name)..."

        Task.detached(priority: .userInitiated) {
            let service = AccessibilityWindowService()
            var availableWindows = service.listWindows()
            var usedWindowIDs = Set<WindowInfo.ID>()
            var loadedAttachedWindows: [AttachedWindow] = []
            var unavailableAttachmentIDs = Set<AttachedWindow.ID>()
            var reconnectedCount = 0
            var restoredCount = 0
            var activatedOnlyCount = 0
            var missedCount = 0

            for reference in workspace.windows {
                if Task.isCancelled {
                    return
                }

                var didRestoreWindow = false
                var didActivateOnly = false
                var replacement = bestSavedWorkspaceWindow(
                    for: reference,
                    in: availableWindows,
                    excluding: usedWindowIDs
                )

                if replacement == nil {
                    if reference.canRestoreWindow {
                        didRestoreWindow = service.openSavedWindowReference(reference)
                    } else {
                        didActivateOnly = service.activateSavedApplication(reference)
                    }

                    let attempts = reference.canRestoreWindow ? 32 : 24
                    for attempt in 0..<attempts {
                        if Task.isCancelled {
                            return
                        }

                        if attempt > 0 {
                            try? await Task.sleep(for: .milliseconds(160))
                        }

                        availableWindows = service.listWindows()
                        replacement = bestSavedWorkspaceWindow(
                            for: reference,
                            in: availableWindows,
                            excluding: usedWindowIDs
                        )

                        if replacement != nil {
                            break
                        }
                    }

                    if replacement == nil, reference.canRestoreWindow {
                        didActivateOnly = service.activateSavedApplication(reference)
                    }
                }

                guard let replacement else {
                    let targetOrigin = reference.targetOrigin(
                        from: boardOrigin,
                        useSavedOrigin: shouldRestoreSavedOrigin
                    )
                    let placeholder = placeholderWindowInfo(for: reference)
                    let unavailableAttachment = AttachedWindow(
                        window: placeholder,
                        savedReference: reference,
                        lastBoardOrigin: boardOrigin,
                        lastWindowOrigin: targetOrigin,
                        lastAppliedOrigin: nil,
                        pendingReleaseOrigin: nil
                    )
                    loadedAttachedWindows.append(unavailableAttachment)
                    unavailableAttachmentIDs.insert(unavailableAttachment.id)

                    if didActivateOnly {
                        activatedOnlyCount += 1
                    } else {
                        missedCount += 1
                    }
                    continue
                }

                if didRestoreWindow {
                    restoredCount += 1
                } else {
                    reconnectedCount += 1
                }

                let targetOrigin = reference.targetOrigin(
                    from: boardOrigin,
                    useSavedOrigin: shouldRestoreSavedOrigin
                )
                let resolvedOrigin: CGPoint
                do {
                    try service.setPosition(targetOrigin, for: replacement)
                    resolvedOrigin = targetOrigin
                } catch {
                    resolvedOrigin = replacement.position ?? targetOrigin
                }

                usedWindowIDs.insert(replacement.id)
                loadedAttachedWindows.append(
                    AttachedWindow(
                        window: replacement,
                        savedReference: reference,
                        lastBoardOrigin: boardOrigin,
                        lastWindowOrigin: resolvedOrigin,
                        lastAppliedOrigin: resolvedOrigin,
                        pendingReleaseOrigin: nil
                    )
                )
            }

            let resolvedAvailableWindows = availableWindows
            let resolvedAttachedWindows = loadedAttachedWindows
            let resolvedUnavailableAttachmentIDs = unavailableAttachmentIDs
            let resolvedReconnectedCount = reconnectedCount
            let resolvedRestoredCount = restoredCount
            let resolvedActivatedOnlyCount = activatedOnlyCount
            let resolvedMissedCount = missedCount

            await MainActor.run {
                attachedWindows = resolvedAttachedWindows
                windows = mergeWindows(resolvedAvailableWindows, into: windows)
                attachedWindowFailureCounts.removeAll()
                unavailableAttachedWindowIDs = resolvedUnavailableAttachmentIDs
                reconnectingAttachedWindowIDs.removeAll()
                activePositionReadIDs.removeAll()
                boardMotion.pendingReleaseOrigin = nil
                isLoadingWorkspace = false
                activeWorkspaceID = workspace.id
                selectedWorkspaceID = workspace.id
                workspaceName = workspace.name

                statusMessage = workspaceLoadStatus(
                    loadedCount: resolvedAttachedWindows.count,
                    reconnectedCount: resolvedReconnectedCount,
                    restoredCount: resolvedRestoredCount,
                    activatedOnlyCount: resolvedActivatedOnlyCount,
                    missedCount: resolvedMissedCount
                )

                if autoFrontMode == .off {
                    bringBoardWindowToFront()
                } else {
                    bringAllAttachedWindowsToFront(updateStatus: false)
                }

                minimizeUnattachedAfterWorkspaceSwitchIfNeeded()
            }
        }
    }

    private func workspaceLoadStatus(
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

    private func deleteSelectedWorkspace() {
        guard let selectedWorkspaceID else {
            return
        }

        workspaceStore.deleteWorkspace(id: selectedWorkspaceID)
        if activeWorkspaceID == selectedWorkspaceID {
            activeWorkspaceID = nil
        }
        self.selectedWorkspaceID = nil
        workspaceName = ""
        statusMessage = "Deleted workspace."
    }

    private func rememberActivatedApplication(from notification: Notification) {
        guard Date() >= suppressExternalActivationUntil else {
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
        boardMotion.lastMoveDate = Date()

        guard !attachedWindows.isEmpty else {
            return
        }

        if followMode == .onRelease || followMode == .animatedRelease {
            boardMotion.pendingReleaseOrigin = origin
            return
        }

        if followMode == .none {
            boardMotion.pendingReleaseOrigin = nil
            return
        }

        for index in attachedWindows.indices {
            let attachedWindow = attachedWindows[index]

            guard !isUnavailable(attachedWindow.id) else {
                attachedWindows[index].lastBoardOrigin = origin
                continue
            }

            let boardDelta = CGPoint(
                x: origin.x - attachedWindow.lastBoardOrigin.x,
                y: origin.y - attachedWindow.lastBoardOrigin.y
            )

            let targetOrigin = CGPoint(
                x: attachedWindow.lastWindowOrigin.x + boardDelta.x,
                y: attachedWindow.lastWindowOrigin.y - boardDelta.y
            )

            if let lastAppliedOrigin = attachedWindow.lastAppliedOrigin,
               abs(lastAppliedOrigin.x - targetOrigin.x) < 1,
               abs(lastAppliedOrigin.y - targetOrigin.y) < 1 {
                attachedWindows[index].lastBoardOrigin = origin
                continue
            }

            attachedWindows[index].lastBoardOrigin = origin
            attachedWindows[index].lastWindowOrigin = targetOrigin
            attachedWindows[index].lastAppliedOrigin = targetOrigin

            switch followMode {
            case .none:
                break
            case .smooth:
                moveAttachedWindow(attachedWindow.window, attachmentID: attachedWindow.id, to: targetOrigin)
            case .onRelease, .animatedRelease:
                break
            }
        }
    }

    private func applyPendingReleaseMoveIfIdle() {
        guard let pendingReleaseBoardOrigin = boardMotion.pendingReleaseOrigin,
              (followMode == .onRelease || followMode == .animatedRelease),
              Date().timeIntervalSince(boardMotion.lastMoveDate) > 0.18 else {
            return
        }

        boardMotion.pendingReleaseOrigin = nil

        for index in attachedWindows.indices {
            let attachedWindow = attachedWindows[index]
            guard !isUnavailable(attachedWindow.id) else {
                attachedWindows[index].lastBoardOrigin = pendingReleaseBoardOrigin
                continue
            }

            let boardDelta = CGPoint(
                x: pendingReleaseBoardOrigin.x - attachedWindow.lastBoardOrigin.x,
                y: pendingReleaseBoardOrigin.y - attachedWindow.lastBoardOrigin.y
            )
            let targetOrigin = CGPoint(
                x: attachedWindow.lastWindowOrigin.x + boardDelta.x,
                y: attachedWindow.lastWindowOrigin.y - boardDelta.y
            )

            if let lastAppliedOrigin = attachedWindow.lastAppliedOrigin,
               abs(lastAppliedOrigin.x - targetOrigin.x) < 1,
               abs(lastAppliedOrigin.y - targetOrigin.y) < 1 {
                attachedWindows[index].lastBoardOrigin = pendingReleaseBoardOrigin
                continue
            }

            let window = attachedWindow.window
            attachedWindows[index].lastBoardOrigin = pendingReleaseBoardOrigin
            attachedWindows[index].lastWindowOrigin = targetOrigin
            attachedWindows[index].lastAppliedOrigin = targetOrigin

            switch followMode {
            case .onRelease:
                moveAttachedWindow(window, attachmentID: attachedWindow.id, to: targetOrigin)
            case .animatedRelease:
                animateAttachedWindow(window, attachmentID: attachedWindow.id, to: targetOrigin)
            case .none, .smooth:
                break
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
        guard autoFrontMode != .off else {
            return
        }

        pendingAutoFront = true
    }

    private func applyPendingAutoFrontIfIdle() {
        guard pendingAutoFront,
              autoFrontMode == .allAttached,
              Date().timeIntervalSince(boardMotion.lastMoveDate) > 0.18,
              !attachedWindows.isEmpty else {
            return
        }

        pendingAutoFront = false
        bringAllAttachedWindowsToFront(updateStatus: false)
    }

    private func refreshAttachedWindowBaselineIfIdle() {
        guard Date().timeIntervalSince(boardMotion.lastMoveDate) > 0.35,
              !attachedWindows.isEmpty else {
            return
        }

        guard positionUpdateMode == .automatic else {
            return
        }

        updateAttachedPosition(showStatus: false)
    }

    private func resetAttachedBoardBaselineToCurrentOrigin() {
        boardMotion.pendingReleaseOrigin = nil

        guard let boardOrigin = boardMotion.currentOrigin else {
            return
        }

        for index in attachedWindows.indices {
            attachedWindows[index].lastBoardOrigin = boardOrigin
            attachedWindows[index].pendingReleaseOrigin = nil
        }
    }

    private func updateAttachedPosition(showStatus: Bool = true) {
        let attachedWindowIDs = attachedWindows.map(\.id)
        for id in attachedWindowIDs {
            updateAttachedPosition(for: id, showStatus: showStatus)
        }
    }

    private func updateAttachedPosition(for id: AttachedWindow.ID, showStatus: Bool = true) {
        guard let boardOrigin = boardMotion.currentOrigin,
              let attachedWindow = attachedWindows.first(where: { $0.id == id }),
              !activePositionReadIDs.contains(id) else {
            return
        }

        activePositionReadIDs.insert(id)

        Task.detached(priority: .utility) {
            let result = Result {
                try AccessibilityWindowService().position(of: attachedWindow.window)
            }

            await MainActor.run {
                activePositionReadIDs.remove(id)

                guard let index = attachedWindows.firstIndex(where: { $0.id == id }) else {
                    return
                }

                switch result {
                case let .success(currentWindowOrigin):
                    attachedWindows[index].lastBoardOrigin = boardOrigin
                    attachedWindows[index].lastWindowOrigin = currentWindowOrigin
                    attachedWindows[index].lastAppliedOrigin = currentWindowOrigin
                    attachedWindows[index].pendingReleaseOrigin = nil
                    clearAttachedWindowAccessFailure(for: id)
                    markAttachedWindowAvailable(id)
                    if showStatus {
                        statusMessage = "Updated position for \(attachedWindow.window.displayName)."
                    }
                case let .failure(error):
                    handleAttachedWindowAccessFailure(for: id, error: error)
                }
            }
        }
    }

    private func minimizeUnattachedWindows() {
        guard !isMinimizingUnattached else {
            return
        }

        let attachedWindowsToRefresh = attachedWindows
        let recentApplication = lastExternalApplication

        isMinimizingUnattached = true
        statusMessage = "Preparing unattached windows..."

        Task.detached(priority: .userInitiated) {
            let service = AccessibilityWindowService()
            let allWindows = service.listWindows()
            let recentWindows = recentApplication.map { service.windows(for: $0) } ?? []
            var refreshedAttachedWindows: [AttachedWindow.ID: WindowInfo] = [:]
            var attachedCandidateWindows: [WindowInfo] = []

            for attachedWindow in attachedWindowsToRefresh {
                if Task.isCancelled {
                    return
                }

                let candidates = service.windows(matching: attachedWindow.window)
                attachedCandidateWindows.append(contentsOf: candidates)

                if let replacement = bestReplacementWindow(for: attachedWindow.window, in: candidates) {
                    refreshedAttachedWindows[attachedWindow.id] = replacement
                }
            }

            let resolvedAttachedCandidateWindows = attachedCandidateWindows
            let resolvedRefreshedAttachedWindows = refreshedAttachedWindows

            await MainActor.run {
                let effectiveWindows: [WindowInfo]
                if let recentApplication {
                    var mergedWindows = mergeWindows(
                        recentWindows,
                        into: allWindows,
                        replacingApplication: recentApplication
                    )
                    mergedWindows = mergeWindows(resolvedAttachedCandidateWindows, into: mergedWindows)
                    effectiveWindows = mergedWindows
                } else {
                    effectiveWindows = mergeWindows(resolvedAttachedCandidateWindows, into: allWindows)
                }

                for (attachmentID, replacement) in resolvedRefreshedAttachedWindows {
                    guard let index = attachedWindows.firstIndex(where: { $0.id == attachmentID }) else {
                        continue
                    }

                    let origin = replacement.position ?? attachedWindows[index].lastWindowOrigin
                    attachedWindows[index].window = replacement
                    attachedWindows[index].lastWindowOrigin = origin
                    attachedWindows[index].lastAppliedOrigin = origin
                    clearAttachedWindowAccessFailure(for: attachmentID)
                    markAttachedWindowAvailable(attachmentID)
                }

                windows = effectiveWindows
                let attachedSnapshots = attachedWindowSnapshots()
                let windowsToMinimize = effectiveWindows.filter {
                    shouldMinimizeWindow($0, attachedSnapshots: attachedSnapshots)
                }

                guard !windowsToMinimize.isEmpty else {
                    isMinimizingUnattached = false
                    statusMessage = "No unattached windows to minimize."
                    return
                }

                beginMinimizing(windowsToMinimize, attachedSnapshots: attachedSnapshots)
            }
        }
    }

    private func minimizeUnattachedAfterWorkspaceSwitchIfNeeded() {
        guard shouldMinimizeUnattachedOnWorkspaceSwitch,
              !attachedWindows.isEmpty,
              attachedWindows.contains(where: { !isUnavailable($0.id) }),
              !isMinimizingUnattached,
              !isRestoringMinimized else {
            return
        }

        minimizeUnattachedWindows()
    }

    private func beginMinimizing(_ windowsToMinimize: [WindowInfo], attachedSnapshots: [AttachedWindowSnapshot]) {
        statusMessage = "Minimizing \(windowsToMinimize.count) unattached window(s)..."

        Task.detached(priority: .userInitiated) {
            let service = AccessibilityWindowService()
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

            let result = MinimizeWindowsResult(
                minimizedWindows: minimizedWindows,
                restoredAttachedWindows: restoredAttachedWindows,
                failedCount: failedCount
            )

            await MainActor.run {
                isMinimizingUnattached = false
                let minimizedIDs = Set(result.minimizedWindows.map(\.id))

                for window in result.minimizedWindows {
                    rememberMinimizedWindow(window)
                }

                windows.removeAll { minimizedIDs.contains($0.id) }
                if let selectedWindowID, minimizedIDs.contains(selectedWindowID) {
                    self.selectedWindowID = nil
                }

                statusMessage = minimizeStatus(
                    minimizedCount: result.minimizedWindows.count,
                    restoredAttachedCount: result.restoredAttachedWindows.count,
                    failedCount: result.failedCount
                )
            }
        }
    }

    private func restoreMinimizedWindows() {
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
                    failedWindows.append(window)
                }
            }

            let result = RestoreWindowsResult(
                restoredWindows: restoredWindows,
                failedWindows: failedWindows
            )

            await MainActor.run {
                isRestoringMinimized = false
                minimizedWindows = result.failedWindows
                appendRestoredWindows(result.restoredWindows)

                if result.failedWindows.isEmpty {
                    statusMessage = "Restored \(result.restoredWindows.count) minimized window(s)."
                } else {
                    statusMessage = "Restored \(result.restoredWindows.count) window(s). \(result.failedWindows.count) could not be restored."
                }
            }
        }
    }

    private func rememberMinimizedWindow(_ window: WindowInfo) {
        guard !minimizedWindows.contains(where: { $0.id == window.id }) else {
            return
        }

        minimizedWindows.append(window)
    }

    private func attachedWindowSnapshots() -> [AttachedWindowSnapshot] {
        attachedWindows.map { attachedWindow in
            return AttachedWindowSnapshot(
                attachmentID: attachedWindow.id,
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
                protectsSameApplicationFromMinimize: shouldProtectSameApplicationFromMinimize(attachedWindow)
            )
        }
    }

    private func shouldMinimizeWindow(
        _ window: WindowInfo,
        attachedSnapshots: [AttachedWindowSnapshot]
    ) -> Bool {
        guard !isAttachedWindow(window, attachedSnapshots: attachedSnapshots) else {
            return false
        }

        return !isAmbiguousSameAppWindow(window, attachedSnapshots: attachedSnapshots)
    }

    private func isAttachedWindow(
        _ window: WindowInfo,
        attachedSnapshots: [AttachedWindowSnapshot]
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

    private func isAmbiguousSameAppWindow(
        _ window: WindowInfo,
        attachedSnapshots: [AttachedWindowSnapshot]
    ) -> Bool {
        attachedSnapshots.contains { snapshot in
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

    private func isSameApplication(_ window: WindowInfo, snapshot: AttachedWindowSnapshot) -> Bool {
        if let windowBundleIdentifier = window.bundleIdentifier,
           let snapshotBundleIdentifier = snapshot.bundleIdentifier {
            return windowBundleIdentifier == snapshotBundleIdentifier
        }

        return window.pid == snapshot.pid || window.appName == snapshot.appName
    }

    private func isStrictMultiWindowApplication(_ bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else {
            return false
        }

        return SavedWindowReference.isVisualStudioCode(bundleIdentifier: bundleIdentifier)
    }

    private func shouldProtectSameApplicationFromMinimize(_ attachedWindow: AttachedWindow) -> Bool {
        let protectedBundleIdentifiers: Set<String> = [
            "com.apple.Terminal"
        ]

        if let bundleIdentifier = attachedWindow.window.bundleIdentifier,
           protectedBundleIdentifiers.contains(bundleIdentifier) {
            return true
        }

        return isUnavailable(attachedWindow.id) || isReconnecting(attachedWindow.id)
    }

    private func originsMatch(_ lhs: CGPoint, _ rhs: CGPoint) -> Bool {
        abs(lhs.x - rhs.x) < 3 && abs(lhs.y - rhs.y) < 3
    }

    private func minimizeStatus(minimizedCount: Int, restoredAttachedCount: Int, failedCount: Int) -> String {
        var message = "Minimized \(minimizedCount) unattached window(s)."

        if restoredAttachedCount > 0 {
            message += " Restored \(restoredAttachedCount) attached window(s)."
        }

        if failedCount > 0 {
            message += " \(failedCount) operation(s) failed."
        }

        return message
    }

    private func appendRestoredWindows(_ restoredWindows: [WindowInfo]) {
        for window in restoredWindows where !windows.contains(where: { $0.id == window.id }) {
            windows.append(window)
        }

        windows.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private func mergeWindows(_ appWindows: [WindowInfo], replacingApplication application: NSRunningApplication) {
        removeCachedWindows(for: application)
        appendRestoredWindows(appWindows)
    }

    private func mergeWindows(_ newWindows: [WindowInfo], into cachedWindows: [WindowInfo]) -> [WindowInfo] {
        var mergedWindows = cachedWindows
        for window in newWindows where !mergedWindows.contains(where: { $0.id == window.id }) {
            mergedWindows.append(window)
        }

        return mergedWindows.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    private func mergeWindows(_ appWindows: [WindowInfo], into cachedWindows: [WindowInfo], replacingApplication application: NSRunningApplication) -> [WindowInfo] {
        var mergedWindows = cachedWindows.filter { !isWindow($0, from: application) }
        for window in appWindows where !mergedWindows.contains(where: { $0.id == window.id }) {
            mergedWindows.append(window)
        }

        return mergedWindows.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    private func removeCachedWindows(for application: NSRunningApplication) {
        windows.removeAll { isWindow($0, from: application) }
        if let selectedWindowID, !windows.contains(where: { $0.id == selectedWindowID }) {
            self.selectedWindowID = nil
        }
    }

    private func isWindow(_ window: WindowInfo, from application: NSRunningApplication) -> Bool {
        if let bundleIdentifier = application.bundleIdentifier,
           let windowBundleIdentifier = window.bundleIdentifier {
            return bundleIdentifier == windowBundleIdentifier
        }

        if window.pid == application.processIdentifier {
            return true
        }

        return application.localizedName == window.appName
    }

    private func bringAllAttachedWindowsToFront(updateStatus: Bool = true) {
        guard !attachedWindows.isEmpty else {
            return
        }

        let availableWindows = attachedWindows.filter { !isUnavailable($0.id) }
        guard !availableWindows.isEmpty else {
            statusMessage = "No available attached windows to bring to front."
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
        let suppressionDuration = 0.8 + (Double(frontingWindows.count) * 0.1)

        frontingTask?.cancel()
        frontingRevision += 1
        let revision = frontingRevision
        suppressExternalActivation(for: suppressionDuration)

        frontingTask = Task.detached(priority: .utility) {
            await raiseAttachedWindowsOffMainThread(
                frontingWindows,
                activationSettleNanoseconds: activationSettleNanoseconds,
                windowSettleNanoseconds: windowSettleNanoseconds
            )

            await MainActor.run {
                guard !Task.isCancelled, revision == frontingRevision else {
                    return
                }

                if updateStatus {
                    statusMessage = "Brought \(frontingWindows.count) attached window(s) to front."
                }
                frontingTask = nil
            }
        }
    }

    private func bringBoardWindowToFront() {
        NSApp.activate(ignoringOtherApps: true)
        boardWindow?.makeKeyAndOrderFront(nil)
    }

    private func applyBoardWindowLevel(to window: NSWindow? = nil) {
        let targetWindow = window ?? boardWindow
        targetWindow?.level = isBoardAlwaysOnTop ? .floating : .normal
    }

    private func scheduleBoardSelectedAction() {
        cancelScheduledBoardSelectedAction()

        boardSelectionTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else {
                return
            }

            handleBoardSelected()
            boardSelectionTask = nil
        }
    }

    private func cancelScheduledBoardSelectedAction() {
        boardSelectionTask?.cancel()
        boardSelectionTask = nil
    }

    private func handleBoardSelected() {
        guard boardClickAction == .bringAttachedToFront,
              attachedWindows.contains(where: { !isUnavailable($0.id) }),
              Date().timeIntervalSince(lastBoardClickFrontDate) > 0.3 else {
            return
        }

        lastBoardClickFrontDate = Date()
        bringAllAttachedWindowsToFront(updateStatus: false)
    }

    private func suppressExternalActivationBriefly() {
        suppressExternalActivation(for: 0.7)
    }

    private func suppressExternalActivation(for duration: TimeInterval) {
        suppressExternalActivationUntil = Date().addingTimeInterval(duration)
    }

    private func clearAttachedWindowAccessFailure(for id: AttachedWindow.ID) {
        attachedWindowFailureCounts[id] = nil
    }

    private func isUnavailable(_ id: AttachedWindow.ID) -> Bool {
        unavailableAttachedWindowIDs.contains(id)
    }

    private func isReconnecting(_ id: AttachedWindow.ID) -> Bool {
        reconnectingAttachedWindowIDs.contains(id)
    }

    private func markAttachedWindowAvailable(_ id: AttachedWindow.ID) {
        unavailableAttachedWindowIDs.remove(id)
        reconnectingAttachedWindowIDs.remove(id)
    }

    private func recoverAttachedWindow(_ attachedWindow: AttachedWindow) {
        let attachmentID = attachedWindow.id
        let originalWindow = attachedWindow.window
        let savedReference = attachedWindow.savedReference

        guard !isReconnecting(attachmentID) else {
            return
        }

        reconnectingAttachedWindowIDs.insert(attachmentID)
        statusMessage = "Checking \(originalWindow.appName)..."

        Task.detached(priority: .userInitiated) {
            let service = AccessibilityWindowService()
            let livePosition: CGPoint?
            if originalWindow.pid == 0 {
                livePosition = nil
            } else {
                livePosition = try? service.position(of: originalWindow)
            }

            if let livePosition {
                service.activateApplication(pid: originalWindow.pid)

                await MainActor.run {
                    guard let index = attachedWindows.firstIndex(where: { $0.id == attachmentID }) else {
                        return
                    }

                    let boardOrigin = boardMotion.currentOrigin ?? attachedWindows[index].lastBoardOrigin
                    attachedWindows[index].lastBoardOrigin = boardOrigin
                    attachedWindows[index].lastWindowOrigin = livePosition
                    attachedWindows[index].lastAppliedOrigin = livePosition
                    attachedWindows[index].pendingReleaseOrigin = nil
                    clearAttachedWindowAccessFailure(for: attachmentID)
                    activePositionReadIDs.remove(attachmentID)
                    markAttachedWindowAvailable(attachmentID)
                    statusMessage = "\(originalWindow.appName) is already connected."
                }
                return
            }

            var replacement: WindowInfo?
            var latestWindows: [WindowInfo] = []
            var didReopen = false
            var didRequestNewWindow = false
            var didActivateApplication = false
            let unavailableError = WindowBoardAXError.operationFailed("Read window position", .invalidUIElement)

            for attempt in 0..<40 {
                if Task.isCancelled {
                    return
                }

                if attempt == 0 {
                    if let savedReference {
                        didReopen = service.openSavedWindowReference(savedReference)
                        if !didReopen {
                            didActivateApplication = service.activateSavedApplication(savedReference)
                        }
                    } else {
                        didReopen = service.openDocument(for: originalWindow)
                        if !didReopen {
                            didActivateApplication = service.activateOrOpenApplication(for: originalWindow)
                        }
                    }
                }

                if attempt == 8 {
                    if let savedReference {
                        didRequestNewWindow = service.openSavedWindowReference(savedReference)
                        if !didRequestNewWindow {
                            didActivateApplication = service.activateSavedApplication(savedReference)
                        }
                    } else {
                        didRequestNewWindow = service.openNewWindow(for: originalWindow)
                        if !didRequestNewWindow {
                            didActivateApplication = service.activateOrOpenApplication(for: originalWindow)
                        }
                    }
                }

                if attempt > 0 {
                    let delayMilliseconds = attempt < 12 ? 35 : 90
                    try? await Task.sleep(for: .milliseconds(delayMilliseconds))
                }

                if let savedReference {
                    let candidates = service.listWindows()
                    latestWindows = candidates
                    replacement = bestSavedWorkspaceWindow(
                        for: savedReference,
                        in: candidates,
                        excluding: []
                    )
                } else {
                    let candidates = service.windows(matching: originalWindow)
                    latestWindows = candidates
                    replacement = bestReplacementWindow(for: originalWindow, in: candidates)
                }
                if replacement != nil {
                    break
                }
            }

            let resolvedReplacement = replacement
            let resolvedWindows = latestWindows
            let resolvedDidReopen = didReopen
            let resolvedDidRequestNewWindow = didRequestNewWindow
            let resolvedDidActivateApplication = didActivateApplication

            await MainActor.run {
                guard let index = attachedWindows.firstIndex(where: { $0.id == attachmentID }) else {
                    return
                }

                guard let replacement = resolvedReplacement else {
                    reconnectingAttachedWindowIDs.remove(attachmentID)
                    handleAttachedWindowAccessFailure(for: attachmentID, error: unavailableError)
                    statusMessage = resolvedDidRequestNewWindow
                        ? "Opened \(originalWindow.appName), but could not find a matching window to reconnect."
                        : resolvedDidReopen
                        ? "Opened \(originalWindow.appName), but could not find a matching window to reconnect."
                        : resolvedDidActivateApplication
                        ? "Activated \(originalWindow.appName), but could not reconnect a matching window."
                        : "Could not find a matching window to reconnect."
                    return
                }

                let boardOrigin = boardMotion.currentOrigin ?? attachedWindows[index].lastBoardOrigin
                let origin = replacement.position ?? attachedWindows[index].lastWindowOrigin
                attachedWindows[index].window = replacement
                attachedWindows[index].savedReference = savedReference
                attachedWindows[index].lastBoardOrigin = boardOrigin
                attachedWindows[index].lastWindowOrigin = origin
                attachedWindows[index].lastAppliedOrigin = origin
                attachedWindows[index].pendingReleaseOrigin = nil
                clearAttachedWindowAccessFailure(for: attachmentID)
                activePositionReadIDs.remove(attachmentID)
                markAttachedWindowAvailable(attachmentID)
                appendRestoredWindows(resolvedWindows)
                statusMessage = "Reconnected \(replacement.displayName)."
            }
        }
    }

    private func handleAttachedWindowAccessFailure(for id: AttachedWindow.ID, error: Error) {
        guard attachedWindows.contains(where: { $0.id == id }) else {
            return
        }

        let failureCount = (attachedWindowFailureCounts[id] ?? 0) + 1
        attachedWindowFailureCounts[id] = failureCount
        unavailableAttachedWindowIDs.insert(id)

        statusMessage = "Attached window is unavailable. Use Activate App or Detach."
    }

    private func detachWindow(id: AttachedWindow.ID, message: String? = nil) {
        persistActiveWorkspaceState()
        attachedWindows.removeAll { $0.id == id }
        clearAttachedWindowAccessFailure(for: id)
        unavailableAttachedWindowIDs.remove(id)
        reconnectingAttachedWindowIDs.remove(id)
        activePositionReadIDs.remove(id)
        if attachedWindows.isEmpty {
            boardMotion.pendingReleaseOrigin = nil
            pendingAutoFront = false
        }
        statusMessage = message ?? "Detached window."
    }

    private func detachAll(message: String) {
        persistActiveWorkspaceState()
        frontingTask?.cancel()
        frontingTask = nil
        frontingRevision += 1
        attachedWindows.removeAll()
        attachedWindowFailureCounts.removeAll()
        unavailableAttachedWindowIDs.removeAll()
        reconnectingAttachedWindowIDs.removeAll()
        activePositionReadIDs.removeAll()
        boardMotion.pendingReleaseOrigin = nil
        pendingAutoFront = false
        statusMessage = message
    }
}
