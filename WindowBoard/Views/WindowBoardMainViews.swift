import AppKit
import SwiftUI

enum AttachedWindowDisplayState: Equatable {
    case available
    case resolving
    case minimized
    case unavailable
    case reconnecting

    var title: String {
        switch self {
        case .available:
            "Available"
        case .resolving:
            "Resolving"
        case .minimized:
            "Minimized"
        case .unavailable:
            "Unavailable"
        case .reconnecting:
            "Reconnecting"
        }
    }

    var systemImage: String {
        switch self {
        case .available:
            "checkmark.circle"
        case .resolving:
            "arrow.triangle.2.circlepath"
        case .minimized:
            "minus.square"
        case .unavailable:
            "exclamationmark.triangle"
        case .reconnecting:
            "arrow.triangle.2.circlepath"
        }
    }

    var needsAttention: Bool {
        switch self {
        case .available, .resolving:
            false
        case .minimized, .unavailable, .reconnecting:
            true
        }
    }

    var recoveryActionTitle: String? {
        switch self {
        case .available, .resolving:
            nil
        case .minimized:
            "Restore Window"
        case .unavailable:
            "Find or Reopen"
        case .reconnecting:
            "Finding..."
        }
    }
}

enum AttachedWindowRecoveryIssue: Equatable {
    case openedButNotMatched
    case activatedButNotMatched
    case couldNotOpen

    var detail: String {
        switch self {
        case .openedButNotMatched:
            "App opened, window not matched"
        case .activatedButNotMatched:
            "App active, window not matched"
        case .couldNotOpen:
            "Could not open app"
        }
    }

    var canUseFrontWindow: Bool {
        switch self {
        case .openedButNotMatched, .activatedButNotMatched:
            true
        case .couldNotOpen:
            false
        }
    }

    var failureMessage: String {
        switch self {
        case .openedButNotMatched:
            "App opened, but WindowBoard could not identify the saved window."
        case .activatedButNotMatched:
            "App is active, but WindowBoard could not identify the saved window."
        case .couldNotOpen:
            "Could not open app. Open it manually, then try again."
        }
    }
}

struct WorkspaceSidebarView: View {
    let workspaces: [SavedWorkspace]
    let activeWorkspaceID: SavedWorkspace.ID?
    let createWorkspace: () -> Void
    @Binding var selection: SavedWorkspace.ID?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    Text("Boards")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                        .padding(.top, 12)
                        .padding(.bottom, 4)

                    if workspaces.isEmpty {
                        Text("No Saved Boards")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                    } else {
                        ForEach(workspaces) { workspace in
                            Button {
                                selection = workspace.id
                            } label: {
                                WorkspaceSidebarRow(
                                    workspace: workspace,
                                    isSelected: workspace.id == selection,
                                    isActive: workspace.id == activeWorkspaceID
                                )
                            }
                            .buttonStyle(.plain)
                            .help(workspace.displayName)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 12)
            }

            Divider()

            Button(action: createWorkspace) {
                ViewThatFits(in: .horizontal) {
                    Label("New Board", systemImage: "plus")
                    Label("New", systemImage: "plus")
                    Image(systemName: "plus")
                }
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .help("New Board")
        }
        .navigationTitle("Window Board")
    }
}

private struct WorkspaceSidebarRow: View {
    let workspace: SavedWorkspace
    let isSelected: Bool
    let isActive: Bool

    var body: some View {
        HStack(spacing: 10) {
            statusItemGlyph
                .foregroundStyle(.secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(workspace.name)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text("\(workspace.windows.count) \(workspace.windows.count == 1 ? "window" : "windows")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

            if isActive {
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .selectedContentBackgroundColor).opacity(0.18))
            }
        }
    }

    @ViewBuilder
    private var statusItemGlyph: some View {
        if let title = WorkspaceStatusItemIcon.title(from: workspace.statusItemSymbolName) {
            Text(title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .truncationMode(.tail)
        } else {
            Image(systemName: workspace.statusItemSymbolName ?? WorkspaceStatusItemIcon.defaultSymbolName)
        }
    }
}

struct WorkspaceDetailView: View {
    let selectedWorkspace: SavedWorkspace?
    let selectedWindowID: WindowInfo.ID?
    let windows: [WindowInfo]
    let attachedWindows: [AttachedWindow]
    let statusMessage: String
    let isLoadingWindows: Bool
    let isLoadingWorkspace: Bool
    let isMinimizingUnattached: Bool
    let isRestoringMinimized: Bool
    let canAttachSelected: Bool
    let canAttachFrontmost: Bool
    let canSaveWorkspace: Bool
    let canOverwriteWorkspace: Bool
    let canEditWorkspaceName: Bool
    let canRenameWorkspace: Bool
    let canReloadWorkspace: Bool
    let canDeleteWorkspace: Bool
    let canUpdatePositions: Bool
    let canBringToFront: Bool
    let canMinimizeUnattached: Bool
    let canRestoreMinimized: Bool
    let canDetachAll: Bool
    let workspaceName: Binding<String>
    let selectedWindow: Binding<WindowInfo.ID?>
    let workspaceStatusText: Binding<String>
    let minimizeUnattachedOnSwitch: Binding<Bool>
    let restoreMissingWindowsOnSwitch: Binding<Bool>
    let boardAlwaysOnTop: Binding<Bool>
    let attachedState: (AttachedWindow) -> AttachedWindowDisplayState
    let recoveryIssue: (AttachedWindow.ID) -> AttachedWindowRecoveryIssue?
    let refreshWindows: () -> Void
    let attachSelected: () -> Void
    let attachFrontmost: () -> Void
    let attachFromAddCard: () -> Void
    let recentlyAddedWindowID: AttachedWindow.ID?
    let clearRecentlyAddedWindowID: () -> Void
    let workspaceTransitionToken: UUID?
    let detachingAttachedWindowIDs: Set<AttachedWindow.ID>
    let saveWorkspace: () -> Void
    let overwriteWorkspace: () -> Void
    let renameWorkspace: () -> Void
    let reloadWorkspace: () -> Void
    let deleteWorkspace: () -> Void
    let updateStatusItemIcon: (String) -> Void
    let updateStatusItemText: () -> Void
    let recoverAttached: (AttachedWindow) -> Void
    let useFrontWindowForAttached: (AttachedWindow) -> Void
    let updateAttached: (AttachedWindow.ID) -> Void
    let detachAttached: (AttachedWindow.ID) -> Void
    let bringForwardAttached: (AttachedWindow) -> Void
    let bringAndMoveAttachedBelowCard: (AttachedWindow, CGPoint) -> Void
    let isNeverMinimizedWindow: (WindowInfo) -> Bool
    let addNeverMinimizeWindow: (WindowInfo) -> Void
    let moveAttachedWindowToPermanentBoard: (AttachedWindow.ID) -> Void
    let rejectPermanentBoardDrop: () -> Void
    let movePermanentWindowToMainBoard: (NeverMinimizeWindow.ID) -> Void
    let rejectMainBoardDrop: () -> Void
    let neverMinimizeWindows: [NeverMinimizeWindow]
    let runningNeverMinimizeWindowCandidates: [WindowInfo]
    let addNeverMinimizeRunningWindow: (WindowInfo) -> Void
    let removeNeverMinimizeWindow: (NeverMinimizeWindow.ID) -> Void
    let recentlyAddedNeverMinimizeWindowID: NeverMinimizeWindow.ID?
    let clearRecentlyAddedNeverMinimizeWindowID: () -> Void
    let detachingNeverMinimizeWindowIDs: Set<NeverMinimizeWindow.ID>
    let liveNeverMinimizeWindow: (NeverMinimizeWindow) -> WindowInfo?
    let showNeverMinimizeWindow: (WindowInfo) -> Void
    let showAndMoveNeverMinimizeWindowBelowCard: (WindowInfo, CGPoint) -> Void
    let updatePositions: () -> Void
    let bringToFront: () -> Void
    let minimizeUnattached: () -> Void
    let restoreMinimized: () -> Void
    let detachAll: () -> Void
    @State private var isWorkspaceSettingsPresented = false

    var body: some View {
        VStack(spacing: 0) {
            BoardSummaryHeader(
                selectedWorkspace: selectedWorkspace,
                postingCount: attachedWindows.count,
                attentionCount: needsRecoveryPostings.count,
                symbolName: selectedWorkspace?.statusItemSymbolName,
                hasRecoverablePostings: hasRecoverablePostings,
                reloadWorkspace: reloadWorkspace,
                recoverMissing: recoverMissingPostings,
                showWorkspaceSettings: { isWorkspaceSettingsPresented = true },
                canReloadWorkspace: canReloadWorkspace
            )
            .popover(isPresented: $isWorkspaceSettingsPresented, arrowEdge: .bottom) {
                WorkspaceSettingsControls(
                    selectedWorkspace: selectedWorkspace,
                    workspaceName: workspaceName,
                    workspaceStatusText: workspaceStatusText,
                    minimizeUnattachedOnSwitch: minimizeUnattachedOnSwitch,
                    restoreMissingWindowsOnSwitch: restoreMissingWindowsOnSwitch,
                    boardAlwaysOnTop: boardAlwaysOnTop,
                    canSaveWorkspace: canSaveWorkspace,
                    canOverwriteWorkspace: canOverwriteWorkspace,
                    canEditWorkspaceName: canEditWorkspaceName,
                    canRenameWorkspace: canRenameWorkspace,
                    canDeleteWorkspace: canDeleteWorkspace,
                    canDetachAll: canDetachAll,
                    saveWorkspace: saveWorkspace,
                    overwriteWorkspace: overwriteWorkspace,
                    renameWorkspace: renameWorkspace,
                    deleteWorkspace: deleteWorkspace,
                    updateStatusItemIcon: updateStatusItemIcon,
                    updateStatusItemText: updateStatusItemText,
                    detachAll: detachAll
                )
                .padding(18)
                .frame(width: 420)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            .background {
                Color(nsColor: .windowBackgroundColor).opacity(0.22)
            }

            Divider()

            boardContent
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.clear)

            Divider()

            StatusFeedbackView(
                statusMessage: statusMessage,
                isLoadingWorkspace: isLoadingWorkspace,
                isMinimizingUnattached: isMinimizingUnattached,
                isRestoringMinimized: isRestoringMinimized
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background {
                Rectangle()
                    .fill(.thinMaterial)
                    .overlay(Color(nsColor: .windowBackgroundColor).opacity(0.08))
            }
        }
        .navigationTitle("")
    }

    private var boardContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                BoardContentSection(
                    title: "Main Board",
                    subtitle: "Only on this board"
                ) {
                    PinnedWindowCardGrid(
                        attachedWindows: attachedWindows,
                        stateForWindow: attachedState,
                        recoveryIssue: recoveryIssue,
                        canAttachFrontmost: canAttachFrontmost,
                        attachFrontmost: attachFrontmost,
                        attachFromAddCard: attachFromAddCard,
                        recentlyAddedWindowID: recentlyAddedWindowID,
                        clearRecentlyAddedWindowID: clearRecentlyAddedWindowID,
                        workspaceTransitionToken: workspaceTransitionToken,
                        detachingAttachedWindowIDs: detachingAttachedWindowIDs,
                        recover: recoverAttached,
                        useFrontWindow: useFrontWindowForAttached,
                        update: updateAttached,
                        detach: detachAttached,
                        bringForward: bringForwardAttached,
                        bringAndMoveBelowCard: bringAndMoveAttachedBelowCard,
                        isNeverMinimizedWindow: isNeverMinimizedWindow,
                        addNeverMinimizeWindow: addNeverMinimizeWindow,
                        movePermanentWindowToMainBoard: movePermanentWindowToMainBoard,
                        rejectDrop: rejectMainBoardDrop
                    )
                }

                Divider()
                    .padding(.vertical, 2)

                BoardContentSection(
                    title: "Permanent Board",
                    subtitle: "Included on every board"
                ) {
                    NeverMinimizeWindowsBoardControls(
                        windows: neverMinimizeWindows,
                        runningWindowCandidates: runningNeverMinimizeWindowCandidates,
                        addWindow: addNeverMinimizeRunningWindow,
                        removeWindow: removeNeverMinimizeWindow,
                        recentlyAddedWindowID: recentlyAddedNeverMinimizeWindowID,
                        clearRecentlyAddedWindowID: clearRecentlyAddedNeverMinimizeWindowID,
                        detachingWindowIDs: detachingNeverMinimizeWindowIDs,
                        liveWindow: liveNeverMinimizeWindow,
                        showWindow: showNeverMinimizeWindow,
                        showAndMoveBelowCard: showAndMoveNeverMinimizeWindowBelowCard,
                        moveAttachedWindow: moveAttachedWindowToPermanentBoard,
                        rejectDrop: rejectPermanentBoardDrop
                    )
                }
            }
            .padding(24)
            .frame(maxWidth: 1120, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var livePostings: [AttachedWindow] {
        attachedWindows.filter { attachedState($0) == .available }
    }

    private var minimizedPostings: [AttachedWindow] {
        attachedWindows.filter { attachedState($0) == .minimized }
    }

    private var missingPostings: [AttachedWindow] {
        attachedWindows.filter { attachedState($0) == .unavailable }
    }

    private var reconnectingPostings: [AttachedWindow] {
        attachedWindows.filter { attachedState($0) == .reconnecting }
    }

    private var needsRecoveryPostings: [AttachedWindow] {
        attachedWindows.filter { attachedState($0).needsAttention }
    }

    private var hasRecoverablePostings: Bool {
        needsRecoveryPostings.contains { attachedState($0).recoveryActionTitle != nil }
    }

    private func recoverMissingPostings() {
        for attachedWindow in needsRecoveryPostings where attachedState(attachedWindow) != .reconnecting {
            recoverAttached(attachedWindow)
        }
    }
}

private struct BoardContentSection<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            content
        }
    }
}

private struct NeverMinimizeWindowsBoardControls: View {
    let windows: [NeverMinimizeWindow]
    let runningWindowCandidates: [WindowInfo]
    let addWindow: (WindowInfo) -> Void
    let removeWindow: (NeverMinimizeWindow.ID) -> Void
    let recentlyAddedWindowID: NeverMinimizeWindow.ID?
    let clearRecentlyAddedWindowID: () -> Void
    let detachingWindowIDs: Set<NeverMinimizeWindow.ID>
    let liveWindow: (NeverMinimizeWindow) -> WindowInfo?
    let showWindow: (WindowInfo) -> Void
    let showAndMoveBelowCard: (WindowInfo, CGPoint) -> Void
    let moveAttachedWindow: (AttachedWindow.ID) -> Void
    let rejectDrop: () -> Void
    @State private var isDropTargeted = false

    private let columns = [
        GridItem(.adaptive(minimum: 200, maximum: 240), spacing: 18, alignment: .top)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if windows.isEmpty {
                Text("No windows added.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                ForEach(windows) { window in
                    let liveWindow = liveWindow(window)
                    let isPinningIn = window.id == recentlyAddedWindowID
                    let isDetaching = detachingWindowIDs.contains(window.id)
                    NeverMinimizeWindowCard(
                        window: window,
                        liveWindow: liveWindow,
                        isPinningIn: isPinningIn,
                        isDetaching: isDetaching,
                        onPinInComplete: isPinningIn ? clearRecentlyAddedWindowID : {},
                        showWindow: {
                            if let liveWindow {
                                showWindow(liveWindow)
                            }
                        },
                        showAndMoveBelowCard: { cursorScreenLocation in
                            if let liveWindow {
                                showAndMoveBelowCard(liveWindow, cursorScreenLocation)
                            }
                        },
                        remove: { removeWindow(window.id) },
                        dragPayload: liveWindow == nil ? nil : DragPayload.permanentBoardWindow(window.id)
                    )
                }

                NeverMinimizeAddRunningWindowCard(
                    windows: windows,
                    runningWindowCandidates: runningWindowCandidates,
                    addWindow: addWindow
                )
            }
            .animation(
                .spring(response: 0.32, dampingFraction: 0.88, blendDuration: 0.06),
                value: windows.map(\.id)
            )
        }
        .padding(.vertical, 2)
        .padding(8)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isDropTargeted ? Color.accentColor.opacity(0.10) : Color.clear)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(
                    isDropTargeted ? Color.accentColor.opacity(0.45) : Color.clear,
                    style: StrokeStyle(lineWidth: 1.2, dash: [6, 5])
                )
        }
        .dropDestination(for: String.self) { items, _ in
            handleDrop(items)
        } isTargeted: { isTargeted in
            isDropTargeted = isTargeted
        }
    }

    private func handleDrop(_ items: [String]) -> Bool {
        guard let item = items.first,
              let id = DragPayload.mainBoardWindowID(from: item) else {
            rejectDrop()
            return false
        }

        moveAttachedWindow(id)
        return true
    }
}

private struct NeverMinimizeWindowCard: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPrimaryActionPressed = false
    @State private var isPrimaryActionPopping = false

    let window: NeverMinimizeWindow
    let liveWindow: WindowInfo?
    let isPinningIn: Bool
    let isDetaching: Bool
    let onPinInComplete: () -> Void
    let showWindow: () -> Void
    let showAndMoveBelowCard: (CGPoint) -> Void
    let remove: () -> Void
    let dragPayload: String?

    private let baseCardSize = CGSize(width: 220, height: 308)

    var body: some View {
        GeometryReader { proxy in
            let scale = proxy.size.width / baseCardSize.width

            cardContent
                .frame(width: baseCardSize.width, height: baseCardSize.height)
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                .clipped()
        }
        .aspectRatio(baseCardSize.width / baseCardSize.height, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .background(cardBackground)
        .overlay(cardSurfaceOverlay)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 11, y: 4)
        .shadow(color: .black.opacity(0.08), radius: 24, y: 11)
        .shadow(color: appAccentColor.opacity(0.12), radius: 20, y: 9)
        .scaleEffect(primaryActionCardScale)
        .animation(.spring(response: 0.20, dampingFraction: 0.82), value: primaryActionCardScale)
        .interactiveCardMotion(
            isEnabled: !isPinningIn && !isDetaching,
            highlightOpacity: 0.12
        )
        .cardPinIn(
            isActive: isPinningIn && !isDetaching,
            onComplete: onPinInComplete
        )
        .cardDetachExit(isActive: isDetaching)
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(window.appName)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 8)

                CardDragHandle(payload: dragPayload)

                actionsMenu
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 6)

            iconField
                .padding(.horizontal, 16)

            Divider()
                .padding(.horizontal, 16)
                .padding(.top, 8)

            VStack(alignment: .leading, spacing: 6) {
                Text(windowTitle)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .frame(minHeight: 30, alignment: .topLeading)

                neverMinimizedBadge

                Text("Included on every board")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer(minLength: 0)

                Button("Remove", action: remove)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
                    .minimumScaleFactor(0.82)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 12)
        }
    }

    private var iconField: some View {
        IconPrimaryActionField(
            appName: window.appName,
            bundleURL: nil,
            bundleIdentifier: window.bundleIdentifier,
            state: liveWindow == nil ? .unavailable : .available,
            background: iconFieldBackground,
            strokeColor: liveWindow == nil ? Color(nsColor: .separatorColor).opacity(0.42) : appAccentColor.opacity(0.32),
            isEnabled: liveWindow != nil,
            actionTitle: liveWindow == nil ? "Window unavailable" : "Show Window",
            accessibilityLabel: liveWindow == nil ? "Window unavailable" : "Show \(window.appName) window",
            doubleClickAction: showAndMoveBelowCard,
            onPressChanged: { isPrimaryActionPressed = $0 },
            onActionFeedback: runPrimaryActionFeedback,
            action: showWindow
        )
    }

    private var actionsMenu: some View {
        Menu {
            Button("Show Window", action: showWindow)
                .disabled(liveWindow == nil)
            Button("Remove", action: remove)
        } label: {
            Image(systemName: "ellipsis")
                .font(.body.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 22)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help("More window actions")
    }

    private var neverMinimizedBadge: some View {
        Label("Permanent", systemImage: "checkmark.circle")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(.quaternary)
            .clipShape(Capsule())
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(appAccentColor.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                .white.opacity(0.22),
                                .white.opacity(0.04),
                                .black.opacity(0.035)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            )
    }

    private var cardSurfaceOverlay: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(appAccentColor.opacity(0.42), lineWidth: 0.8)

            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .inset(by: 0.7)
                .stroke(.white.opacity(0.30), lineWidth: 1)
                .blendMode(.plusLighter)

            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .inset(by: 1.2)
                .stroke(.black.opacity(0.035), lineWidth: 1)
        }
    }

    private var iconFieldBackground: LinearGradient {
        LinearGradient(
            colors: [
                appAccentColor.opacity(0.26),
                appAccentColor.opacity(0.22),
                appAccentColor.opacity(0.18)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var appAccentColor: Color {
        Color(nsColor: AppIconPalette.accentColor(
            appName: window.appName,
            bundleURL: nil,
            bundleIdentifier: window.bundleIdentifier
        ))
    }

    private var primaryActionCardScale: CGFloat {
        if reduceMotion {
            1
        } else if isPrimaryActionPressed {
            0.992
        } else if isPrimaryActionPopping {
            1.012
        } else {
            1
        }
    }

    private var windowTitle: String {
        let title = window.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "No window title" : title
    }

    private func runPrimaryActionFeedback() {
        guard liveWindow != nil, !reduceMotion else { return }

        isPrimaryActionPopping = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(115))
            withAnimation(.spring(response: 0.24, dampingFraction: 0.82)) {
                isPrimaryActionPopping = false
            }
        }
    }
}

private struct NeverMinimizeAddRunningWindowCard: View {
    let windows: [NeverMinimizeWindow]
    let runningWindowCandidates: [WindowInfo]
    let addWindow: (WindowInfo) -> Void

    private let baseCardSize = CGSize(width: 220, height: 308)

    var body: some View {
        Menu {
            if runningWindowCandidates.isEmpty {
                Button("No running windows available") {}
                    .disabled(true)
            } else {
                ForEach(runningWindowCandidates) { window in
                    let alreadyAdded = windows.contains { $0.matches(window) }
                    Button(alreadyAdded ? "\(window.displayName) (Added)" : window.displayName) {
                        addWindow(window)
                    }
                    .disabled(alreadyAdded)
                }
            }
        } label: {
            GeometryReader { proxy in
                let scale = proxy.size.width / baseCardSize.width

                addCardContent
                    .frame(width: baseCardSize.width, height: baseCardSize.height)
                    .scaleEffect(scale, anchor: .topLeading)
                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            }
            .aspectRatio(baseCardSize.width / baseCardSize.height, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        .white.opacity(0.18),
                                        .white.opacity(0.04),
                                        .black.opacity(0.025)
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                    )
            }
            .overlay(addCardSurfaceOverlay)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: .black.opacity(0.10), radius: 10, y: 3)
            .shadow(color: .black.opacity(0.08), radius: 22, y: 10)
            .interactiveCardMotion(highlightOpacity: 0.10)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help("Add to Permanent Board")
    }

    private var addCardContent: some View {
        VStack(spacing: 12) {
            Image(systemName: "plus")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 58, height: 58)
                .background {
                    Circle()
                        .fill(Color(nsColor: .windowBackgroundColor).opacity(0.36))
                        .overlay(
                            Circle()
                                .stroke(.white.opacity(0.24), lineWidth: 1)
                        )
                }
                .shadow(color: .black.opacity(0.12), radius: 9, y: 4)

            Text("Add to Permanent Board")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Text("Choose a running window to include on every board.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .padding(.horizontal, 18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var addCardSurfaceOverlay: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(
                    Color(nsColor: .separatorColor).opacity(0.46),
                    style: StrokeStyle(lineWidth: 1, dash: [7, 6])
                )

            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .inset(by: 0.7)
                .stroke(.white.opacity(0.24), lineWidth: 1)
                .blendMode(.plusLighter)

            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .inset(by: 1.2)
                .stroke(.black.opacity(0.025), lineWidth: 1)
        }
    }
}

struct WindowSelectionView: View {
    let windows: [WindowInfo]
    @Binding var selection: WindowInfo.ID?
    let isLoading: Bool
    let canAttachSelected: Bool
    let canAttachFrontmost: Bool
    let refreshWindows: () -> Void
    let attachSelected: () -> Void
    let attachFrontmost: () -> Void

    var body: some View {
        if isLoading {
            ProgressView("Loading windows...")
        } else {
            Picker("Window", selection: $selection) {
                Text("Choose a window").tag(WindowInfo.ID?.none)
                ForEach(windows) { window in
                    Text(window.displayName).tag(WindowInfo.ID?.some(window.id))
                }
            }
        }

        ViewThatFits(in: .horizontal) {
            HStack {
                windowActionButtons
                Spacer()
            }

            VStack(alignment: .leading, spacing: 8) {
                windowActionButtons
            }
        }
    }

    @ViewBuilder
    private var windowActionButtons: some View {
        Button("Refresh", action: refreshWindows)
            .disabled(isLoading)
        Button("Attach Selected", action: attachSelected)
            .disabled(!canAttachSelected)
        Button("Attach Window", action: attachFrontmost)
            .disabled(!canAttachFrontmost)
    }
}

private struct BoardSummaryHeader: View {
    let selectedWorkspace: SavedWorkspace?
    let postingCount: Int
    let attentionCount: Int
    let symbolName: String?
    let hasRecoverablePostings: Bool
    let reloadWorkspace: () -> Void
    let recoverMissing: () -> Void
    let showWorkspaceSettings: () -> Void
    let canReloadWorkspace: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            StatusItemPreview(symbolName: symbolName)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(.quaternary)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(selectedWorkspace?.name ?? "No Board Selected")
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)

                Text(summaryText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            ViewThatFits(in: .horizontal) {
                HStack {
                    Button {
                        recoverMissing()
                    } label: {
                        Label("Recover Missing", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(!hasRecoverablePostings)

                    Button {
                        reloadWorkspace()
                    } label: {
                        Label("Restore Layout", systemImage: "arrow.counterclockwise")
                    }
                    .disabled(!canReloadWorkspace)

                    Button {
                        showWorkspaceSettings()
                    } label: {
                        Label("Board Settings", systemImage: "slider.horizontal.3")
                    }
                }

                HStack {
                    Button {
                        recoverMissing()
                    } label: {
                        Label("Recover Missing", systemImage: "arrow.triangle.2.circlepath")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(!hasRecoverablePostings)
                    .help("Recover Missing")

                    Button {
                        reloadWorkspace()
                    } label: {
                        Label("Restore Layout", systemImage: "arrow.counterclockwise")
                            .labelStyle(.iconOnly)
                    }
                    .disabled(!canReloadWorkspace)
                    .help("Restore Layout")

                    Button {
                        showWorkspaceSettings()
                    } label: {
                        Label("Board Settings", systemImage: "slider.horizontal.3")
                            .labelStyle(.iconOnly)
                    }
                    .help("Board Settings")
                }
            }
        }
    }

    private var summaryText: String {
        let countText = "\(postingCount) pinned"
        let attentionText = attentionCount > 0 ? " · \(attentionCount) need attention" : ""
        guard let updatedAt = selectedWorkspace?.updatedAt else {
            return "\(countText)\(attentionText)"
        }

        return "\(countText)\(attentionText) · saved \(updatedAt.formatted(date: .omitted, time: .shortened))"
    }
}

private struct RecoveryOverviewBar: View {
    let liveCount: Int
    let minimizedCount: Int
    let missingCount: Int
    let reconnectingCount: Int

    var body: some View {
        HStack(spacing: 8) {
            OverviewChip(title: "\(liveCount) live", systemImage: "checkmark.circle.fill", tint: .green)
            OverviewChip(title: "\(minimizedCount) minimized", systemImage: "minus.square.fill", tint: .orange)
            OverviewChip(title: "\(missingCount) missing", systemImage: "exclamationmark.triangle.fill", tint: .red)

            if reconnectingCount > 0 {
                OverviewChip(title: "\(reconnectingCount) finding", systemImage: "arrow.triangle.2.circlepath", tint: .blue)
            }

            Spacer()
        }
    }
}

private struct OverviewChip: View {
    let title: String
    let systemImage: String
    let tint: Color

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tint.opacity(0.11))
            .clipShape(Capsule())
    }
}

private struct BoardSectionHeader: View {
    let title: String
    let count: Int
    let systemImage: String

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
                .font(.caption)

            Text(title)
                .font(.subheadline.weight(.semibold))

            Text("\(count)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.quaternary)
                .clipShape(Capsule())

            Spacer()
        }
        .foregroundStyle(.secondary)
    }
}

private struct BoardInspectorPanel: View {
    let selectedWorkspace: SavedWorkspace?
    let attachedWindows: [AttachedWindow]
    let liveCount: Int
    let minimizedCount: Int
    let missingCount: Int
    let reconnectingCount: Int
    let recoverMissing: () -> Void
    let restoreSnapshot: () -> Void
    let canRecoverMissing: Bool
    let canRestoreSnapshot: Bool
    let canAttachFrontmost: Bool
    let attachFrontmost: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            inspectorHeader

            InspectorSection(title: "Board State") {
                InspectorValueRow(title: "Pinned", value: "\(attachedWindows.count)")
                InspectorValueRow(title: "Live", value: "\(liveCount)")
                InspectorValueRow(title: "Minimized", value: "\(minimizedCount)")
                InspectorValueRow(title: "Missing", value: "\(missingCount)")
                if reconnectingCount > 0 {
                    InspectorValueRow(title: "Finding", value: "\(reconnectingCount)")
                }
            }

            InspectorSection(title: "Snapshot") {
                InspectorValueRow(title: "Saved Windows", value: "\(selectedWorkspace?.windows.count ?? 0)")
                InspectorValueRow(title: "Last Saved", value: snapshotTime)
            }

            VStack(spacing: 8) {
                Button {
                    attachFrontmost()
                } label: {
                    Label("Pin Frontmost Window", systemImage: "plus.rectangle.on.rectangle")
                        .frame(maxWidth: .infinity)
                }
                .disabled(!canAttachFrontmost)

                Button {
                    recoverMissing()
                } label: {
                    Label("Recover Missing", systemImage: "arrow.triangle.2.circlepath")
                        .frame(maxWidth: .infinity)
                }
                .disabled(!canRecoverMissing)

                Button {
                    restoreSnapshot()
                } label: {
                    Label("Restore Snapshot", systemImage: "arrow.counterclockwise")
                        .frame(maxWidth: .infinity)
                }
                .disabled(!canRestoreSnapshot)
            }
            .buttonStyle(.bordered)

            Spacer()
        }
        .padding(18)
        .frame(width: 270)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.bar)
    }

    private var inspectorHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(selectedWorkspace?.name ?? "Board", systemImage: "rectangle.on.rectangle")
                .font(.headline)
                .lineLimit(2)

            Text("\(attachedWindows.count) pinned \(attachedWindows.count == 1 ? "window" : "windows")")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var snapshotTime: String {
        guard let updatedAt = selectedWorkspace?.updatedAt else {
            return "Never"
        }

        return updatedAt.formatted(date: .omitted, time: .shortened)
    }
}

private struct InspectorSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            VStack(spacing: 0) {
                content
            }
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
    }
}

private struct InspectorValueRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)

            Spacer()

            Text(value)
                .monospacedDigit()
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

private struct PinnedWindowCardGrid: View {
    let attachedWindows: [AttachedWindow]
    let stateForWindow: (AttachedWindow) -> AttachedWindowDisplayState
    let recoveryIssue: (AttachedWindow.ID) -> AttachedWindowRecoveryIssue?
    let canAttachFrontmost: Bool
    let attachFrontmost: () -> Void
    let attachFromAddCard: () -> Void
    let recentlyAddedWindowID: AttachedWindow.ID?
    let clearRecentlyAddedWindowID: () -> Void
    let workspaceTransitionToken: UUID?
    let detachingAttachedWindowIDs: Set<AttachedWindow.ID>
    let recover: (AttachedWindow) -> Void
    let useFrontWindow: (AttachedWindow) -> Void
    let update: (AttachedWindow.ID) -> Void
    let detach: (AttachedWindow.ID) -> Void
    let bringForward: (AttachedWindow) -> Void
    let bringAndMoveBelowCard: (AttachedWindow, CGPoint) -> Void
    let isNeverMinimizedWindow: (WindowInfo) -> Bool
    let addNeverMinimizeWindow: (WindowInfo) -> Void
    let movePermanentWindowToMainBoard: (NeverMinimizeWindow.ID) -> Void
    let rejectDrop: () -> Void
    @State private var isDropTargeted = false

    private let columns = [
        GridItem(.adaptive(minimum: 200, maximum: 240), spacing: 18, alignment: .top)
    ]

    var body: some View {
        let entranceToken = shouldAnimateWorkspaceEntrance ? workspaceTransitionToken : nil

        LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
            if attachedWindows.isEmpty {
                AddPinnedWindowCard(
                    canAttachFrontmost: canAttachFrontmost,
                    attachFrontmost: attachFromAddCard,
                    isEmptyState: true,
                    appearanceGeneration: attachedWindows.count,
                    workspaceTransitionToken: entranceToken,
                    workspaceTransitionIndex: 0
                )
            } else {
                ForEach(Array(attachedWindows.enumerated()), id: \.element.id) { index, attachedWindow in
                    let isPinningIn = attachedWindow.id == recentlyAddedWindowID
                    let isDetaching = detachingAttachedWindowIDs.contains(attachedWindow.id)
                    let state = stateForWindow(attachedWindow)
                    let canDragToPermanentBoard = attachedWindow.window.pid != 0
                        && !isDetaching
                        && state == .available
                    PinnedWindowCard(
                        attachedWindow: attachedWindow,
                        state: state,
                        recoveryIssue: recoveryIssue(attachedWindow.id),
                        isPinningIn: isPinningIn,
                        isDetaching: isDetaching,
                        workspaceTransitionToken: entranceToken,
                        workspaceTransitionIndex: index,
                        onPinInComplete: isPinningIn ? clearRecentlyAddedWindowID : {},
                        bringForward: { bringForward(attachedWindow) },
                        recover: { recover(attachedWindow) },
                        useFrontWindow: { useFrontWindow(attachedWindow) },
                        update: { update(attachedWindow.id) },
                        detach: { detach(attachedWindow.id) },
                        isNeverMinimizedWindow: isNeverMinimizedWindow(attachedWindow.window),
                        addNeverMinimizeWindow: { addNeverMinimizeWindow(attachedWindow.window) },
                        dragPayload: canDragToPermanentBoard ? DragPayload.mainBoardWindow(attachedWindow.id) : nil,
                        bringAndMoveBelowCard: { cursorScreenLocation in
                            bringAndMoveBelowCard(attachedWindow, cursorScreenLocation)
                        }
                    )
                }

                AddPinnedWindowCard(
                    canAttachFrontmost: canAttachFrontmost,
                    attachFrontmost: attachFromAddCard,
                    isEmptyState: false,
                    appearanceGeneration: attachedWindows.count,
                    workspaceTransitionToken: entranceToken,
                    workspaceTransitionIndex: attachedWindows.count
                )
            }
        }
        .animation(
            .spring(response: 0.32, dampingFraction: 0.88, blendDuration: 0.06),
            value: attachedWindows.map(\.id)
        )
        .padding(8)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isDropTargeted ? Color.accentColor.opacity(0.10) : Color.clear)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(
                    isDropTargeted ? Color.accentColor.opacity(0.45) : Color.clear,
                    style: StrokeStyle(lineWidth: 1.2, dash: [6, 5])
                )
        }
        .dropDestination(for: String.self) { items, _ in
            handleDrop(items)
        } isTargeted: { isTargeted in
            isDropTargeted = isTargeted
        }
    }

    private var shouldAnimateWorkspaceEntrance: Bool {
        attachedWindows.count < 4
    }

    private func handleDrop(_ items: [String]) -> Bool {
        guard let item = items.first,
              let id = DragPayload.permanentBoardWindowID(from: item) else {
            rejectDrop()
            return false
        }

        movePermanentWindowToMainBoard(id)
        return true
    }
}

private extension View {
    func interactiveCardMotion(
        cornerRadius: CGFloat = 16,
        isEnabled: Bool = true,
        highlightOpacity: Double = 0.12
    ) -> some View {
        modifier(
            InteractiveCardMotion(
                cornerRadius: cornerRadius,
                isEnabled: isEnabled,
                highlightOpacity: highlightOpacity
            )
        )
    }

    func cardPinIn(
        isActive: Bool,
        onComplete: @escaping () -> Void
    ) -> some View {
        modifier(CardPinInModifier(isActive: isActive, onComplete: onComplete))
    }

    func workspaceCardEntrance(
        token: UUID?,
        index: Int,
        isEnabled: Bool = true
    ) -> some View {
        modifier(
            WorkspaceCardEntranceModifier(
                token: token,
                index: index,
                isEnabled: isEnabled
            )
        )
    }

    func cardDetachExit(isActive: Bool) -> some View {
        modifier(CardDetachExitModifier(isActive: isActive))
    }

}

private enum DragPayload {
    private static let mainPrefix = "main:"
    private static let permanentPrefix = "permanent:"

    static func mainBoardWindow(_ id: AttachedWindow.ID) -> String {
        "\(mainPrefix)\(id.uuidString)"
    }

    static func permanentBoardWindow(_ id: NeverMinimizeWindow.ID) -> String {
        "\(permanentPrefix)\(id)"
    }

    static func mainBoardWindowID(from payload: String) -> AttachedWindow.ID? {
        guard payload.hasPrefix(mainPrefix) else {
            return nil
        }

        return UUID(uuidString: String(payload.dropFirst(mainPrefix.count)))
    }

    static func permanentBoardWindowID(from payload: String) -> NeverMinimizeWindow.ID? {
        guard payload.hasPrefix(permanentPrefix) else {
            return nil
        }

        return String(payload.dropFirst(permanentPrefix.count))
    }
}

private struct CardDragHandle: View {
    let payload: String?

    var body: some View {
        if let payload {
            Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
                .draggable(payload)
                .help("Drag to move between boards")
                .accessibilityLabel("Drag to move between boards")
        }
    }
}

private struct CardDetachExitModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let isActive: Bool

    func body(content: Content) -> some View {
        content
            .opacity(isActive ? 0 : 1)
            .scaleEffect(reduceMotion || !isActive ? 1 : 0.96)
            .offset(y: reduceMotion || !isActive ? 0 : -8)
            .rotationEffect(.degrees(reduceMotion || !isActive ? 0 : -1.5))
            .animation(.easeInOut(duration: reduceMotion ? 0.16 : 0.24), value: isActive)
            .allowsHitTesting(!isActive)
            .accessibilityHidden(isActive)
    }
}

private struct WorkspaceCardEntranceModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visible = true
    @State private var lastToken: UUID?

    let token: UUID?
    let index: Int
    let isEnabled: Bool

    private var delayNanoseconds: UInt64 {
        UInt64(min(Double(index) * 0.035, 0.18) * 1_000_000_000)
    }

    private var entranceAnimation: Animation {
        if reduceMotion {
            return .easeOut(duration: 0.16)
        }

        return .spring(response: 0.34, dampingFraction: 0.86, blendDuration: 0.06)
    }

    func body(content: Content) -> some View {
        content
            .opacity(visible ? 1 : 0)
            .scaleEffect(reduceMotion || visible ? 1 : 0.985)
            .offset(y: reduceMotion || visible ? 0 : 10)
            .onAppear {
                let shouldRunInitialEntrance = lastToken == nil && token != nil
                lastToken = token
                if shouldRunInitialEntrance {
                    scheduleEntrance()
                }
            }
            .onChange(of: token) { _, newToken in
                runEntranceIfNeeded(for: newToken)
            }
    }

    private func runEntranceIfNeeded(for newToken: UUID?) {
        guard isEnabled,
              let newToken,
              newToken != lastToken else {
            lastToken = newToken
            return
        }

        lastToken = newToken
        scheduleEntrance()
    }

    private func scheduleEntrance() {
        guard isEnabled else {
            visible = true
            return
        }

        visible = false

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            withAnimation(entranceAnimation) {
                visible = true
            }
        }
    }
}

private struct CardPinInModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visible = true
    @State private var hasAnimated = false

    let isActive: Bool
    let onComplete: () -> Void

    func body(content: Content) -> some View {
        let shouldShowStartState = isActive && !hasAnimated
        let isVisible = shouldShowStartState ? false : visible

        content
            .opacity(isVisible ? 1 : 0)
            .scaleEffect(reduceMotion || isVisible ? 1 : 0.96)
            .offset(y: reduceMotion || isVisible ? 0 : -8)
            .rotationEffect(.degrees(reduceMotion || isVisible ? 0 : 1.5))
            .onAppear(perform: startIfNeeded)
            .onChange(of: isActive) { _, _ in
                startIfNeeded()
            }
    }

    private func startIfNeeded() {
        guard isActive, !hasAnimated else {
            return
        }

        hasAnimated = true
        visible = false

        Task { @MainActor in
            await Task.yield()
            withAnimation(pinAnimation) {
                visible = true
            }
            try? await Task.sleep(for: .milliseconds(reduceMotion ? 180 : 520))
            onComplete()
        }
    }

    private var pinAnimation: Animation {
        if reduceMotion {
            .easeOut(duration: 0.16)
        } else {
            .spring(response: 0.30, dampingFraction: 0.86, blendDuration: 0.06)
        }
    }
}

private struct InteractiveCardMotion: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var normalizedHover: CGPoint = .zero
    @State private var isHovering = false
    @State private var cardSize: CGSize = .zero

    let cornerRadius: CGFloat
    let isEnabled: Bool
    let highlightOpacity: Double

    private let maxTiltDegrees: CGFloat = 5
    private let spring = Animation.interactiveSpring(
        response: 0.28,
        dampingFraction: 0.82,
        blendDuration: 0.08
    )

    private var motionEnabled: Bool {
        isEnabled && !reduceMotion
    }

    private var x: CGFloat {
        motionEnabled ? normalizedHover.x : 0
    }

    private var y: CGFloat {
        motionEnabled ? normalizedHover.y : 0
    }

    private var hoverScale: CGFloat {
        motionEnabled && isHovering ? 1.018 : 1
    }

    func body(content: Content) -> some View {
        content
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .onAppear {
                            cardSize = proxy.size
                        }
                        .onChange(of: proxy.size) { _, newSize in
                            cardSize = newSize
                        }
                }
            }
            .overlay {
                specularHighlight
                    .allowsHitTesting(false)
            }
            .scaleEffect(hoverScale)
            .rotation3DEffect(
                .degrees(-y * maxTiltDegrees),
                axis: (x: 1, y: 0, z: 0),
                perspective: 0.55
            )
            .rotation3DEffect(
                .degrees(x * maxTiltDegrees),
                axis: (x: 0, y: 1, z: 0),
                perspective: 0.55
            )
            .shadow(
                color: .black.opacity(motionEnabled && isHovering ? 0.12 : 0.04),
                radius: motionEnabled && isHovering ? 18 : 8,
                x: x * 7,
                y: y * 7 + (motionEnabled && isHovering ? 10 : 5)
            )
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .onContinuousHover { phase in
                guard isEnabled else { return }

                switch phase {
                case .active(let location):
                    updateHover(at: location)
                case .ended:
                    resetHover()
                }
            }
    }

    private var specularHighlight: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            let activeOpacity = motionEnabled && isHovering ? highlightOpacity : 0

            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0.28),
                            .init(color: .white.opacity(0.48), location: 0.48),
                            .init(color: .clear, location: 0.68)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: width * 0.76, height: height * 1.45)
                .rotationEffect(.degrees(18))
                .offset(
                    x: width * 0.12 + x * width * 0.22,
                    y: -height * 0.28 + y * height * 0.16
                )
                .opacity(activeOpacity)
                .blur(radius: 0.35)
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    private func updateHover(at location: CGPoint) {
        guard cardSize.width > 0, cardSize.height > 0 else { return }

        let normalizedX = ((location.x / cardSize.width) - 0.5) * 2
        let normalizedY = ((location.y / cardSize.height) - 0.5) * 2
        let clamped = CGPoint(
            x: min(max(normalizedX, -1), 1),
            y: min(max(normalizedY, -1), 1)
        )

        withAnimation(spring) {
            isHovering = true
            normalizedHover = clamped
        }
    }

    private func resetHover() {
        withAnimation(spring) {
            isHovering = false
            normalizedHover = .zero
        }
    }
}

private struct AddPinnedWindowCard: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let canAttachFrontmost: Bool
    let attachFrontmost: () -> Void
    let isEmptyState: Bool
    let appearanceGeneration: Int
    let workspaceTransitionToken: UUID?
    let workspaceTransitionIndex: Int
    @State private var isPresenting = true
    @State private var lastAppearanceGeneration = 0

    private let baseCardSize = CGSize(width: 220, height: 308)
    private var presentationOpacity: Double {
        (canAttachFrontmost ? 1 : 0.55) * (isPresenting ? 1 : 0)
    }

    var body: some View {
        GeometryReader { proxy in
            let scale = proxy.size.width / baseCardSize.width

            Button(action: attachFrontmost) {
                addCardContent
                    .frame(width: baseCardSize.width, height: baseCardSize.height)
                    .scaleEffect(scale, anchor: .topLeading)
                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            }
            .buttonStyle(.plain)
            .disabled(!canAttachFrontmost)
        }
        .aspectRatio(baseCardSize.width / baseCardSize.height, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    .white.opacity(0.18),
                                    .white.opacity(0.04),
                                    .black.opacity(0.025)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                )
        }
        .overlay(addCardSurfaceOverlay)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.10), radius: 10, y: 3)
        .shadow(color: .black.opacity(0.08), radius: 22, y: 10)
        .opacity(presentationOpacity)
        .scaleEffect(reduceMotion || isPresenting ? 1 : 0.96)
        .offset(y: reduceMotion || isPresenting ? 0 : 8)
        .interactiveCardMotion(
            isEnabled: canAttachFrontmost,
            highlightOpacity: 0.10
        )
        .workspaceCardEntrance(
            token: workspaceTransitionToken,
            index: workspaceTransitionIndex
        )
        .onAppear {
            lastAppearanceGeneration = appearanceGeneration
            if !isEmptyState, appearanceGeneration > 0 {
                isPresenting = false
                presentAfterDelay(milliseconds: 150)
            } else {
                isPresenting = true
            }
        }
        .onChange(of: appearanceGeneration) { _, newGeneration in
            animateNewAddCardIfNeeded(newGeneration)
        }
    }

    private func animateNewAddCardIfNeeded(_ newGeneration: Int) {
        guard newGeneration > lastAppearanceGeneration else {
            lastAppearanceGeneration = newGeneration
            return
        }

        lastAppearanceGeneration = newGeneration
        isPresenting = false
        presentAfterDelay(milliseconds: 150)
    }

    private func presentAfterDelay(milliseconds: UInt64) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(milliseconds))
            withAnimation(.easeOut(duration: 0.24)) {
                isPresenting = true
            }
        }
    }

    private var addCardContent: some View {
        VStack(spacing: 12) {
            Image(systemName: "plus")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 58, height: 58)
                .background {
                    Circle()
                        .fill(Color(nsColor: .windowBackgroundColor).opacity(0.36))
                        .overlay(
                            Circle()
                                .stroke(.white.opacity(0.24), lineWidth: 1)
                        )
                }
                .shadow(color: .black.opacity(0.12), radius: 9, y: 4)

            Text(isEmptyState ? "Pin Frontmost Window" : "Add Window")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if isEmptyState {
                Text("Attach the frontmost app window to make it part of this board.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var addCardSurfaceOverlay: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(
                    Color(nsColor: .separatorColor).opacity(0.46),
                    style: StrokeStyle(lineWidth: 1, dash: [7, 6])
                )

            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .inset(by: 0.7)
                .stroke(.white.opacity(0.24), lineWidth: 1)
                .blendMode(.plusLighter)

            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .inset(by: 1.2)
                .stroke(.black.opacity(0.025), lineWidth: 1)
        }
    }
}

private struct PinnedWindowCard: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPrimaryActionPressed = false
    @State private var isPrimaryActionPopping = false

    let attachedWindow: AttachedWindow
    let state: AttachedWindowDisplayState
    let recoveryIssue: AttachedWindowRecoveryIssue?
    let isPinningIn: Bool
    let isDetaching: Bool
    let workspaceTransitionToken: UUID?
    let workspaceTransitionIndex: Int
    let onPinInComplete: () -> Void
    let bringForward: () -> Void
    let recover: () -> Void
    let useFrontWindow: () -> Void
    let update: () -> Void
    let detach: () -> Void
    let isNeverMinimizedWindow: Bool
    let addNeverMinimizeWindow: () -> Void
    let dragPayload: String?
    let bringAndMoveBelowCard: (CGPoint) -> Void

    private let baseCardSize = CGSize(width: 220, height: 308)

    var body: some View {
        GeometryReader { proxy in
            let scale = proxy.size.width / baseCardSize.width

            cardContent
                .frame(width: baseCardSize.width, height: baseCardSize.height)
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                .clipped()
        }
        .aspectRatio(baseCardSize.width / baseCardSize.height, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .background(cardBackground)
        .overlay(cardSurfaceOverlay)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(state.needsAttention ? 0.16 : 0.12), radius: 11, y: 4)
        .shadow(color: .black.opacity(state.needsAttention ? 0.10 : 0.08), radius: 24, y: 11)
        .shadow(color: appAccentColor.opacity(state == .available ? 0.12 : 0.05), radius: 20, y: 9)
        .scaleEffect(primaryActionCardScale)
        .animation(.spring(response: 0.20, dampingFraction: 0.82), value: primaryActionCardScale)
        .interactiveCardMotion(
            isEnabled: !isPinningIn && !isDetaching,
            highlightOpacity: state.needsAttention ? 0.08 : 0.12
        )
        .cardPinIn(
            isActive: isPinningIn && !isDetaching,
            onComplete: onPinInComplete
        )
        .workspaceCardEntrance(
            token: workspaceTransitionToken,
            index: workspaceTransitionIndex,
            isEnabled: !isPinningIn && !isDetaching
        )
        .cardDetachExit(isActive: isDetaching)
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(attachedWindow.window.appName)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 8)

                CardDragHandle(payload: dragPayload)

                actionsMenu
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 6)

            iconField
                .padding(.horizontal, 16)

            Divider()
                .padding(.horizontal, 16)
                .padding(.top, 8)

            VStack(alignment: .leading, spacing: 6) {
                Text(windowSubtitle)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .frame(minHeight: 30, alignment: .topLeading)

                StatusBadge(state: state)

                Text(statusDetail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer(minLength: 0)

                if shouldShowUseFrontWindow {
                    Button("Use Front Window", action: useFrontWindow)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .minimumScaleFactor(0.82)
                }

                Button(primaryActionTitle, action: primaryAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(state == .reconnecting || state == .resolving)
                    .controlSize(.small)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
                    .minimumScaleFactor(0.82)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 12)
        }
    }

    private var isPrimaryActionEnabled: Bool {
        state != .reconnecting && state != .resolving && !isDetaching
    }

    private var iconField: some View {
        IconPrimaryActionField(
            appName: attachedWindow.window.appName,
            bundleURL: attachedWindow.window.bundleURL,
            bundleIdentifier: attachedWindow.window.bundleIdentifier,
            state: state,
            background: iconFieldBackground,
            strokeColor: iconFieldStroke,
            isEnabled: isPrimaryActionEnabled,
            doubleClickAction: bringAndMoveBelowCard,
            onPressChanged: setPrimaryActionPressed,
            onActionFeedback: runPrimaryActionFeedback,
            action: primaryAction
        )
    }

    private var actionsMenu: some View {
        Menu {
            Button("Save Layout", action: update)
            Button("Find or Reopen", action: recover)
                .disabled(state == .reconnecting || state == .resolving)
            if shouldShowUseFrontWindow {
                Button("Use Front Window", action: useFrontWindow)
            }
            neverMinimizeMenuItem
            Divider()
            Button("Detach from Board", action: detach)
        } label: {
            Image(systemName: "ellipsis")
                .font(.body.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 22)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help("More window actions")
    }

    @ViewBuilder
    private var neverMinimizeMenuItem: some View {
        if attachedWindow.window.pid == 0 {
            Button("Add to Permanent Board") {}
                .disabled(true)
        } else if isNeverMinimizedWindow {
            Button("Already on Permanent Board") {}
                .disabled(true)
        } else {
            Button("Add to Permanent Board", action: addNeverMinimizeWindow)
        }
    }

    private var windowSubtitle: String {
        let title = attachedWindow.window.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "No window title" : title
    }

    private var statusDetail: String {
        if let recoveryIssue, state == .unavailable || state == .reconnecting {
            return recoveryIssue.detail
        }

        return switch state {
        case .available:
            "Ready"
        case .resolving:
            "Restoring saved window"
        case .minimized:
            "Minimized"
        case .unavailable:
            "Last seen window is missing"
        case .reconnecting:
            "Finding matching window"
        }
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(state == .unavailable ? Color.red.opacity(0.085) : appAccentColor.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                .white.opacity(0.22),
                                .white.opacity(0.04),
                                .black.opacity(0.035)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            )
    }

    private var cardSurfaceOverlay: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(cardStroke, lineWidth: strokeWidth)

            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .inset(by: 0.7)
                .stroke(.white.opacity(0.30), lineWidth: 1)
                .blendMode(.plusLighter)

            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .inset(by: 1.2)
                .stroke(.black.opacity(0.035), lineWidth: 1)
        }
    }

    private var iconFieldBackground: LinearGradient {
        if state == .unavailable {
            return LinearGradient(
                colors: [
                    Color(nsColor: .controlBackgroundColor).opacity(0.88),
                    Color.red.opacity(0.085),
                    Color(nsColor: .controlBackgroundColor).opacity(0.84)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }

        return LinearGradient(
            colors: [
                appAccentColor.opacity(0.26),
                appAccentColor.opacity(0.22),
                appAccentColor.opacity(0.18)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var iconFieldStroke: Color {
        state == .unavailable ? Color(nsColor: .separatorColor).opacity(0.42) : appAccentColor.opacity(0.32)
    }

    private var cardStroke: Color {
        switch state {
        case .available:
            appAccentColor.opacity(0.42)
        case .resolving:
            .blue.opacity(0.40)
        case .minimized:
            .orange.opacity(0.55)
        case .unavailable:
            .red.opacity(0.55)
        case .reconnecting:
            .blue.opacity(0.55)
        }
    }

    private var strokeWidth: CGFloat {
        state.needsAttention ? 1.15 : 0.8
    }

    private var primaryActionCardScale: CGFloat {
        if reduceMotion {
            1
        } else if isPrimaryActionPressed {
            0.992
        } else if isPrimaryActionPopping {
            1.012
        } else {
            1
        }
    }

    private var appAccentColor: Color {
        Color(nsColor: AppIconPalette.accentColor(
            appName: attachedWindow.window.appName,
            bundleURL: attachedWindow.window.bundleURL,
            bundleIdentifier: attachedWindow.window.bundleIdentifier
        ))
    }

    private var primaryActionTitle: String {
        switch state {
        case .available:
            "Bring Forward"
        case .resolving:
            "Restoring..."
        case .minimized:
            "Restore Window"
        case .unavailable:
            "Find or Reopen"
        case .reconnecting:
            "Finding..."
        }
    }

    private var shouldShowUseFrontWindow: Bool {
        (state == .unavailable || state == .reconnecting) && recoveryIssue?.canUseFrontWindow == true
    }

    private func primaryAction() {
        if state == .available {
            bringForward()
        } else if state != .resolving {
            recover()
        }
    }

    private func setPrimaryActionPressed(_ isPressed: Bool) {
        guard isPrimaryActionEnabled else { return }
        isPrimaryActionPressed = isPressed
    }

    private func runPrimaryActionFeedback() {
        guard isPrimaryActionEnabled, !reduceMotion else { return }

        isPrimaryActionPopping = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(115))
            withAnimation(.spring(response: 0.24, dampingFraction: 0.82)) {
                isPrimaryActionPopping = false
            }
        }
    }
}

private struct IconPrimaryActionField: View {
    @State private var isCursorPushed = false

    let appName: String
    let bundleURL: URL?
    let bundleIdentifier: String?
    let state: AttachedWindowDisplayState
    let background: LinearGradient
    let strokeColor: Color
    let isEnabled: Bool
    var actionTitle: String? = nil
    var accessibilityLabel: String? = nil
    var doubleClickAction: ((CGPoint) -> Void)? = nil
    let onPressChanged: (Bool) -> Void
    let onActionFeedback: () -> Void
    let action: () -> Void

    var body: some View {
        Button {
            triggerAction()
        } label: {
            fieldContent
        }
        .buttonStyle(
            IconPrimaryActionButtonStyle(
                isEnabled: isEnabled,
                onPressChanged: onPressChanged
            )
        )
        .disabled(!isEnabled)
        .onHover { hovering in
            guard isEnabled else { return }

            if hovering, !isCursorPushed {
                NSCursor.pointingHand.push()
                isCursorPushed = true
            } else if !hovering, isCursorPushed {
                NSCursor.pop()
                isCursorPushed = false
            }
        }
        .onDisappear {
            if isCursorPushed {
                NSCursor.pop()
                isCursorPushed = false
            }
        }
        .help(resolvedActionTitle)
        .accessibilityLabel(Text(resolvedAccessibilityLabel))
        .accessibilityAddTraits(isEnabled ? .isButton : [])
        .frame(maxWidth: .infinity)
        .aspectRatio(188.0 / 118.0, contentMode: .fit)
        .simultaneousGesture(
            TapGesture(count: 2)
                .onEnded {
                    guard isEnabled else { return }
                    doubleClickAction?(NSEvent.mouseLocation)
                }
        )
    }

    private var fieldContent: some View {
        GeometryReader { proxy in
            let iconSize = min(max(proxy.size.width * 0.52, 82), 120)

            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(background)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(strokeColor.opacity(0.82), lineWidth: 0.8)
                    )
                    .overlay(alignment: .top) {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(.white.opacity(0.34), lineWidth: 1)
                            .blendMode(.plusLighter)
                    }

                AppIconView(
                    appName: appName,
                    bundleURL: bundleURL,
                    bundleIdentifier: bundleIdentifier,
                    size: iconSize,
                    isElevated: true
                )
            }
        }
    }

    private func triggerAction() {
        guard isEnabled else { return }

        action()
        onActionFeedback()
    }

    private var primaryActionTitle: String {
        switch state {
        case .available:
            "Bring Forward"
        case .resolving:
            "Restoring..."
        case .minimized:
            "Restore Window"
        case .unavailable:
            "Find or Reopen"
        case .reconnecting:
            "Finding..."
        }
    }

    private var resolvedActionTitle: String {
        let title = actionTitle ?? primaryActionTitle
        guard doubleClickAction != nil, isEnabled, state == .available else {
            return title
        }
        return "\(title). Double-click to place below the cursor."
    }

    private var resolvedAccessibilityLabel: String {
        if let accessibilityLabel {
            return accessibilityLabel
        }

        switch state {
        case .available:
            return "Bring \(appName) forward"
        case .resolving:
            return "Restoring \(appName)"
        case .minimized:
            return "Restore \(appName) window"
        case .unavailable:
            return "Find or reopen \(appName)"
        case .reconnecting:
            return "Finding \(appName)"
        }
    }
}

private struct IconPrimaryActionButtonStyle: ButtonStyle {
    let isEnabled: Bool
    let onPressChanged: (Bool) -> Void

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { _, isPressed in
                onPressChanged(isEnabled && isPressed)
            }
            .onDisappear {
                onPressChanged(false)
            }
    }
}

private struct RecoveryPostingRow: View {
    let attachedWindow: AttachedWindow
    let state: AttachedWindowDisplayState
    let recover: () -> Void
    let detach: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            AppIconView(
                appName: attachedWindow.window.appName,
                bundleURL: attachedWindow.window.bundleURL,
                bundleIdentifier: attachedWindow.window.bundleIdentifier
            )

            VStack(alignment: .leading, spacing: 3) {
                Text(attachedWindow.window.appName)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)

                Text(attachedWindow.window.title.isEmpty ? "Last saved window is not currently available." : attachedWindow.window.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            StatusBadge(state: state)

            if let title = state.recoveryActionTitle {
                Button(title, action: recover)
                    .disabled(state == .reconnecting || state == .resolving)
            }

            Button {
                detach()
            } label: {
                Image(systemName: "xmark.circle")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Detach from board")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.red.opacity(0.035))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.red.opacity(0.45), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct SnapshotComparisonView: View {
    let selectedWorkspace: SavedWorkspace?
    let attachedWindows: [AttachedWindow]
    let stateForWindow: (AttachedWindow) -> AttachedWindowDisplayState
    let restoreSnapshot: () -> Void
    let canRestoreSnapshot: Bool

    var body: some View {
        let savedReferences = selectedWorkspace?.windows ?? []

        VStack(alignment: .leading, spacing: 12) {
            HStack {
                BoardSectionHeader(
                    title: "Snapshot Comparison",
                    count: savedReferences.isEmpty ? attachedWindows.count : savedReferences.count,
                    systemImage: "rectangle.stack"
                )

                Button("Restore Snapshot", action: restoreSnapshot)
                    .disabled(!canRestoreSnapshot)
            }

            VStack(spacing: 0) {
                if attachedWindows.isEmpty && savedReferences.isEmpty {
                    Text("No snapshot entries to compare.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                } else if attachedWindows.isEmpty {
                    ForEach(savedReferences) { savedReference in
                        SavedSnapshotReferenceRow(savedReference: savedReference)

                        if savedReference.id != savedReferences.last?.id {
                            Divider()
                                .padding(.leading, 14)
                        }
                    }
                } else {
                    ForEach(attachedWindows, id: \.id) { attachedWindow in
                        SnapshotComparisonRow(
                            attachedWindow: attachedWindow,
                            state: stateForWindow(attachedWindow)
                        )

                        if attachedWindow.id != attachedWindows.last?.id {
                            Divider()
                                .padding(.leading, 14)
                        }
                    }
                }
            }
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}

private struct SavedSnapshotReferenceRow: View {
    let savedReference: SavedWindowReference

    var body: some View {
        HStack(spacing: 12) {
            Label("Saved", systemImage: "archivebox")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 112, alignment: .leading)

            AppIconView(
                appName: savedReference.appName,
                bundleURL: savedReference.bundleURL,
                bundleIdentifier: savedReference.bundleIdentifier,
                size: 18
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(savedReference.appName)
                    .lineLimit(1)

                if !savedReference.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(savedReference.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if let savedOrigin = savedReference.savedOrigin {
                Text("\(Int(savedOrigin.x)), \(Int(savedOrigin.y))")
                    .foregroundStyle(.secondary)
            }

            if let savedSize = savedReference.savedSize {
                Text("\(Int(savedSize.width)) × \(Int(savedSize.height))")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}

private struct SnapshotComparisonRow: View {
    let attachedWindow: AttachedWindow
    let state: AttachedWindowDisplayState

    var body: some View {
        HStack(spacing: 12) {
            Label(statusTitle, systemImage: state.systemImage)
                .font(.caption.weight(.medium))
                .foregroundStyle(statusColor)
                .frame(width: 112, alignment: .leading)

            AppIconView(
                appName: attachedWindow.window.appName,
                bundleURL: attachedWindow.window.bundleURL,
                bundleIdentifier: attachedWindow.window.bundleIdentifier,
                size: 18
            )

            Text(attachedWindow.window.appName)
                .lineLimit(1)

            Spacer()

            if let savedOrigin = attachedWindow.savedReference?.savedOrigin {
                Text("\(Int(savedOrigin.x)), \(Int(savedOrigin.y))")
                    .foregroundStyle(.secondary)
            }

            if let savedSize = attachedWindow.savedReference?.savedSize {
                Text("\(Int(savedSize.width)) × \(Int(savedSize.height))")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private var statusTitle: String {
        switch state {
        case .available:
            "In Sync"
        case .resolving:
            "Restoring"
        case .minimized:
            "Minimized"
        case .unavailable:
            "Missing"
        case .reconnecting:
            "Finding"
        }
    }

    private var statusColor: Color {
        switch state {
        case .available:
            .green
        case .resolving:
            .blue
        case .minimized:
            .orange
        case .unavailable:
            .red
        case .reconnecting:
            .blue
        }
    }
}

private struct AppIconView: View {
    let appName: String
    let bundleURL: URL?
    let bundleIdentifier: String?
    var size: CGFloat = 24
    var isElevated = false

    var body: some View {
        Group {
            if let iconImage {
                Image(nsImage: iconImage)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                fallbackIcon
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        .shadow(color: .black.opacity(isElevated ? 0.18 : 0), radius: isElevated ? 10 : 0, y: isElevated ? 5 : 0)
        .shadow(color: iconColor.opacity(isElevated ? 0.18 : 0), radius: isElevated ? 18 : 0, y: isElevated ? 8 : 0)
    }

    private var iconImage: NSImage? {
        AppIconCache.icon(
            appName: appName,
            bundleURL: bundleURL,
            bundleIdentifier: bundleIdentifier
        )
    }

    private var fallbackIcon: some View {
        Image(systemName: symbolName)
            .font(.system(size: size * 0.52, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(iconColor.gradient)
    }

    private var symbolName: String {
        switch appName.lowercased() {
        case let name where name.contains("terminal"):
            "terminal"
        case let name where name.contains("safari") || name.contains("chrome"):
            "globe"
        case let name where name.contains("xcode") || name.contains("code"):
            "chevron.left.forwardslash.chevron.right"
        case let name where name.contains("simulator"):
            "iphone"
        default:
            "macwindow"
        }
    }

    private var iconColor: Color {
        switch appName.lowercased() {
        case let name where name.contains("terminal"):
            .black
        case let name where name.contains("safari") || name.contains("chrome"):
            .blue
        case let name where name.contains("xcode") || name.contains("code"):
            .blue
        case let name where name.contains("simulator"):
            .gray
        default:
            .accentColor
        }
    }
}

private enum AppIconCache {
    private static var cache: [String: NSImage] = [:]

    static func icon(appName: String, bundleURL: URL?, bundleIdentifier: String?) -> NSImage? {
        let key = bundleIdentifier ?? bundleURL?.absoluteString ?? appName
        if let cachedIcon = cache[key] {
            return cachedIcon
        }

        guard let resolvedIcon = resolvedIcon(bundleURL: bundleURL, bundleIdentifier: bundleIdentifier) else {
            return nil
        }

        cache[key] = resolvedIcon
        return resolvedIcon
    }

    private static func resolvedIcon(bundleURL: URL?, bundleIdentifier: String?) -> NSImage? {
        if let bundleURL {
            return NSWorkspace.shared.icon(forFile: bundleURL.path)
        }

        if let bundleIdentifier,
           let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            return NSWorkspace.shared.icon(forFile: applicationURL.path)
        }

        return nil
    }
}

private enum AppIconPalette {
    private static var cache: [String: NSColor] = [:]

    static func accentColor(appName: String, bundleURL: URL?, bundleIdentifier: String?) -> NSColor {
        let key = bundleIdentifier ?? bundleURL?.absoluteString ?? appName
        if let cached = cache[key] {
            return cached
        }

        let resolved = resolvedIcon(bundleURL: bundleURL, bundleIdentifier: bundleIdentifier)
            .flatMap(dominantColor(from:)) ?? fallbackColor(appName: appName)
        cache[key] = resolved
        return resolved
    }

    private static func resolvedIcon(bundleURL: URL?, bundleIdentifier: String?) -> NSImage? {
        if let bundleURL {
            return NSWorkspace.shared.icon(forFile: bundleURL.path)
        }

        if let bundleIdentifier,
           let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            return NSWorkspace.shared.icon(forFile: applicationURL.path)
        }

        return nil
    }

    private static func dominantColor(from image: NSImage) -> NSColor? {
        let targetSize = NSSize(width: 24, height: 24)
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(targetSize.width),
            pixelsHigh: Int(targetSize.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )

        guard let bitmap else {
            return nil
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(origin: .zero, size: targetSize))
        NSGraphicsContext.restoreGraphicsState()

        var redTotal: CGFloat = 0
        var greenTotal: CGFloat = 0
        var blueTotal: CGFloat = 0
        var weightTotal: CGFloat = 0

        for x in 0..<bitmap.pixelsWide {
            for y in 0..<bitmap.pixelsHigh {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      color.alphaComponent > 0.2 else {
                    continue
                }

                let maxComponent = max(color.redComponent, color.greenComponent, color.blueComponent)
                let minComponent = min(color.redComponent, color.greenComponent, color.blueComponent)
                let saturation = maxComponent - minComponent
                let brightness = maxComponent

                guard saturation > 0.08, brightness > 0.16, brightness < 0.96 else {
                    continue
                }

                let weight = saturation * color.alphaComponent
                redTotal += color.redComponent * weight
                greenTotal += color.greenComponent * weight
                blueTotal += color.blueComponent * weight
                weightTotal += weight
            }
        }

        guard weightTotal > 0 else {
            return nil
        }

        return NSColor(
            calibratedRed: redTotal / weightTotal,
            green: greenTotal / weightTotal,
            blue: blueTotal / weightTotal,
            alpha: 1
        )
    }

    private static func fallbackColor(appName: String) -> NSColor {
        switch appName.lowercased() {
        case let name where name.contains("terminal"):
            return .darkGray
        case let name where name.contains("safari") || name.contains("chrome"):
            return .systemBlue
        case let name where name.contains("xcode") || name.contains("code"):
            return .systemBlue
        case let name where name.contains("simulator"):
            return .systemGray
        default:
            return .controlAccentColor
        }
    }
}

private struct WorkspaceSummaryHeader: View {
    let selectedWorkspace: SavedWorkspace?
    let attachedCount: Int
    let symbolName: String?
    let reloadWorkspace: () -> Void
    let canReloadWorkspace: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            StatusItemPreview(symbolName: symbolName)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(.quaternary)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(selectedWorkspace?.displayName ?? "No Board Selected")
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)

                Text("\(attachedCount) \(attachedCount == 1 ? "board window" : "board windows")")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Reload", action: reloadWorkspace)
                .disabled(!canReloadWorkspace)
        }
    }
}

private struct AttachedWindowsHeader: View {
    let count: Int

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Board Windows")
                    .font(.headline)
                Text("\(count) \(count == 1 ? "window" : "windows") on this board")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
    }
}

private struct WorkspaceSettingsControls: View {
    let selectedWorkspace: SavedWorkspace?
    let workspaceName: Binding<String>
    let workspaceStatusText: Binding<String>
    let minimizeUnattachedOnSwitch: Binding<Bool>
    let restoreMissingWindowsOnSwitch: Binding<Bool>
    let boardAlwaysOnTop: Binding<Bool>
    let canSaveWorkspace: Bool
    let canOverwriteWorkspace: Bool
    let canEditWorkspaceName: Bool
    let canRenameWorkspace: Bool
    let canDeleteWorkspace: Bool
    let canDetachAll: Bool
    let saveWorkspace: () -> Void
    let overwriteWorkspace: () -> Void
    let renameWorkspace: () -> Void
    let deleteWorkspace: () -> Void
    let updateStatusItemIcon: (String) -> Void
    let updateStatusItemText: () -> Void
    let detachAll: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Board")
                    .font(.subheadline.weight(.medium))

                TextField("Board Name", text: workspaceName)
                    .disabled(!canEditWorkspaceName)

                ViewThatFits(in: .horizontal) {
                    HStack {
                        workspaceActionButtons
                        Spacer()
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        workspaceActionButtons
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Status Item Display")
                    .font(.subheadline.weight(.medium))

                ViewThatFits(in: .horizontal) {
                    HStack {
                        statusItemDisplayControls
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        statusItemDisplayControls
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Switch Behavior")
                    .font(.subheadline.weight(.medium))

                Toggle("Minimize Others When Switching Boards", isOn: minimizeUnattachedOnSwitch)
                Toggle("Restore Missing Windows When Switching Boards", isOn: restoreMissingWindowsOnSwitch)
                Toggle("Keep Window Board On Top", isOn: boardAlwaysOnTop)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Danger Zone")
                    .font(.subheadline.weight(.medium))

                ViewThatFits(in: .horizontal) {
                    HStack {
                        dangerZoneButtons
                        Spacer()
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        dangerZoneButtons
                    }
                }
            }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var workspaceActionButtons: some View {
        Button("Save", action: saveWorkspace)
            .disabled(!canSaveWorkspace)
        Button("Overwrite", action: overwriteWorkspace)
            .disabled(!canOverwriteWorkspace)
        Button("Rename", action: renameWorkspace)
            .disabled(!canRenameWorkspace)
    }

    @ViewBuilder
    private var statusItemDisplayControls: some View {
        StatusItemPreview(symbolName: selectedWorkspace?.statusItemSymbolName)
        TextField("Text", text: workspaceStatusText)
            .frame(minWidth: 80, idealWidth: 120, maxWidth: 160)
            .disabled(selectedWorkspace == nil)
        Button("Set Text", action: updateStatusItemText)
            .disabled(selectedWorkspace == nil)
        StatusItemIconMenu(
            symbolName: selectedWorkspace?.statusItemSymbolName,
            selectIcon: updateStatusItemIcon
        )
        .disabled(selectedWorkspace == nil)
    }

    @ViewBuilder
    private var dangerZoneButtons: some View {
        Button("Delete Board", action: deleteWorkspace)
            .disabled(!canDeleteWorkspace)
        Button("Remove All Windows", action: detachAll)
            .disabled(!canDetachAll)
    }
}

struct AttachedWindowsListView: View {
    let attachedWindows: [AttachedWindow]
    let stateForWindow: (AttachedWindow) -> AttachedWindowDisplayState
    let canAttachFrontmost: Bool
    let attachFrontmost: () -> Void
    let recover: (AttachedWindow) -> Void
    let update: (AttachedWindow.ID) -> Void
    let detach: (AttachedWindow.ID) -> Void

    var body: some View {
        List {
            if attachedWindows.isEmpty {
                EmptyAttachedWindowsRow(
                    canAttachFrontmost: canAttachFrontmost,
                    attachFrontmost: attachFrontmost
                )
            } else {
                ForEach(attachedWindows, id: \.id) { attachedWindow in
                    AttachedWindowListRow(
                        attachedWindow: attachedWindow,
                        state: stateForWindow(attachedWindow),
                        recover: { recover(attachedWindow) },
                        update: { update(attachedWindow.id) },
                        detach: { detach(attachedWindow.id) }
                    )
                }
            }
        }
        .listStyle(.inset)
    }
}

private struct EmptyAttachedWindowsRow: View {
    let canAttachFrontmost: Bool
    let attachFrontmost: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("No windows attached", systemImage: "rectangle.stack.badge.plus")
                .font(.headline)

            Text("Attach the frontmost app window, or choose a window below.")
                .foregroundStyle(.secondary)

            Button("Attach Window", action: attachFrontmost)
                .disabled(!canAttachFrontmost)
        }
        .padding(.vertical, 18)
    }
}

private struct AttachedWindowListRow: View {
    let attachedWindow: AttachedWindow
    let state: AttachedWindowDisplayState
    let recover: () -> Void
    let update: () -> Void
    let detach: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "macwindow")
                .foregroundStyle(.secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 4) {
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

            StatusBadge(state: state)

            recoveryButton

            Menu {
                Button("Save Layout", action: update)
                Button("Find Window Again", action: recover)
                    .disabled(state == .reconnecting)
                Divider()
                Button("Remove from Board", action: detach)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .help("More actions")
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var recoveryButton: some View {
        if let recoveryActionTitle = state.recoveryActionTitle {
            switch state {
            case .minimized, .unavailable:
                Button(recoveryActionTitle, action: recover)
                    .buttonStyle(.borderedProminent)
            case .reconnecting:
                Button(recoveryActionTitle, action: recover)
                    .disabled(true)
            case .available, .resolving:
                EmptyView()
            }
        }
    }
}

private struct StatusBadge: View {
    let state: AttachedWindowDisplayState

    var body: some View {
        Label(state.title, systemImage: state.systemImage)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(.quaternary)
            .clipShape(Capsule())
    }
}

private struct StatusItemPreview: View {
    let symbolName: String?

    var body: some View {
        HStack(spacing: 6) {
            if let title = WorkspaceStatusItemIcon.title(from: symbolName) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
            } else {
                Image(systemName: symbolName ?? WorkspaceStatusItemIcon.defaultSymbolName)
            }

            Text("Current")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct StatusItemIconMenu: View {
    let symbolName: String?
    let selectIcon: (String) -> Void

    var body: some View {
        Menu {
            Section("Symbols") {
                ForEach(WorkspaceStatusItemIcon.options) { icon in
                    Button {
                        selectIcon(icon.symbolName)
                    } label: {
                        Label(icon.label, systemImage: icon.symbolName)
                    }
                }
            }

            Section("Emoji") {
                ForEach(WorkspaceStatusItemIcon.emojiOptions) { icon in
                    Button {
                        selectIcon(icon.symbolName)
                    } label: {
                        Text("\(icon.emoji ?? "") \(icon.label)")
                    }
                }
            }
        } label: {
            if let title = WorkspaceStatusItemIcon.title(from: symbolName) {
                Text("\(title) Display")
            } else {
                Label("Icon", systemImage: symbolName ?? WorkspaceStatusItemIcon.defaultSymbolName)
            }
        }
    }
}

private struct StatusFeedbackView: View {
    let statusMessage: String
    let isLoadingWorkspace: Bool
    let isMinimizingUnattached: Bool
    let isRestoringMinimized: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if isLoadingWorkspace {
                ProgressView("Restoring windows and reconnecting as needed...")
            } else if isMinimizingUnattached {
                ProgressView("Minimizing other windows...")
            } else if isRestoringMinimized {
                ProgressView("Restoring minimized windows...")
            }

            Text(statusMessage)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
