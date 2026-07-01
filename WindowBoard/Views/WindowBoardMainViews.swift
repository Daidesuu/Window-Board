import AppKit
import SwiftUI

enum AttachedWindowDisplayState: Equatable {
    case available
    case minimized
    case unavailable
    case reconnecting

    var title: String {
        switch self {
        case .available:
            "Available"
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
        case .available:
            false
        case .minimized, .unavailable, .reconnecting:
            true
        }
    }

    var recoveryActionTitle: String? {
        switch self {
        case .available:
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

struct WorkspaceSidebarView: View {
    let workspaces: [SavedWorkspace]
    let activeWorkspaceID: SavedWorkspace.ID?
    @Binding var selection: SavedWorkspace.ID?

    var body: some View {
        List(selection: $selection) {
            Section("Workspaces") {
                if workspaces.isEmpty {
                    Text("No Saved Workspaces")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(workspaces) { workspace in
                        WorkspaceSidebarRow(
                            workspace: workspace,
                            isActive: workspace.id == activeWorkspaceID
                        )
                        .tag(SavedWorkspace.ID?.some(workspace.id))
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background {
            Rectangle()
                .fill(.thinMaterial)
                .overlay(Color(nsColor: .windowBackgroundColor).opacity(0.08))
        }
        .navigationTitle("Window Board")
    }
}

private struct WorkspaceSidebarRow: View {
    let workspace: SavedWorkspace
    let isActive: Bool

    var body: some View {
        HStack(spacing: 10) {
            statusItemGlyph
                .foregroundStyle(.secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(workspace.name)
                        .lineLimit(1)

                    if isActive {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Text("\(workspace.windows.count) \(workspace.windows.count == 1 ? "window" : "windows")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private var statusItemGlyph: some View {
        if let title = WorkspaceStatusItemIcon.title(from: workspace.statusItemSymbolName) {
            Text(title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
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
    let refreshWindows: () -> Void
    let attachSelected: () -> Void
    let attachFrontmost: () -> Void
    let saveWorkspace: () -> Void
    let overwriteWorkspace: () -> Void
    let renameWorkspace: () -> Void
    let reloadWorkspace: () -> Void
    let deleteWorkspace: () -> Void
    let updateStatusItemIcon: (String) -> Void
    let updateStatusItemText: () -> Void
    let recoverAttached: (AttachedWindow) -> Void
    let updateAttached: (AttachedWindow.ID) -> Void
    let detachAttached: (AttachedWindow.ID) -> Void
    let bringForwardAttached: (AttachedWindow) -> Void
    let updatePositions: () -> Void
    let bringToFront: () -> Void
    let minimizeUnattached: () -> Void
    let restoreMinimized: () -> Void
    let detachAll: () -> Void
    @State private var isAddWindowExpanded = false
    @State private var isWorkspaceSettingsExpanded = false

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
                canReloadWorkspace: canReloadWorkspace
            )
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            .background {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .overlay(Color(nsColor: .windowBackgroundColor).opacity(0.015))
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
            VStack(alignment: .leading, spacing: 22) {
                PinnedWindowCardGrid(
                    attachedWindows: attachedWindows,
                    stateForWindow: attachedState,
                    canAttachFrontmost: canAttachFrontmost,
                    attachFrontmost: attachFrontmost,
                    recover: recoverAttached,
                    update: updateAttached,
                    detach: detachAttached,
                    bringForward: bringForwardAttached
                )

                secondaryControls
                    .padding(.top, 4)
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

    private var secondaryControls: some View {
        Form {
            Section {
                DisclosureGroup("Add Window", isExpanded: $isAddWindowExpanded) {
                    WindowSelectionView(
                        windows: windows,
                        selection: selectedWindow,
                        isLoading: isLoadingWindows,
                        canAttachSelected: canAttachSelected,
                        canAttachFrontmost: canAttachFrontmost,
                        refreshWindows: refreshWindows,
                        attachSelected: attachSelected,
                        attachFrontmost: attachFrontmost
                    )
                }
            }

            Section {
                DisclosureGroup("Workspace Settings", isExpanded: $isWorkspaceSettingsExpanded) {
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
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .frame(maxWidth: 520)
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

        HStack {
            Button("Refresh", action: refreshWindows)
                .disabled(isLoading)
            Button("Attach Selected", action: attachSelected)
                .disabled(!canAttachSelected)
            Button("Attach Window", action: attachFrontmost)
                .disabled(!canAttachFrontmost)
            Spacer()
        }
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
    let canAttachFrontmost: Bool
    let attachFrontmost: () -> Void
    let recover: (AttachedWindow) -> Void
    let update: (AttachedWindow.ID) -> Void
    let detach: (AttachedWindow.ID) -> Void
    let bringForward: (AttachedWindow) -> Void

    private let columns = [
        GridItem(.adaptive(minimum: 200, maximum: 240), spacing: 18, alignment: .top)
    ]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
            if attachedWindows.isEmpty {
                AddPinnedWindowCard(
                    canAttachFrontmost: canAttachFrontmost,
                    attachFrontmost: attachFrontmost,
                    isEmptyState: true
                )
            } else {
                ForEach(attachedWindows, id: \.id) { attachedWindow in
                    PinnedWindowCard(
                        attachedWindow: attachedWindow,
                        state: stateForWindow(attachedWindow),
                        bringForward: { bringForward(attachedWindow) },
                        recover: { recover(attachedWindow) },
                        update: { update(attachedWindow.id) },
                        detach: { detach(attachedWindow.id) }
                    )
                }

                AddPinnedWindowCard(
                    canAttachFrontmost: canAttachFrontmost,
                    attachFrontmost: attachFrontmost,
                    isEmptyState: false
                )
            }
        }
    }
}

private struct AddPinnedWindowCard: View {
    let canAttachFrontmost: Bool
    let attachFrontmost: () -> Void
    let isEmptyState: Bool

    var body: some View {
        Button(action: attachFrontmost) {
            VStack(spacing: 12) {
                Image(systemName: "plus")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(.secondary)

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
        .buttonStyle(.plain)
        .disabled(!canAttachFrontmost)
        .aspectRatio(220.0 / 308.0, contentMode: .fit)
        .frame(minHeight: 260)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        }
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(
                    Color(nsColor: .separatorColor).opacity(0.42),
                    style: StrokeStyle(lineWidth: 1, dash: [7, 6])
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .opacity(canAttachFrontmost ? 1 : 0.55)
    }
}

private struct PinnedWindowCard: View {
    let attachedWindow: AttachedWindow
    let state: AttachedWindowDisplayState
    let bringForward: () -> Void
    let recover: () -> Void
    let update: () -> Void
    let detach: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(attachedWindow.window.appName)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 8)

                actionsMenu
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 9)

            iconField
                .padding(.horizontal, 16)

            Divider()
                .padding(.horizontal, 16)
                .padding(.top, 12)

            VStack(alignment: .leading, spacing: 8) {
                Text(windowSubtitle)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .frame(minHeight: 34, alignment: .topLeading)

                StatusBadge(state: state)

                Text(statusDetail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer(minLength: 0)

                Button(primaryActionTitle, action: primaryAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(state == .reconnecting)
                    .controlSize(.small)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 14)
        }
        .aspectRatio(220.0 / 308.0, contentMode: .fit)
        .frame(minHeight: 260)
        .background(cardBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(cardStroke, lineWidth: strokeWidth)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.065), radius: 14, y: 4)
    }

    private var iconField: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(iconFieldBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(iconFieldStroke, lineWidth: 0.8)
                )

            AppIconView(
                appName: attachedWindow.window.appName,
                bundleURL: attachedWindow.window.bundleURL,
                bundleIdentifier: attachedWindow.window.bundleIdentifier,
                size: 88
            )
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(188.0 / 132.0, contentMode: .fit)
    }

    private var actionsMenu: some View {
        Menu {
            Button("Save Layout", action: update)
            Button("Find or Reopen", action: recover)
                .disabled(state == .reconnecting)
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

    private var windowSubtitle: String {
        let title = attachedWindow.window.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "No window title" : title
    }

    private var statusDetail: String {
        switch state {
        case .available:
            "Ready"
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
                    .fill(state == .unavailable ? Color.red.opacity(0.035) : appAccentColor.opacity(0.055))
            )
    }

    private var iconFieldBackground: Color {
        state == .unavailable ? Color(nsColor: .controlBackgroundColor).opacity(0.72) : appAccentColor.opacity(0.16)
    }

    private var iconFieldStroke: Color {
        state == .unavailable ? Color(nsColor: .separatorColor).opacity(0.42) : appAccentColor.opacity(0.32)
    }

    private var cardStroke: Color {
        switch state {
        case .available:
            appAccentColor.opacity(0.42)
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
        case .minimized:
            "Restore Window"
        case .unavailable:
            "Find or Reopen"
        case .reconnecting:
            "Finding..."
        }
    }

    private func primaryAction() {
        if state == .available {
            bringForward()
        } else {
            recover()
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
                    .disabled(state == .reconnecting)
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
    }

    private var iconImage: NSImage? {
        if let bundleURL {
            return NSWorkspace.shared.icon(forFile: bundleURL.path)
        }

        if let bundleIdentifier,
           let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            return NSWorkspace.shared.icon(forFile: applicationURL.path)
        }

        return nil
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
                Text(selectedWorkspace?.displayName ?? "No Workspace Selected")
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)

                Text("\(attachedCount) \(attachedCount == 1 ? "attached window" : "attached windows")")
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
                Text("Attached Windows")
                    .font(.headline)
                Text("\(count) \(count == 1 ? "window" : "windows") in this workspace")
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
                Text("Workspace")
                    .font(.subheadline.weight(.medium))

                TextField("Workspace Name", text: workspaceName)
                    .disabled(!canEditWorkspaceName)

                HStack {
                    Button("Save", action: saveWorkspace)
                        .disabled(!canSaveWorkspace)
                    Button("Overwrite", action: overwriteWorkspace)
                        .disabled(!canOverwriteWorkspace)
                    Button("Rename", action: renameWorkspace)
                        .disabled(!canRenameWorkspace)
                    Spacer()
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Status Item Display")
                    .font(.subheadline.weight(.medium))

                HStack {
                    StatusItemPreview(symbolName: selectedWorkspace?.statusItemSymbolName)
                    Spacer()
                    TextField("Text", text: workspaceStatusText)
                        .frame(width: 120)
                        .disabled(selectedWorkspace == nil)
                    Button("Set Text", action: updateStatusItemText)
                        .disabled(selectedWorkspace == nil)
                    StatusItemIconMenu(
                        symbolName: selectedWorkspace?.statusItemSymbolName,
                        selectIcon: updateStatusItemIcon
                    )
                    .disabled(selectedWorkspace == nil)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Switch Behavior")
                    .font(.subheadline.weight(.medium))

                Toggle("Minimize Unattached On Workspace Switch", isOn: minimizeUnattachedOnSwitch)
                Toggle("Restore Missing Windows On Workspace Switch", isOn: restoreMissingWindowsOnSwitch)
                Toggle("Keep Window Board On Top", isOn: boardAlwaysOnTop)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Danger Zone")
                    .font(.subheadline.weight(.medium))

                HStack {
                    Button("Delete Workspace", action: deleteWorkspace)
                        .disabled(!canDeleteWorkspace)
                    Button("Remove All Windows", action: detachAll)
                        .disabled(!canDetachAll)
                    Spacer()
                }
            }
        }
        .padding(.vertical, 6)
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
                Button("Remove from Workspace", action: detach)
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
            case .available:
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
                ProgressView("Minimizing unattached windows...")
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
