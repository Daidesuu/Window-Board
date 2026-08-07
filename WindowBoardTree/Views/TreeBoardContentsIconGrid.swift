import AppKit
import SwiftUI

struct TreeBoardContentsIconGrid: View {
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
    let windowCandidates: [WindowInfo]
    let canAttachWindow: (WindowInfo) -> Bool
    let onAttachWindow: (WindowInfo.ID) -> Void
    let canAddWindow: Bool
    let currentBoardID: SavedWorkspace.ID
    let onMoveBoard: (SavedWorkspace.ID, SavedWorkspace.ID) -> Bool
    let onMoveWindow: (TreeWindowDragPayload, SavedWorkspace.ID) -> Bool

    @State private var lastClickedItemID: TreeBrowserItem.ID?
    @State private var lastClickTime: TimeInterval = 0
    @FocusState private var isGridFocused: Bool

    private let columns = [
        GridItem(.adaptive(minimum: 104, maximum: 132), spacing: 18, alignment: .top)
    ]

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
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        isGridFocused = true
                        selection.removeAll()
                    }

                if items.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 22) {
                            ForEach(items) { item in
                                draggableItem(item)
                            }
                        }
                        .padding(20)
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .focusable()
            .focused($isGridFocused)
        }
        .contextMenu {
            Button("New Child Board", action: onCreateEmptyChild)
            addWindowMenu
        }
        .onKeyPress(.return) {
            renameSelection()
        }
        .onKeyPress(phases: .down) { keyPress in
            guard keyPress.characters == "a",
                  keyPress.modifiers.contains(.command) else {
                return .ignored
            }
            selection = Set(items.map(\.id))
            return .handled
        }
        .onDeleteCommand(perform: deleteSelection)
    }

    @ViewBuilder
    private func draggableItem(_ item: TreeBrowserItem) -> some View {
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
                itemView(item)
            }
            .draggable(TreeBoardDragPayload(boardID: board.id)) {
                TreeBrowserDragPreview(name: board.name, systemImage: "folder")
            }

        case let .window(row):
            itemView(item)
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

    private func itemView(_ item: TreeBrowserItem) -> some View {
        VStack(spacing: 7) {
            TreeItemIconView(item: item)

            Text(item.name)
                .font(.callout)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .foregroundStyle(selection.contains(item.id) ? Color.white : Color.primary)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(selection.contains(item.id) ? Color.accentColor : .clear)
                }
        }
        .frame(width: 104)
        .frame(minHeight: 88, alignment: .top)
        .contentShape(Rectangle())
        .onTapGesture {
            handleClick(on: item)
        }
        .contextMenu {
            itemContextMenu(item)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.name)
        .accessibilityValue(selection.contains(item.id) ? "Selected" : "")
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("This Board is Empty", systemImage: "rectangle.stack.badge.plus")
        } description: {
            Text("Create a child Board or attach an external window.")
        } actions: {
            Button("New Child Board", action: onCreateEmptyChild)
            addWindowMenu
        }
    }

    private var addWindowMenu: some View {
        Menu("Add Window") {
            if windowCandidates.isEmpty {
                Text("No external windows found")
            } else {
                ForEach(windowCandidates) { window in
                    Button(window.displayName) {
                        onAttachWindow(window.id)
                    }
                    .disabled(!canAttachWindow(window))
                }
            }
        }
        .disabled(!canAddWindow)
    }

    private func handleClick(on item: TreeBrowserItem) {
        let now = ProcessInfo.processInfo.systemUptime
        let isDoubleClick = lastClickedItemID == item.id
            && now - lastClickTime <= NSEvent.doubleClickInterval

        isGridFocused = true
        if NSEvent.modifierFlags.contains(.command) {
            if selection.contains(item.id) {
                selection.remove(item.id)
            } else {
                selection.insert(item.id)
            }
        } else {
            selection = [item.id]
        }

        if isDoubleClick {
            lastClickedItemID = nil
            lastClickTime = 0
            onOpen(item)
        } else {
            lastClickedItemID = item.id
            lastClickTime = now
        }
    }

    @ViewBuilder
    private func itemContextMenu(_ item: TreeBrowserItem) -> some View {
        switch item {
        case let .board(board, _):
            Button("Open Board") { onOpen(item) }
            Button("New Child Board") { onCreateChild(board.id) }
            Button("Rename Board") { onRename(board.id) }
            Button(isFavorite(board.id) ? "Remove from Favorites" : "Add to Favorites") {
                onToggleFavorite(board.id)
            }
            Divider()
            Button("Delete Board", role: .destructive) { onDelete(board.id) }

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

    private func renameSelection() -> KeyPress.Result {
        guard let selectedID = selection.first,
              let item = items.first(where: { $0.id == selectedID }),
              case let .board(board, _) = item else {
            return .ignored
        }
        onRename(board.id)
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
