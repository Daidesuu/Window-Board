import SwiftUI

struct TreeBoardDetailView: View {
    @ObservedObject var directory: BoardDirectoryController
    @ObservedObject var windowController: TreeBoardWindowController

    let onOpenBoard: (SavedWorkspace.ID) -> Void
    let onCreateChild: (SavedWorkspace.ID) -> Void
    let onRename: (SavedWorkspace.ID) -> Void
    let onDelete: (SavedWorkspace.ID) -> Void
    let isFavorite: (SavedWorkspace.ID) -> Bool
    let onToggleFavorite: (SavedWorkspace.ID) -> Void
    let onMoveBoard: (SavedWorkspace.ID, SavedWorkspace.ID) -> Bool
    let onMoveWindow: (TreeWindowDragPayload, SavedWorkspace.ID) -> Bool

    @State private var selection: Set<TreeBrowserItem.ID> = []

    var body: some View {
        if let board = directory.snapshot.currentBoard {
            VStack(spacing: 0) {
                TreePathBar(
                    boards: directory.snapshot.breadcrumbs,
                    currentBoardID: directory.currentBoardID,
                    onOpenBoard: onOpenBoard
                )

                if !windowController.isAccessibilityTrusted {
                    TreeAccessibilityBanner(
                        requestAccess: requestAccessibilityAccess,
                        openSettings: windowController.openAccessibilitySettings
                    )
                }

                if let statusMessage = windowController.statusMessage {
                    statusBanner(statusMessage)
                }

                TreeBoardContentsTable(
                    items: browserItems,
                    selection: $selection,
                    onOpen: open,
                    onCreateChild: onCreateChild,
                    onRename: onRename,
                    onDelete: onDelete,
                    isFavorite: isFavorite,
                    onToggleFavorite: onToggleFavorite,
                    onRemoveWindow: windowController.detach,
                    onCreateEmptyChild: { onCreateChild(board.id) },
                    currentBoardID: board.id,
                    onMoveBoard: onMoveBoard,
                    onMoveWindow: onMoveWindow
                )
            }
            .onChange(of: browserItems.map(\.id)) { _, validIDs in
                selection.formIntersection(Set(validIDs))
            }
        } else {
            ContentUnavailableView(
                "Root Board Unavailable",
                systemImage: "exclamationmark.triangle"
            )
        }
    }

    private var browserItems: [TreeBrowserItem] {
        directory.snapshot.childBoards.map { child in
            .board(
                child,
                childCount: directory.treeStore.childIDs(of: child.id).count
            )
        } + windowController.rows.map(TreeBrowserItem.window)
    }

    private func open(_ item: TreeBrowserItem) {
        switch item {
        case let .board(board, _):
            onOpenBoard(board.id)
        case let .window(row):
            guard row.state != .unavailable else {
                windowController.statusMessage = "Window is unavailable."
                return
            }
            Task { await windowController.showWindow(referenceID: row.id) }
        }
    }

    private func requestAccessibilityAccess() {
        windowController.requestAccessibilityAccess()
        Task { await windowController.refresh() }
    }

    private func statusBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
            Button {
                windowController.clearStatusMessage()
            } label: {
                Label("Dismiss", systemImage: "xmark")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.45))
    }
}
