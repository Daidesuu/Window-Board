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

private struct AttachedWindowSnapshotResult {
    let id: AttachedWindow.ID
    let origin: CGPoint?
    let size: CGSize?
    let isMinimized: Bool
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
    @ObservedObject private var session: WorkspaceSessionController

    @StateObject private var boardMotion = BoardMotionState()
    @State private var isTrusted = false
    @State private var windows: [WindowInfo] = []
    @State private var selectedWindowID: WindowInfo.ID?
    @State private var boardWindow: NSWindow?
    @State private var isLoadingWindows = false
    @AppStorage("boardAlwaysOnTop") private var isBoardAlwaysOnTop = false
    @AppStorage("minimizeUnattachedOnWorkspaceSwitch") private var shouldMinimizeUnattachedOnWorkspaceSwitch = false
    @AppStorage("restoreMissingWindowsOnWorkspaceSwitch") private var shouldRestoreMissingWindowsOnWorkspaceSwitch = false
    @State private var pendingAutoFront = false
    @State private var lastBoardClickFrontDate = Date.distantPast
    @State private var boardSelectionTask: Task<Void, Never>?
    @State private var frontingTask: Task<Void, Never>?
    @State private var frontingRevision = 0
    @State private var workspaceFrontingRevision = 0
    @State private var attachedWindowSnapshotTask: Task<Void, Never>?
    @State private var suppressExternalActivationUntil = Date.distantPast
    @State private var lastExternalApplication: NSRunningApplication?
    @State private var attachedWindowFailureCounts: [AttachedWindow.ID: Int] = [:]
    @State private var activePositionReadIDs: Set<AttachedWindow.ID> = []
    @State private var minimizedAttachedWindowIDs: Set<AttachedWindow.ID> = []
    @State private var workspaceStatusTextInput = ""

    init(appState: WindowBoardAppState) {
        _appState = ObservedObject(initialValue: appState)
        _workspaceStore = ObservedObject(initialValue: appState.workspaceStore)
        _session = ObservedObject(initialValue: appState.session)
    }

    var body: some View {
        Group {
            if isTrusted {
                NavigationSplitView {
                    workspaceSidebar
                } detail: {
                    workspaceDetail
                }
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
            ToolbarItemGroup {
                Button {
                    refreshWindowsAsync()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Refresh window list")
                .disabled(!isTrusted || isLoadingWindows)

                Button {
                    attachFrontmostWindow()
                } label: {
                    Label("Attach Window", systemImage: "plus.rectangle.on.rectangle")
                }
                .help("Pin the frontmost window to this board")
                .disabled(!isTrusted || lastExternalApplication == nil || boardWindow == nil)

                Button {
                    bringAllAttachedWindowsToFront()
                } label: {
                    Label("Focus Board", systemImage: "scope")
                }
                .help("Bring this board's pinned windows to the front")
                .disabled(!isTrusted || session.attachedWindows.isEmpty)

                Button {
                    minimizeUnattachedWindows()
                } label: {
                    Label("Minimize Others", systemImage: "minus.square")
                }
                .help("Minimize windows not in this workspace")
                .disabled(!isTrusted || session.isMinimizingUnattached || session.isRestoringMinimized || windows.isEmpty)

                Button {
                    restoreMinimizedWindows()
                } label: {
                    Label("Restore Windows", systemImage: "arrow.counterclockwise")
                }
                .help("Restore windows minimized by WindowBoard")
                .disabled(!isTrusted || session.isMinimizingUnattached || session.isRestoringMinimized || session.minimizedWindows.isEmpty)
            }
        }
        .onAppear {
            refreshTrustAndWindows()
            syncStatusMenuState()
            restartAttachedWindowSnapshotTask()
        }
        .onDisappear {
            stopAttachedWindowSnapshotTask()
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
        .onChange(of: session.isMinimizingUnattached) { _, _ in
            syncStatusMenuState()
        }
        .onChange(of: session.isRestoringMinimized) { _, _ in
            syncStatusMenuState()
        }
        .onChange(of: isBoardAlwaysOnTop) { _, _ in
            applyBoardWindowLevel()
            session.statusMessage = isBoardAlwaysOnTop
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

    private var workspaceSidebar: some View {
        WorkspaceSidebarView(
            workspaces: workspaceStore.workspaces,
            activeWorkspaceID: session.activeWorkspaceID,
            selection: $session.selectedWorkspaceID
        )
    }

    private var workspaceDetail: some View {
        WorkspaceDetailView(
            selectedWorkspace: selectedWorkspace,
            selectedWindowID: selectedWindowID,
            windows: windows,
            attachedWindows: session.attachedWindows,
            statusMessage: session.statusMessage,
            isLoadingWindows: isLoadingWindows,
            isLoadingWorkspace: session.isLoadingWorkspace,
            isMinimizingUnattached: session.isMinimizingUnattached,
            isRestoringMinimized: session.isRestoringMinimized,
            canAttachSelected: selectedWindow != nil && boardWindow != nil,
            canAttachFrontmost: lastExternalApplication != nil && boardWindow != nil,
            canSaveWorkspace: !session.attachedWindows.isEmpty && boardMotion.currentOrigin != nil,
            canOverwriteWorkspace: selectedWorkspace != nil && !session.attachedWindows.isEmpty && boardMotion.currentOrigin != nil,
            canEditWorkspaceName: selectedWorkspace?.isDefault != true,
            canRenameWorkspace: selectedWorkspace != nil && selectedWorkspace?.isDefault != true && !trimmedWorkspaceName.isEmpty,
            canReloadWorkspace: selectedWorkspace != nil && !session.isLoadingWorkspace && boardWindow != nil,
            canDeleteWorkspace: selectedWorkspace != nil && selectedWorkspace?.isDefault != true && !session.isLoadingWorkspace,
            canUpdatePositions: !session.attachedWindows.isEmpty && boardWindow != nil,
            canBringToFront: !session.attachedWindows.isEmpty,
            canMinimizeUnattached: !session.isMinimizingUnattached && !session.isRestoringMinimized && !windows.isEmpty,
            canRestoreMinimized: !session.isMinimizingUnattached && !session.isRestoringMinimized && !session.minimizedWindows.isEmpty,
            canDetachAll: !session.attachedWindows.isEmpty,
            workspaceName: $session.workspaceName,
            selectedWindow: $selectedWindowID,
            workspaceStatusText: $workspaceStatusTextInput,
            minimizeUnattachedOnSwitch: $shouldMinimizeUnattachedOnWorkspaceSwitch,
            restoreMissingWindowsOnSwitch: $shouldRestoreMissingWindowsOnWorkspaceSwitch,
            boardAlwaysOnTop: $isBoardAlwaysOnTop,
            attachedState: attachedDisplayState(for:),
            refreshWindows: refreshWindowsAsync,
            attachSelected: attachSelectedWindow,
            attachFrontmost: attachFrontmostWindow,
            saveWorkspace: saveCurrentWorkspace,
            overwriteWorkspace: overwriteSelectedWorkspace,
            renameWorkspace: renameSelectedWorkspace,
            reloadWorkspace: loadSelectedWorkspace,
            deleteWorkspace: deleteSelectedWorkspace,
            updateStatusItemIcon: updateSelectedWorkspaceIcon,
            updateStatusItemText: updateSelectedWorkspaceStatusText,
            recoverAttached: recoverAttachedWindow,
            updateAttached: updateAttachedPositionFromMainView(id:),
            detachAttached: detachWindowFromMainView(id:),
            bringForwardAttached: { bringAttachedWindowToFrontFromMainView($0) },
            updatePositions: updateAttachedPositionsFromMainView,
            bringToFront: bringAllAttachedWindowsToFrontFromMainView,
            minimizeUnattached: minimizeUnattachedWindows,
            restoreMinimized: restoreMinimizedWindows,
            detachAll: detachAllFromMainView
        )
    }

    private func detachAllFromMainView() {
        detachAll(message: "Detached all windows.")
    }

    private func bringAttachedWindowToFrontFromMainView(_ attachedWindow: AttachedWindow) {
        guard !isUnavailable(attachedWindow.id) else {
            session.statusMessage = "\(attachedWindow.window.appName) is not available."
            return
        }

        bringAttachedWindowsToFrontSmoothly([attachedWindow], updateStatus: true)
    }

    private func updateAttachedPositionFromMainView(id: AttachedWindow.ID) {
        updateAttachedPosition(for: id)
    }

    private func detachWindowFromMainView(id: AttachedWindow.ID) {
        detachWindow(id: id)
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
        sectionContainer {
            HStack {
                sectionTitle("Window Selection", systemImage: "macwindow")

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

            VStack(alignment: .leading, spacing: 8) {
                if isLoadingWindows {
                    progressRow("Loading windows...")
                } else {
                    Picker("Window", selection: $selectedWindowID) {
                        Text("Choose a window").tag(WindowInfo.ID?.none)
                        ForEach(windows) { window in
                            Text(window.displayName).tag(WindowInfo.ID?.some(window.id))
                        }
                    }
                }

                HStack(spacing: 8) {
                    Button("Attach Selected") {
                        attachSelectedWindow()
                    }
                    .disabled(selectedWindow == nil || boardWindow == nil)

                    Button("Attach Window") {
                        attachFrontmostWindow()
                    }
                    .disabled(lastExternalApplication == nil || boardWindow == nil)

                    Spacer()
                }
            }
        }
    }

    private var attachedSection: some View {
        sectionContainer {
            HStack {
                sectionTitle("Attached Windows", systemImage: "rectangle.stack")
                Spacer()
                Text("\(session.attachedWindows.count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            if session.attachedWindows.isEmpty {
                Text("No windows attached")
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(session.attachedWindows, id: \.id) { attachedWindow in
                        attachedWindowRow(attachedWindow)
                    }
                }
            }
        }
    }

    private func attachedWindowRow(_ attachedWindow: AttachedWindow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(attachedWindow.window.appName)
                        .font(.body.weight(.medium))
                        .lineLimit(1)

                    if !attachedWindow.window.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(attachedWindow.window.title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }

                Spacer(minLength: 8)

                attachedStatusBadge(for: attachedWindow)
            }

            HStack(spacing: 8) {
                if isUnavailable(attachedWindow.id) || isReconnecting(attachedWindow.id) {
                    Button("Open / Reconnect") {
                        recoverAttachedWindow(attachedWindow)
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button("Open / Reconnect") {
                        recoverAttachedWindow(attachedWindow)
                    }
                }

                Button("Update") {
                    updateAttachedPosition(for: attachedWindow.id)
                }

                Button("Detach") {
                    detachWindow(id: attachedWindow.id)
                }

                Spacer()
            }
        }
        .padding(.vertical, 4)
    }

    private var workspaceSection: some View {
        sectionContainer {
            HStack {
                sectionTitle("Current Workspace", systemImage: "rectangle.on.rectangle")
                Spacer()
                if let selectedWorkspace {
                    Text(selectedWorkspace.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Picker("Saved Workspace", selection: $session.selectedWorkspaceID) {
                        Text("Choose a workspace").tag(SavedWorkspace.ID?.none)
                        ForEach(workspaceStore.workspaces) { workspace in
                            Text(workspace.displayName).tag(SavedWorkspace.ID?.some(workspace.id))
                        }
                    }
                    .disabled(session.isLoadingWorkspace || boardWindow == nil)

                    Button("Reload") {
                        loadSelectedWorkspace()
                    }
                    .disabled(selectedWorkspace == nil || session.isLoadingWorkspace || boardWindow == nil)
                }

                HStack(spacing: 8) {
                    TextField("Workspace Name", text: $session.workspaceName)
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 160)

                    Button("Save") {
                        saveCurrentWorkspace()
                    }
                    .disabled(session.attachedWindows.isEmpty || boardMotion.currentOrigin == nil)

                    Button("Overwrite") {
                        overwriteSelectedWorkspace()
                    }
                    .disabled(selectedWorkspace == nil || session.attachedWindows.isEmpty || boardMotion.currentOrigin == nil)

                    Button("Rename") {
                        renameSelectedWorkspace()
                    }
                    .disabled(selectedWorkspace == nil || trimmedWorkspaceName.isEmpty)

                    Spacer()

                    Button("Delete") {
                        deleteSelectedWorkspace()
                    }
                    .disabled(selectedWorkspace == nil || session.isLoadingWorkspace)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Status Item Display")
                    .font(.subheadline.weight(.medium))

                HStack(spacing: 8) {
                    statusItemPreview

                    Spacer()

                    TextField("Text", text: $workspaceStatusTextInput)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 96)
                        .disabled(selectedWorkspace == nil)

                    Button("Set Text") {
                        updateSelectedWorkspaceStatusText()
                    }
                    .disabled(selectedWorkspace == nil)

                    workspaceIconMenu
                        .disabled(selectedWorkspace == nil)
                }
            }

            if session.isLoadingWorkspace {
                progressRow("Loading workspace...")
            }

            Toggle("Minimize Unattached On Workspace Switch", isOn: $shouldMinimizeUnattachedOnWorkspaceSwitch)
                .font(.caption)
        }
    }

    private var workspaceIconMenu: some View {
        Menu {
            Section("Symbols") {
                ForEach(WorkspaceStatusItemIcon.options) { icon in
                    Button {
                        updateSelectedWorkspaceIcon(icon.symbolName)
                    } label: {
                        Label(icon.label, systemImage: icon.symbolName)
                    }
                }
            }

            Section("Emoji") {
                ForEach(WorkspaceStatusItemIcon.emojiOptions) { icon in
                    Button {
                        updateSelectedWorkspaceIcon(icon.symbolName)
                    } label: {
                        Text("\(icon.emoji ?? "") \(icon.label)")
                    }
                }
            }
        } label: {
            workspaceIconLabel
        }
    }

    private var statusItemPreview: some View {
        HStack(spacing: 6) {
            if let title = WorkspaceStatusItemIcon.title(from: selectedWorkspace?.statusItemSymbolName) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
            } else {
                Image(systemName: selectedWorkspace?.statusItemSymbolName ?? WorkspaceStatusItemIcon.defaultSymbolName)
                    .font(.body)
            }

            Text("Current")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.quaternary)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private var workspaceIconLabel: some View {
        Group {
            if let title = WorkspaceStatusItemIcon.title(from: selectedWorkspace?.statusItemSymbolName) {
                Text("\(title) Display")
            } else {
                Label("Icon", systemImage: selectedWorkspace?.statusItemSymbolName ?? WorkspaceStatusItemIcon.defaultSymbolName)
            }
        }
    }

    private var boardAlwaysOnTopToggle: some View {
        Toggle("Keep Window Board On Top", isOn: $isBoardAlwaysOnTop)
    }

    private var actionRow: some View {
        sectionContainer {
            HStack {
                sectionTitle("Actions", systemImage: "bolt")
                Spacer()
            }

            HStack {
                Button("Update Position") {
                    updateAttachedPosition()
                }
                .disabled(session.attachedWindows.isEmpty || boardWindow == nil)

                Button("Show Attached") {
                    bringAllAttachedWindowsToFront()
                }
                .disabled(session.attachedWindows.isEmpty)

                Button("Minimize Others") {
                    minimizeUnattachedWindows()
                }
                .disabled(session.isMinimizingUnattached || session.isRestoringMinimized || windows.isEmpty)

                Button("Restore Windows") {
                    restoreMinimizedWindows()
                }
                .disabled(session.isMinimizingUnattached || session.isRestoringMinimized || session.minimizedWindows.isEmpty)

                Spacer()

                Button("Detach All") {
                    detachAll(message: "Detached all windows.")
                }
                .disabled(session.attachedWindows.isEmpty)
            }
        }
    }

    private var statusFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            if session.isLoadingWorkspace {
                progressRow("Restoring windows and reconnecting as needed...")
            } else if session.isMinimizingUnattached {
                progressRow("Minimizing unattached windows...")
            } else if session.isRestoringMinimized {
                progressRow("Restoring minimized windows...")
            }

            Text(session.statusMessage)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func sectionContainer<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func sectionTitle(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.headline)
    }

    private func progressRow(_ title: String) -> some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(title)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func attachedStatusBadge(for attachedWindow: AttachedWindow) -> some View {
        if isReconnecting(attachedWindow.id) {
            statusBadge("Reconnecting", systemImage: "arrow.triangle.2.circlepath")
        } else if isUnavailable(attachedWindow.id) {
            statusBadge("Unavailable", systemImage: "exclamationmark.triangle")
        } else if isMinimized(attachedWindow.id) {
            statusBadge("Minimized", systemImage: "minus.square")
        } else {
            statusBadge("Available", systemImage: "checkmark.circle")
        }
    }

    private func attachedDisplayState(for attachedWindow: AttachedWindow) -> AttachedWindowDisplayState {
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

    private func statusBadge(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(.quaternary)
            .clipShape(Capsule())
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
              appActiveWorkspaceID != session.activeWorkspaceID,
              !session.isLoadingWorkspace,
              boardWindow != nil else {
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
            let loadedWindows = AccessibilityWindowService().listWindows()

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
            session.statusMessage = "Activate another app window first."
            return
        }

        guard let frontmostWindow = service.frontmostWindow(for: lastExternalApplication) else {
            session.statusMessage = "No attachable frontmost window found for \(lastExternalApplication.localizedName ?? "the selected app")."
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
            let wasAlreadyAttached = session.attachedWindows.contains {
                isSameAttachedWindow($0.window, as: window)
            }
            session.attachedWindows.removeAll { isSameAttachedWindow($0.window, as: window) }
            clearAttachedWindowAccessFailure(for: attachedWindow.id)
            markAttachedWindowAvailable(attachedWindow.id)
            session.attachedWindows.insert(attachedWindow, at: session.attachedWindows.startIndex)
            session.statusMessage = wasAlreadyAttached
                ? "Already attached. Updated \(window.displayName)."
                : "Attached \(window.displayName)."
            bringAllAttachedWindowsToFront(updateStatus: false)
        } catch {
            session.statusMessage = "Could not attach selected window. \(error.localizedDescription)"
        }
    }

    private func saveCurrentWorkspace() {
        session.saveCurrentWorkspace(name: session.workspaceName, boardOrigin: boardMotion.currentOrigin)
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
        let workspaceFrontingRevision = shouldTemporarilyFrontBoard
            ? beginTemporaryBoardWorkspaceFronting()
            : nil
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
                activePositionReadIDs.removeAll()
                boardMotion.pendingReleaseOrigin = nil
                if autoFrontMode == .off {
                    if shouldBringBoardToFrontAfterLoad && shouldBringBoardToFront {
                        bringBoardWindowToFront()
                    }
                } else if !shouldMinimizeUnattachedOnWorkspaceSwitch {
                    bringAllAttachedWindowsToFront(updateStatus: false)
                }

                if !usesDeferredWindowApplication, let workspaceFrontingRevision {
                    endTemporaryBoardWorkspaceFronting(revision: workspaceFrontingRevision)
                }
            },
            deferredWindowApplicationCompletion: {
                guard autoFrontMode == .off,
                      shouldBringBoardToFrontAfterLoad,
                      let workspaceFrontingRevision else {
                    return
                }

                bringBoardWindowToFront()
                endTemporaryBoardWorkspaceFronting(revision: workspaceFrontingRevision)
            },
            minimizeAfterSwitchCompletion: {
                guard shouldMinimizeUnattachedOnWorkspaceSwitch,
                      shouldBringBoardToFrontAfterLoad else {
                    return
                }

                bringBoardWindowToFront()
            }
        )
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

        guard !session.attachedWindows.isEmpty else {
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

        for index in session.attachedWindows.indices {
            let attachedWindow = session.attachedWindows[index]

            guard !isUnavailable(attachedWindow.id) else {
                session.attachedWindows[index].lastBoardOrigin = origin
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
                session.attachedWindows[index].lastBoardOrigin = origin
                continue
            }

            session.attachedWindows[index].lastBoardOrigin = origin
            session.attachedWindows[index].lastWindowOrigin = targetOrigin
            session.attachedWindows[index].lastAppliedOrigin = targetOrigin

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

        for index in session.attachedWindows.indices {
            let attachedWindow = session.attachedWindows[index]
            guard !isUnavailable(attachedWindow.id) else {
                session.attachedWindows[index].lastBoardOrigin = pendingReleaseBoardOrigin
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
                session.attachedWindows[index].lastBoardOrigin = pendingReleaseBoardOrigin
                continue
            }

            let window = attachedWindow.window
            session.attachedWindows[index].lastBoardOrigin = pendingReleaseBoardOrigin
            session.attachedWindows[index].lastWindowOrigin = targetOrigin
            session.attachedWindows[index].lastAppliedOrigin = targetOrigin

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
              !session.attachedWindows.isEmpty else {
            return
        }

        pendingAutoFront = false
        bringAllAttachedWindowsToFront(updateStatus: false)
    }

    private func refreshAttachedWindowBaselineIfIdle() {
        guard Date().timeIntervalSince(boardMotion.lastMoveDate) > 0.35,
              !session.attachedWindows.isEmpty else {
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

        activePositionReadIDs.insert(id)

        Task.detached(priority: .utility) {
            let result = Result {
                try AccessibilityWindowService().position(of: attachedWindow.window)
            }

            await MainActor.run {
                activePositionReadIDs.remove(id)

                guard let index = session.attachedWindows.firstIndex(where: { $0.id == id }) else {
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
        stopAttachedWindowSnapshotTask()

        guard !session.attachedWindows.isEmpty else {
            return
        }

        attachedWindowSnapshotTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else {
                    return
                }
                await refreshAttachedWindowSnapshots()
            }
        }
    }

    private func stopAttachedWindowSnapshotTask() {
        attachedWindowSnapshotTask?.cancel()
        attachedWindowSnapshotTask = nil
    }

    @MainActor
    private func refreshAttachedWindowSnapshots() async {
        guard !session.attachedWindows.isEmpty else {
            stopAttachedWindowSnapshotTask()
            return
        }

        let attachedWindows = session.attachedWindows
        let results = await Task.detached(priority: .utility) {
            let service = AccessibilityWindowService()
            return attachedWindows.map { attachedWindow -> AttachedWindowSnapshotResult in
                let origin = try? service.position(of: attachedWindow.window)
                let size = origin == nil ? nil : try? service.size(of: attachedWindow.window)
                let isMinimized = service.isMinimized(attachedWindow.window)
                return AttachedWindowSnapshotResult(
                    id: attachedWindow.id,
                    origin: origin,
                    size: size,
                    isMinimized: isMinimized
                )
            }
        }.value

        var didChange = false
        var sizeByAttachmentID: [AttachedWindow.ID: CGSize] = [:]

        for result in results {
            guard let index = session.attachedWindows.firstIndex(where: { $0.id == result.id }) else {
                continue
            }

            if let size = result.size {
                sizeByAttachmentID[result.id] = size
            }

            if result.isMinimized {
                minimizedAttachedWindowIDs.insert(result.id)
                clearAttachedWindowAccessFailure(for: result.id)
                markAttachedWindowAvailable(result.id)
                continue
            } else {
                minimizedAttachedWindowIDs.remove(result.id)
            }

            if let origin = result.origin {
                if !originsMatch(session.attachedWindows[index].lastWindowOrigin, origin) {
                    session.attachedWindows[index].lastWindowOrigin = origin
                    session.attachedWindows[index].lastAppliedOrigin = origin
                    session.attachedWindows[index].pendingReleaseOrigin = nil
                    didChange = true
                }
                clearAttachedWindowAccessFailure(for: result.id)
                markAttachedWindowAvailable(result.id)
            } else {
                if !isUnavailable(result.id) {
                    session.unavailableAttachedWindowIDs.insert(result.id)
                    didChange = true
                }
            }
        }

        if didChange {
            _ = session.persistActiveWorkspaceSnapshot(sizeByAttachmentID: sizeByAttachmentID)
        }
    }

    private func minimizeUnattachedWindows() {
        let recentWindows = lastExternalApplication.map { service.windows(for: $0) } ?? []
        session.minimizeUnattachedWindows(
            knownWindows: windows,
            recentWindows: recentWindows,
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

    private func minimizeUnattachedAfterWorkspaceSwitchIfNeeded() {
        guard shouldMinimizeUnattachedOnWorkspaceSwitch,
              !session.attachedWindows.isEmpty,
              session.attachedWindows.contains(where: { !isUnavailable($0.id) }),
              !session.isMinimizingUnattached,
              !session.isRestoringMinimized else {
            return
        }

        minimizeUnattachedWindows()
    }

    private func beginMinimizing(_ windowsToMinimize: [WindowInfo], attachedSnapshots: [AttachedWindowSnapshot]) {
        session.statusMessage = "Minimizing \(windowsToMinimize.count) unattached window(s)..."

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
                session.isMinimizingUnattached = false
                let minimizedIDs = Set(result.minimizedWindows.map(\.id))

                for window in result.minimizedWindows {
                    rememberMinimizedWindow(window)
                }

                windows.removeAll { minimizedIDs.contains($0.id) }
                if let selectedWindowID, minimizedIDs.contains(selectedWindowID) {
                    self.selectedWindowID = nil
                }

                session.statusMessage = minimizeStatus(
                    minimizedCount: result.minimizedWindows.count,
                    restoredAttachedCount: result.restoredAttachedWindows.count,
                    failedCount: result.failedCount
                )
            }
        }
    }

    private func restoreMinimizedWindows() {
        session.restoreMinimizedWindows { restoredWindows in
            appendRestoredWindows(restoredWindows)
        }
    }

    private func rememberMinimizedWindow(_ window: WindowInfo) {
        guard !session.minimizedWindows.contains(where: { $0.id == window.id }) else {
            return
        }

        session.minimizedWindows.append(window)
    }

    private func attachedWindowSnapshots() -> [AttachedWindowSnapshot] {
        session.attachedWindows.map { attachedWindow in
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
            session.statusMessage = "No available attached windows to bring to front."
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
                    session.statusMessage = "Brought \(frontingWindows.count) attached window(s) to front."
                }
                frontingTask = nil
            }
        }
    }

    private func bringBoardWindowToFront() {
        NSApp.activate(ignoringOtherApps: true)
        boardWindow?.makeKeyAndOrderFront(nil)
    }

    private func beginTemporaryBoardWorkspaceFronting() -> Int {
        workspaceFrontingRevision += 1
        let revision = workspaceFrontingRevision
        boardWindow?.level = .floating
        bringBoardWindowToFront()
        return revision
    }

    private func endTemporaryBoardWorkspaceFronting(revision: Int) {
        guard revision == workspaceFrontingRevision else {
            return
        }

        bringBoardWindowToFront()
        applyBoardWindowLevel()
    }

    private func applyBoardWindowLevel(to window: NSWindow? = nil) {
        let targetWindow = window ?? boardWindow
        targetWindow?.level = isBoardAlwaysOnTop ? .floating : .normal
    }

    private func configureBoardWindowTransparency(_ window: NSWindow) {
        window.isOpaque = false
        let baseBackgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.6)
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
              session.attachedWindows.contains(where: { !isUnavailable($0.id) }),
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
    }

    private func recoverAttachedWindow(_ attachedWindow: AttachedWindow) {
        let attachmentID = attachedWindow.id
        let originalWindow = attachedWindow.window
        let savedReference = attachedWindow.savedReference
        let shouldTryMinimizedRestore = isMinimized(attachmentID)

        guard !isReconnecting(attachmentID) || shouldTryMinimizedRestore else {
            return
        }

        if shouldTryMinimizedRestore {
            session.statusMessage = "Restoring \(originalWindow.appName)..."
        } else {
            session.reconnectingAttachedWindowIDs.insert(attachmentID)
            session.statusMessage = "Checking \(originalWindow.appName)..."
        }

        Task.detached(priority: .userInitiated) {
            let service = AccessibilityWindowService()
            if originalWindow.pid != 0, service.isMinimized(originalWindow) {
                do {
                    try service.setMinimized(false, for: originalWindow)
                    service.activateApplication(pid: originalWindow.pid)
                    try? await Task.sleep(for: .milliseconds(120))
                    let restoredPosition = try? service.position(of: originalWindow)

                    await MainActor.run {
                        guard let index = session.attachedWindows.firstIndex(where: { $0.id == attachmentID }) else {
                            return
                        }

                        let boardOrigin = boardMotion.currentOrigin ?? session.attachedWindows[index].lastBoardOrigin
                        let origin = restoredPosition ?? session.attachedWindows[index].lastWindowOrigin
                        session.attachedWindows[index].lastBoardOrigin = boardOrigin
                        session.attachedWindows[index].lastWindowOrigin = origin
                        session.attachedWindows[index].lastAppliedOrigin = origin
                        session.attachedWindows[index].pendingReleaseOrigin = nil
                        minimizedAttachedWindowIDs.remove(attachmentID)
                        clearAttachedWindowAccessFailure(for: attachmentID)
                        activePositionReadIDs.remove(attachmentID)
                        markAttachedWindowAvailable(attachmentID)
                        session.statusMessage = "Restored \(originalWindow.displayName)."
                    }
                    return
                } catch {
                    await MainActor.run {
                        session.reconnectingAttachedWindowIDs.insert(attachmentID)
                        session.statusMessage = "Checking \(originalWindow.appName)..."
                    }
                }
            }

            let livePosition: CGPoint?
            if originalWindow.pid == 0 {
                livePosition = nil
            } else {
                livePosition = try? service.position(of: originalWindow)
            }

            if let livePosition {
                service.activateApplication(pid: originalWindow.pid)

                await MainActor.run {
                    guard let index = session.attachedWindows.firstIndex(where: { $0.id == attachmentID }) else {
                        return
                    }

                    let boardOrigin = boardMotion.currentOrigin ?? session.attachedWindows[index].lastBoardOrigin
                    session.attachedWindows[index].lastBoardOrigin = boardOrigin
                    session.attachedWindows[index].lastWindowOrigin = livePosition
                    session.attachedWindows[index].lastAppliedOrigin = livePosition
                    session.attachedWindows[index].pendingReleaseOrigin = nil
                    clearAttachedWindowAccessFailure(for: attachmentID)
                    activePositionReadIDs.remove(attachmentID)
                    minimizedAttachedWindowIDs.remove(attachmentID)
                    markAttachedWindowAvailable(attachmentID)
                    session.statusMessage = "\(originalWindow.appName) is already connected."
                }
                return
            }

            if shouldTryMinimizedRestore {
                await MainActor.run {
                    minimizedAttachedWindowIDs.remove(attachmentID)
                    session.reconnectingAttachedWindowIDs.insert(attachmentID)
                    session.statusMessage = "Checking \(originalWindow.appName)..."
                }
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

            if let replacement, service.isMinimized(replacement) {
                try? service.setMinimized(false, for: replacement)
            }

            let resolvedReplacement = replacement
            let resolvedWindows = latestWindows
            let resolvedDidReopen = didReopen
            let resolvedDidRequestNewWindow = didRequestNewWindow
            let resolvedDidActivateApplication = didActivateApplication

            await MainActor.run {
                guard let index = session.attachedWindows.firstIndex(where: { $0.id == attachmentID }) else {
                    return
                }

                guard let replacement = resolvedReplacement else {
                    session.reconnectingAttachedWindowIDs.remove(attachmentID)
                    handleAttachedWindowAccessFailure(for: attachmentID, error: unavailableError)
                    session.statusMessage = resolvedDidRequestNewWindow
                        ? "Opened \(originalWindow.appName), but could not find a matching window to reconnect."
                        : resolvedDidReopen
                        ? "Opened \(originalWindow.appName), but could not find a matching window to reconnect."
                        : resolvedDidActivateApplication
                        ? "Activated \(originalWindow.appName), but could not reconnect a matching window."
                        : "Could not find a matching window to reconnect."
                    return
                }

                let boardOrigin = boardMotion.currentOrigin ?? session.attachedWindows[index].lastBoardOrigin
                let origin = replacement.position ?? session.attachedWindows[index].lastWindowOrigin
                session.attachedWindows[index].window = replacement
                session.attachedWindows[index].savedReference = savedReference
                session.attachedWindows[index].lastBoardOrigin = boardOrigin
                session.attachedWindows[index].lastWindowOrigin = origin
                session.attachedWindows[index].lastAppliedOrigin = origin
                session.attachedWindows[index].pendingReleaseOrigin = nil
                clearAttachedWindowAccessFailure(for: attachmentID)
                activePositionReadIDs.remove(attachmentID)
                minimizedAttachedWindowIDs.remove(attachmentID)
                markAttachedWindowAvailable(attachmentID)
                appendRestoredWindows(resolvedWindows)
                session.statusMessage = "Reconnected \(replacement.displayName)."
            }
        }
    }

    private func handleAttachedWindowAccessFailure(for id: AttachedWindow.ID, error: Error) {
        guard session.attachedWindows.contains(where: { $0.id == id }) else {
            return
        }

        let failureCount = (attachedWindowFailureCounts[id] ?? 0) + 1
        attachedWindowFailureCounts[id] = failureCount
        session.unavailableAttachedWindowIDs.insert(id)

        session.statusMessage = "Attached window is unavailable. Use Activate App or Detach."
    }

    private func detachWindow(id: AttachedWindow.ID, message: String? = nil) {
        session.detachWindow(id: id, boardOrigin: boardMotion.currentOrigin)
        clearAttachedWindowAccessFailure(for: id)
        activePositionReadIDs.remove(id)
        minimizedAttachedWindowIDs.remove(id)
        if session.attachedWindows.isEmpty {
            boardMotion.pendingReleaseOrigin = nil
            pendingAutoFront = false
        }
        if let message {
            session.statusMessage = message
        }
    }

    private func detachAll(message: String) {
        session.detachAll(boardOrigin: boardMotion.currentOrigin, message: message)
        frontingTask?.cancel()
        frontingTask = nil
        frontingRevision += 1
        attachedWindowFailureCounts.removeAll()
        activePositionReadIDs.removeAll()
        minimizedAttachedWindowIDs.removeAll()
        boardMotion.pendingReleaseOrigin = nil
        pendingAutoFront = false
    }
}
