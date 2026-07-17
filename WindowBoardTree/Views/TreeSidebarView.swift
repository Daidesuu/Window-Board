import SwiftUI

struct TreeSidebarView: View {
    @ObservedObject private var appState: TreeWindowBoardAppState
    @ObservedObject private var directory: BoardDirectoryController
    @ObservedObject private var treeStore: BoardTreeStore
    @ObservedObject private var workspaceStore: WorkspaceStore

    let onCreateChild: (SavedWorkspace.ID) -> Void
    let onRename: (SavedWorkspace.ID) -> Void
    let onDelete: (SavedWorkspace.ID) -> Void

    @State private var selectedLocation: TreeSidebarSelection?

    init(
        appState: TreeWindowBoardAppState,
        onCreateChild: @escaping (SavedWorkspace.ID) -> Void,
        onRename: @escaping (SavedWorkspace.ID) -> Void,
        onDelete: @escaping (SavedWorkspace.ID) -> Void
    ) {
        self.appState = appState
        _directory = ObservedObject(wrappedValue: appState.directory)
        _treeStore = ObservedObject(wrappedValue: appState.treeStore)
        _workspaceStore = ObservedObject(wrappedValue: appState.workspaceStore)
        self.onCreateChild = onCreateChild
        self.onRename = onRename
        self.onDelete = onDelete
    }

    var body: some View {
        List(selection: selection) {
            TreeFavoritesSidebarSection(
                boards: favoriteBoards,
                onOpen: openFavorite,
                onShowInTree: showInTree,
                onAdd: appState.addFavorite,
                onRemove: { _ = appState.removeFavorite($0) },
                onMove: appState.moveFavorite,
                onRename: onRename,
                onDelete: onDelete
            )

            Section("Boards") {
                ForEach(nodes) { node in
                    TreeSidebarNodeRow(
                        node: node,
                        isExpanded: expansionBinding(for: node.board.id),
                        isRoot: node.board.id == treeStore.data.rootBoardID,
                        onCreateChild: { onCreateChild(node.board.id) },
                        onRename: { onRename(node.board.id) },
                        onDelete: { onDelete(node.board.id) },
                        isFavorite: appState.isFavorite(node.board.id),
                        onToggleFavorite: {
                            if appState.isFavorite(node.board.id) {
                                _ = appState.removeFavorite(node.board.id)
                            } else {
                                _ = appState.addFavorite(node.board.id)
                            }
                        },
                        onMoveIntoBoard: { payload in
                            appState.moveBoard(payload.boardID, to: node.board.id)
                        },
                        onMoveWindowIntoBoard: { payload in
                            appState.windowController.moveWindow(
                                referenceID: payload.referenceID,
                                from: payload.sourceBoardID,
                                to: node.board.id
                            ) == .moved
                        },
                        onMoveBeforeBoard: node.parentID.map { parentID in
                            { payload in
                                appState.moveBoard(
                                    payload.boardID,
                                    to: parentID,
                                    at: node.siblingIndex
                                )
                            }
                        }
                    )
                    .tag(TreeSidebarSelection.board(node.board.id))
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
    }

    private var selection: Binding<TreeSidebarSelection?> {
        Binding(
            get: {
                if let selectedLocation,
                   selectedLocation.boardID == directory.currentBoardID {
                    return selectedLocation
                }
                return .board(directory.currentBoardID)
            },
            set: { location in
                guard let location else { return }
                selectedLocation = location
                _ = appState.selectBoard(location.boardID)
            }
        )
    }

    private var favoriteBoards: [SavedWorkspace] {
        let boardByID = Dictionary(
            uniqueKeysWithValues: workspaceStore.workspaces.map { ($0.id, $0) }
        )
        return treeStore.data.favoriteBoardIDs.compactMap { boardByID[$0] }
    }

    private var nodes: [TreeSidebarNode] {
        TreeSidebarProjection.nodes(
            tree: treeStore.data,
            workspaces: workspaceStore.workspaces,
            expandedBoardIDs: appState.expandedBoardIDs
        )
    }

    private func expansionBinding(for boardID: SavedWorkspace.ID) -> Binding<Bool> {
        Binding(
            get: { appState.isExpanded(boardID) },
            set: { appState.setExpanded($0, for: boardID) }
        )
    }

    private func openFavorite(_ boardID: SavedWorkspace.ID) {
        selectedLocation = .favorite(boardID)
        _ = appState.selectBoard(boardID)
    }

    private func showInTree(_ boardID: SavedWorkspace.ID) {
        selectedLocation = .board(boardID)
        _ = appState.selectBoard(boardID)
    }
}

private struct TreeSidebarNode: Identifiable {
    let board: SavedWorkspace
    let depth: Int
    let parentID: SavedWorkspace.ID?
    let siblingIndex: Int
    let childCount: Int

    var id: SavedWorkspace.ID { board.id }
}

private enum TreeSidebarProjection {
    static func nodes(
        tree: BoardTreeData,
        workspaces: [SavedWorkspace],
        expandedBoardIDs: Set<SavedWorkspace.ID>
    ) -> [TreeSidebarNode] {
        let boardByID = Dictionary(uniqueKeysWithValues: workspaces.map { ($0.id, $0) })
        var result: [TreeSidebarNode] = []

        func appendNode(
            _ boardID: SavedWorkspace.ID,
            depth: Int,
            parentID: SavedWorkspace.ID?,
            siblingIndex: Int
        ) {
            guard let board = boardByID[boardID] else { return }
            let childIDs = tree.childBoardIDsByParentID[boardID] ?? []
            result.append(
                TreeSidebarNode(
                    board: board,
                    depth: depth,
                    parentID: parentID,
                    siblingIndex: siblingIndex,
                    childCount: childIDs.count
                )
            )

            guard expandedBoardIDs.contains(boardID) else { return }
            for (index, childID) in childIDs.enumerated() {
                appendNode(childID, depth: depth + 1, parentID: boardID, siblingIndex: index)
            }
        }

        appendNode(tree.rootBoardID, depth: 0, parentID: nil, siblingIndex: 0)
        return result
    }
}

private struct TreeSidebarNodeRow: View {
    let node: TreeSidebarNode
    @Binding var isExpanded: Bool
    let isRoot: Bool
    let onCreateChild: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void
    let isFavorite: Bool
    let onToggleFavorite: () -> Void
    let onMoveIntoBoard: (TreeBoardDragPayload) -> Bool
    let onMoveWindowIntoBoard: (TreeWindowDragPayload) -> Bool
    let onMoveBeforeBoard: ((TreeBoardDragPayload) -> Bool)?

    var body: some View {
        VStack(spacing: 0) {
            if let onMoveBeforeBoard {
                TreeSidebarInsertionDropTarget(onDrop: onMoveBeforeBoard)
            }

            draggableRow
        }
        .listRowInsets(EdgeInsets(top: 1, leading: 8, bottom: 1, trailing: 8))
    }

    @ViewBuilder
    private var draggableRow: some View {
        if isRoot {
            row
        } else {
            row.draggable(TreeBoardDragPayload(boardID: node.board.id)) {
                TreeSidebarDragPreview(board: node.board)
            }
        }
    }

    private var row: some View {
        TreeSidebarBoardDropTarget(
            onBoardDrop: onMoveIntoBoard,
            onWindowDrop: onMoveWindowIntoBoard
        ) {
            HStack(spacing: 7) {
                Color.clear
                    .frame(width: CGFloat(node.depth) * 14)

                if node.childCount > 0 {
                    Button {
                        isExpanded.toggle()
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .frame(width: 12, height: 18)
                    }
                    .buttonStyle(.plain)
                    .help(isExpanded ? "Collapse Board" : "Expand Board")
                } else {
                    Color.clear.frame(width: 12, height: 18)
                }

                Image(systemName: isRoot ? "rectangle.stack.fill" : "rectangle.stack")
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 1) {
                    Text(node.board.name)
                        .lineLimit(1)
                    Text(metadata)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 4)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 3)
            .contextMenu {
                Button("New Child Board") {
                    onCreateChild()
                }

                Button("Rename Board") {
                    onRename()
                }
                .disabled(isRoot)

                Button(isFavorite ? "Remove from Favorites" : "Add to Favorites") {
                    onToggleFavorite()
                }

                Divider()

                Button("Delete Board", role: .destructive) {
                    onDelete()
                }
                .disabled(isRoot)
            }
        }
    }

    private var metadata: String {
        let windowCount = node.board.windows.count
        let windowLabel = "\(windowCount) \(windowCount == 1 ? "window" : "windows")"
        guard node.childCount > 0 else { return windowLabel }
        return "\(windowLabel) · \(node.childCount) \(node.childCount == 1 ? "child" : "children")"
    }
}

private struct TreeSidebarBoardDropTarget<Content: View>: View {
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
            .background {
                RoundedRectangle(cornerRadius: 6)
                    .fill(isTargeted ? Color.accentColor.opacity(0.14) : .clear)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isTargeted ? Color.accentColor.opacity(0.7) : .clear, lineWidth: 1)
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

private struct TreeSidebarInsertionDropTarget: View {
    let onDrop: (TreeBoardDragPayload) -> Bool
    @State private var isTargeted = false

    var body: some View {
        Rectangle()
            .fill(.clear)
            .frame(height: 8)
            .overlay {
                Capsule()
                    .fill(isTargeted ? Color.accentColor : .clear)
                    .frame(height: 2)
            }
            .contentShape(Rectangle())
            .dropDestination(for: TreeBoardDragPayload.self) { payloads, _ in
                guard let payload = payloads.first else { return false }
                return onDrop(payload)
            } isTargeted: { isTargeted = $0 }
    }
}

private struct TreeSidebarDragPreview: View {
    let board: SavedWorkspace

    var body: some View {
        Label(board.name, systemImage: "rectangle.stack")
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}
