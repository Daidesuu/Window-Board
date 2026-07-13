import SwiftUI

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
