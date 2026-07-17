import SwiftUI

enum TreeSidebarSelection: Hashable {
    case board(SavedWorkspace.ID)
    case favorite(SavedWorkspace.ID)

    var boardID: SavedWorkspace.ID {
        switch self {
        case let .board(boardID), let .favorite(boardID):
            boardID
        }
    }
}

struct TreeFavoritesSidebarSection: View {
    let boards: [SavedWorkspace]
    let onOpen: (SavedWorkspace.ID) -> Void
    let onShowInTree: (SavedWorkspace.ID) -> Void
    let onAdd: (SavedWorkspace.ID) -> Bool
    let onRemove: (SavedWorkspace.ID) -> Void
    let onMove: (SavedWorkspace.ID, Int) -> Bool
    let onRename: (SavedWorkspace.ID) -> Void
    let onDelete: (SavedWorkspace.ID) -> Void

    var body: some View {
        Section("Favorites") {
            if boards.isEmpty {
                TreeEmptyFavoritesDropTarget(onDrop: { onAdd($0.boardID) })
            } else {
                ForEach(Array(boards.enumerated()), id: \.element.id) { index, board in
                    TreeFavoriteInsertionDropTarget(index: index, onMove: onMove)

                    favoriteRow(board)
                        .tag(TreeSidebarSelection.favorite(board.id))
                }

                TreeFavoriteInsertionDropTarget(index: boards.count, onMove: onMove)
            }
        }
    }

    private func favoriteRow(_ board: SavedWorkspace) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "star.fill")
                .foregroundStyle(.secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(board.name)
                    .lineLimit(1)
                Text(windowCountLabel(board.windows.count))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 3)
        .contextMenu {
            Button("Open Board") {
                onOpen(board.id)
            }
            Button("Show in Board Tree") {
                onShowInTree(board.id)
            }

            Divider()

            Button("Remove from Favorites") {
                onRemove(board.id)
            }
            Button("Rename Board") {
                onRename(board.id)
            }

            Divider()

            Button("Delete Board", role: .destructive) {
                onDelete(board.id)
            }
        }
        .draggable(TreeFavoriteDragPayload(boardID: board.id)) {
            Label(board.name, systemImage: "star.fill")
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        }
        .dropDestination(for: TreeBoardDragPayload.self) { payloads, _ in
            guard let payload = payloads.first else { return false }
            return onAdd(payload.boardID)
        }
        .listRowInsets(EdgeInsets(top: 1, leading: 8, bottom: 1, trailing: 8))
    }

    private func windowCountLabel(_ count: Int) -> String {
        "\(count) \(count == 1 ? "window" : "windows")"
    }
}

private struct TreeEmptyFavoritesDropTarget: View {
    let onDrop: (TreeBoardDragPayload) -> Bool
    @State private var isTargeted = false

    var body: some View {
        Label("Drop a Board here", systemImage: "star")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background {
                RoundedRectangle(cornerRadius: 6)
                    .fill(isTargeted ? Color.accentColor.opacity(0.14) : .clear)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isTargeted ? Color.accentColor.opacity(0.7) : .clear, lineWidth: 1)
            }
            .contentShape(Rectangle())
            .dropDestination(for: TreeBoardDragPayload.self) { payloads, _ in
                guard let payload = payloads.first else { return false }
                return onDrop(payload)
            } isTargeted: { isTargeted = $0 }
            .listRowInsets(EdgeInsets(top: 1, leading: 8, bottom: 1, trailing: 8))
    }
}

private struct TreeFavoriteInsertionDropTarget: View {
    let index: Int
    let onMove: (SavedWorkspace.ID, Int) -> Bool
    @State private var isTargeted = false

    var body: some View {
        Rectangle()
            .fill(.clear)
            .frame(height: 6)
            .overlay {
                Capsule()
                    .fill(isTargeted ? Color.accentColor : .clear)
                    .frame(height: 2)
            }
            .contentShape(Rectangle())
            .dropDestination(for: TreeFavoriteDragPayload.self) { payloads, _ in
                guard let payload = payloads.first else { return false }
                return onMove(payload.boardID, index)
            } isTargeted: { isTargeted = $0 }
            .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
    }
}
