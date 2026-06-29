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
    let updatePositions: () -> Void
    let bringToFront: () -> Void
    let minimizeUnattached: () -> Void
    let restoreMinimized: () -> Void
    let detachAll: () -> Void
    @State private var isAddWindowExpanded = false
    @State private var isWorkspaceSettingsExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            WorkspaceSummaryHeader(
                selectedWorkspace: selectedWorkspace,
                attachedCount: attachedWindows.count,
                symbolName: selectedWorkspace?.statusItemSymbolName,
                reloadWorkspace: reloadWorkspace,
                canReloadWorkspace: canReloadWorkspace
            )
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()

            VStack(spacing: 0) {
                AttachedWindowsHeader(count: attachedWindows.count)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)

                AttachedWindowsListView(
                    attachedWindows: attachedWindows,
                    stateForWindow: attachedState,
                    canAttachFrontmost: canAttachFrontmost,
                    attachFrontmost: attachFrontmost,
                    recover: recoverAttached,
                    update: updateAttached,
                    detach: detachAttached
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            secondaryControls
                .frame(maxHeight: 300)

            Divider()

            StatusFeedbackView(
                statusMessage: statusMessage,
                isLoadingWorkspace: isLoadingWorkspace,
                isMinimizingUnattached: isMinimizingUnattached,
                isRestoringMinimized: isRestoringMinimized
            )
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
        }
        .navigationTitle(selectedWorkspace?.name ?? "Workspace")
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
        .scrollContentBackground(.automatic)
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
