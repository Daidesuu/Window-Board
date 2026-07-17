import SwiftUI

struct TreeBoardContentsTable: View {
    let items: [TreeBrowserItem]
    @Binding var selection: Set<TreeBrowserItem.ID>

    let onOpen: (TreeBrowserItem) -> Void
    let onCreateChild: (SavedWorkspace.ID) -> Void
    let onRename: (SavedWorkspace.ID) -> Void
    let onDelete: (SavedWorkspace.ID) -> Void
    let isFavorite: (SavedWorkspace.ID) -> Bool
    let onToggleFavorite: (SavedWorkspace.ID) -> Void
    let onRemoveWindow: (SavedWindowReference.ID) -> Void
    let onCreateEmptyChild: () -> Void
    let currentBoardID: SavedWorkspace.ID
    let onMoveBoard: (SavedWorkspace.ID, SavedWorkspace.ID) -> Bool
    let onMoveWindow: (TreeWindowDragPayload, SavedWorkspace.ID) -> Bool

    var body: some View {
        TreeCurrentBoardDropTarget(
            onBoardDrop: { payload in
                onMoveBoard(payload.boardID, currentBoardID)
            },
            onWindowDrop: { payload in
                onMoveWindow(payload, currentBoardID)
            }
        ) {
            ZStack {
                Table(items, selection: $selection) {
                    TableColumn("Name") { item in
                        nameCell(item)
                    }
                    .width(min: 220, ideal: 360)

                    TableColumn("Kind") { item in
                        Text(item.kind)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .width(min: 110, ideal: 150)

                    TableColumn("Status") { item in
                        statusCell(item)
                    }
                    .width(min: 130, ideal: 180)
                }

                if items.isEmpty {
                    ContentUnavailableView {
                        Label("This Board is Empty", systemImage: "rectangle.stack.badge.plus")
                    } description: {
                        Text("Create a child Board or attach an external window.")
                    } actions: {
                        Button("New Child Board", action: onCreateEmptyChild)
                    }
                }
            }
        }
        .onKeyPress(.return) {
            openSelection()
        }
        .onDeleteCommand(perform: deleteSelection)
    }

    @ViewBuilder
    private func nameCell(_ item: TreeBrowserItem) -> some View {
        switch item {
        case let .board(board, _):
            TreeBrowserBoardDropTarget(
                onBoardDrop: { payload in
                    onMoveBoard(payload.boardID, board.id)
                },
                onWindowDrop: { payload in
                    onMoveWindow(payload, board.id)
                }
            ) {
                baseNameCell(item)
            }
            .draggable(TreeBoardDragPayload(boardID: board.id)) {
                TreeBrowserDragPreview(name: board.name, systemImage: "folder")
            }

        case let .window(row):
            baseNameCell(item)
                .draggable(
                    TreeWindowDragPayload(
                        referenceID: row.id,
                        sourceBoardID: currentBoardID
                    )
                ) {
                    TreeBrowserDragPreview(name: item.name, systemImage: "macwindow")
                }
        }
    }

    private func baseNameCell(_ item: TreeBrowserItem) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon(for: item))
                .foregroundStyle(iconStyle(for: item))
                .frame(width: 18)

            Text(item.name)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            onOpen(item)
        }
        .contextMenu {
            itemContextMenu(item)
        }
    }

    @ViewBuilder
    private func statusCell(_ item: TreeBrowserItem) -> some View {
        switch item {
        case .board:
            Text(item.status)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        case let .window(row):
            Label(item.status, systemImage: row.state.systemImage)
                .foregroundStyle(row.state == .unavailable ? .orange : .secondary)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private func itemContextMenu(_ item: TreeBrowserItem) -> some View {
        switch item {
        case let .board(board, _):
            Button("Open Board") {
                onOpen(item)
            }
            Button("New Child Board") {
                onCreateChild(board.id)
            }
            Button("Rename Board") {
                onRename(board.id)
            }
            Button(isFavorite(board.id) ? "Remove from Favorites" : "Add to Favorites") {
                onToggleFavorite(board.id)
            }
            Divider()
            Button("Delete Board", role: .destructive) {
                onDelete(board.id)
            }

        case let .window(row):
            Button(row.state == .minimized ? "Restore Window" : "Show Window") {
                onOpen(item)
            }
            .disabled(row.state == .unavailable)
            Divider()
            Button("Remove from Board", role: .destructive) {
                onRemoveWindow(row.id)
            }
        }
    }

    private func icon(for item: TreeBrowserItem) -> String {
        switch item {
        case .board: "folder"
        case .window: "macwindow"
        }
    }

    private func iconStyle(for item: TreeBrowserItem) -> AnyShapeStyle {
        switch item {
        case .board:
            AnyShapeStyle(Color.accentColor)
        case let .window(row):
            AnyShapeStyle(row.state == .unavailable ? Color.secondary : Color.primary)
        }
    }

    private func openSelection() -> KeyPress.Result {
        guard let selectedID = selection.first,
              let item = items.first(where: { $0.id == selectedID }) else {
            return .ignored
        }
        onOpen(item)
        return .handled
    }

    private func deleteSelection() {
        guard let selectedID = selection.first,
              let item = items.first(where: { $0.id == selectedID }) else {
            return
        }

        switch item {
        case let .board(board, _):
            onDelete(board.id)
        case let .window(row):
            onRemoveWindow(row.id)
        }
    }
}

private struct TreeBrowserBoardDropTarget<Content: View>: View {
    let onBoardDrop: (TreeBoardDragPayload) -> Bool
    let onWindowDrop: (TreeWindowDragPayload) -> Bool
    @ViewBuilder let content: () -> Content

    @State private var isBoardTargeted = false
    @State private var isWindowTargeted = false

    private var isTargeted: Bool {
        isBoardTargeted || isWindowTargeted
    }

    var body: some View {
        content()
            .padding(.horizontal, 3)
            .background {
                RoundedRectangle(cornerRadius: 5)
                    .fill(isTargeted ? Color.accentColor.opacity(0.14) : .clear)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .stroke(
                        isTargeted ? Color.accentColor.opacity(0.65) : .clear,
                        lineWidth: 1
                    )
                    .allowsHitTesting(false)
            }
            .dropDestination(for: TreeBoardDragPayload.self) { payloads, _ in
                guard let payload = payloads.first else { return false }
                return onBoardDrop(payload)
            } isTargeted: { isBoardTargeted = $0 }
            .dropDestination(for: TreeWindowDragPayload.self) { payloads, _ in
                guard let payload = payloads.first else { return false }
                return onWindowDrop(payload)
            } isTargeted: { isWindowTargeted = $0 }
    }
}

private struct TreeCurrentBoardDropTarget<Content: View>: View {
    let onBoardDrop: (TreeBoardDragPayload) -> Bool
    let onWindowDrop: (TreeWindowDragPayload) -> Bool
    @ViewBuilder let content: () -> Content

    @State private var isBoardTargeted = false
    @State private var isWindowTargeted = false

    private var isTargeted: Bool {
        isBoardTargeted || isWindowTargeted
    }

    var body: some View {
        content()
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(
                        isTargeted ? Color.accentColor.opacity(0.75) : .clear,
                        lineWidth: 2
                    )
                    .padding(3)
                    .allowsHitTesting(false)
            }
            .dropDestination(for: TreeBoardDragPayload.self) { payloads, _ in
                guard let payload = payloads.first else { return false }
                return onBoardDrop(payload)
            } isTargeted: { isBoardTargeted = $0 }
            .dropDestination(for: TreeWindowDragPayload.self) { payloads, _ in
                guard let payload = payloads.first else { return false }
                return onWindowDrop(payload)
            } isTargeted: { isWindowTargeted = $0 }
    }
}

private struct TreeBrowserDragPreview: View {
    let name: String
    let systemImage: String

    var body: some View {
        Label(name, systemImage: systemImage)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}
