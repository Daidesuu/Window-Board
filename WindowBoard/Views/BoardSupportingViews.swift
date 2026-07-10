import SwiftUI

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

struct WorkspaceSettingsControls: View {
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

struct StatusBadge: View {
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

struct ProcessingStatusOverlay: View {
    let isLoadingWorkspace: Bool
    let isMinimizingUnattached: Bool
    let isRestoringMinimized: Bool

    var body: some View {
        if let message {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)

                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.thinMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .animation(.easeInOut(duration: 0.18), value: message)
        }
    }

    private var message: String? {
        if isLoadingWorkspace {
            return "Restoring windows..."
        }

        if isMinimizingUnattached {
            return "Minimizing other windows..."
        }

        if isRestoringMinimized {
            return "Restoring windows..."
        }

        return nil
    }
}
