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
    private let titlebarInsetHeight: CGFloat = 4

    let workspaces: [SavedWorkspace]
    let activeWorkspaceID: SavedWorkspace.ID?
    let showBoardSettings: (SavedWorkspace) -> Void
    let restoreBoardLayout: (SavedWorkspace) -> Void
    let removeBoardWindows: (SavedWorkspace) -> Void
    let deleteBoard: (SavedWorkspace) -> Void
    @Binding var selection: SavedWorkspace.ID?

    var body: some View {
        List(selection: $selection) {
            Section("Boards") {
                if workspaces.isEmpty {
                    Text("No Saved Boards")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(workspaces) { workspace in
                        WorkspaceSidebarRow(
                            workspace: workspace,
                            isActive: workspace.id == activeWorkspaceID
                        )
                        .tag(SavedWorkspace.ID?.some(workspace.id))
                        .help(workspace.displayName)
                        .contextMenu {
                            Button {
                                showBoardSettings(workspace)
                            } label: {
                                Label("Board Settings", systemImage: "slider.horizontal.3")
                            }

                            Button {
                                restoreBoardLayout(workspace)
                            } label: {
                                Label("Restore Layout", systemImage: "arrow.counterclockwise")
                            }

                            Divider()

                            Button(role: .destructive) {
                                removeBoardWindows(workspace)
                            } label: {
                                Label("Remove All Windows", systemImage: "xmark.circle")
                            }
                            .disabled(workspace.windows.isEmpty)

                            Button(role: .destructive) {
                                deleteBoard(workspace)
                            } label: {
                                Label("Delete Board", systemImage: "trash")
                            }
                            .disabled(workspace.isDefault)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top, spacing: 0) {
            Color.clear
                .frame(height: titlebarInsetHeight)
        }
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
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
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

