import AppKit
import SwiftUI

struct WorkspaceDetailActions {
    let refreshWindows: () -> Void
    let attachSelected: () -> Void
    let attachFrontmost: () -> Void
    let attachFromAddCard: () -> Void
    let clearRecentlyAddedWindowID: () -> Void
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
    let addNeverMinimizeWindow: (WindowInfo) -> Void
    let moveAttachedWindowToPermanentBoard: (AttachedWindow.ID) -> Void
    let rejectPermanentBoardDrop: () -> Void
    let movePermanentWindowToMainBoard: (NeverMinimizeWindow.ID) -> Void
    let rejectMainBoardDrop: () -> Void
    let addNeverMinimizeRunningWindow: (WindowInfo) -> Void
    let removeNeverMinimizeWindow: (NeverMinimizeWindow.ID) -> Void
    let clearRecentlyAddedNeverMinimizeWindowID: () -> Void
    let showNeverMinimizeWindow: (WindowInfo) -> Void
    let showAndMoveNeverMinimizeWindowBelowCard: (WindowInfo, CGPoint) -> Void
    let updatePositions: () -> Void
    let bringToFront: () -> Void
    let minimizeUnattached: () -> Void
    let restoreMinimized: () -> Void
    let detachAll: () -> Void
}

struct WorkspaceDetailView: View {
    let selectedWorkspace: SavedWorkspace?
    let selectedWindowID: WindowInfo.ID?
    let windows: [WindowInfo]
    let attachedWindows: [AttachedWindow]
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
    let actions: WorkspaceDetailActions
    let recentlyAddedWindowID: AttachedWindow.ID?
    let workspaceTransitionToken: UUID?
    let detachingAttachedWindowIDs: Set<AttachedWindow.ID>
    let isNeverMinimizedWindow: (WindowInfo) -> Bool
    let neverMinimizeWindows: [NeverMinimizeWindow]
    let runningNeverMinimizeWindowCandidates: [WindowInfo]
    let recentlyAddedNeverMinimizeWindowID: NeverMinimizeWindow.ID?
    let detachingNeverMinimizeWindowIDs: Set<NeverMinimizeWindow.ID>
    let liveNeverMinimizeWindow: (NeverMinimizeWindow) -> WindowInfo?

    var body: some View {
        ZStack(alignment: .bottom) {
            boardContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.clear)

            ProcessingStatusOverlay(
                isLoadingWorkspace: isLoadingWorkspace,
                isMinimizingUnattached: isMinimizingUnattached,
                isRestoringMinimized: isRestoringMinimized
            )
            .padding(.bottom, 16)
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
                        attachFrontmost: actions.attachFrontmost,
                        attachFromAddCard: actions.attachFromAddCard,
                        recentlyAddedWindowID: recentlyAddedWindowID,
                        clearRecentlyAddedWindowID: actions.clearRecentlyAddedWindowID,
                        workspaceTransitionToken: workspaceTransitionToken,
                        detachingAttachedWindowIDs: detachingAttachedWindowIDs,
                        recover: actions.recoverAttached,
                        useFrontWindow: actions.useFrontWindowForAttached,
                        update: actions.updateAttached,
                        detach: actions.detachAttached,
                        bringForward: actions.bringForwardAttached,
                        bringAndMoveBelowCard: actions.bringAndMoveAttachedBelowCard,
                        isNeverMinimizedWindow: isNeverMinimizedWindow,
                        addNeverMinimizeWindow: actions.addNeverMinimizeWindow,
                        movePermanentWindowToMainBoard: actions.movePermanentWindowToMainBoard,
                        rejectDrop: actions.rejectMainBoardDrop
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
                        addWindow: actions.addNeverMinimizeRunningWindow,
                        removeWindow: actions.removeNeverMinimizeWindow,
                        recentlyAddedWindowID: recentlyAddedNeverMinimizeWindowID,
                        clearRecentlyAddedWindowID: actions.clearRecentlyAddedNeverMinimizeWindowID,
                        detachingWindowIDs: detachingNeverMinimizeWindowIDs,
                        liveWindow: liveNeverMinimizeWindow,
                        showWindow: actions.showNeverMinimizeWindow,
                        showAndMoveBelowCard: actions.showAndMoveNeverMinimizeWindowBelowCard,
                        moveAttachedWindow: actions.moveAttachedWindowToPermanentBoard,
                        rejectDrop: actions.rejectPermanentBoardDrop
                    )
                }
            }
            .padding(24)
            .frame(maxWidth: 1120, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
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

struct BoardSectionHeader: View {
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
