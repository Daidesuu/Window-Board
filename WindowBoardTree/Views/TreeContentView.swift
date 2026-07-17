import SwiftUI

struct TreeContentView: View {
    @ObservedObject private var appState: TreeWindowBoardAppState
    @ObservedObject private var directory: BoardDirectoryController
    @ObservedObject private var windowController: TreeBoardWindowController

    @State private var editorRequest: TreeBoardEditorRequest?
    @State private var deletionRequest: TreeBoardDeletionRequest?

    init(appState: TreeWindowBoardAppState) {
        self.appState = appState
        _directory = ObservedObject(wrappedValue: appState.directory)
        _windowController = ObservedObject(wrappedValue: appState.windowController)
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .navigationTitle(directory.snapshot.currentBoard?.name ?? "WindowBoard Tree")
        .task(id: directory.currentBoardID) {
            await windowController.loadBoard(directory.currentBoardID)
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    presentCreateBoard(parentID: directory.currentBoardID)
                } label: {
                    Label("New Child Board", systemImage: "folder.badge.plus")
                }
                .help("Create a child Board")
                .keyboardShortcut("n", modifiers: .command)
            }

            ToolbarItemGroup(placement: .primaryAction) {
                addWindowMenu

                Button {
                    Task { await windowController.attachFrontmostWindow() }
                } label: {
                    Label("Attach Frontmost Window", systemImage: "macwindow.badge.plus")
                }
                .help("Attach the frontmost external window to this Board")
                .disabled(!windowController.isAccessibilityTrusted)

                Button {
                    Task { await windowController.refresh() }
                } label: {
                    Label("Refresh Windows", systemImage: "arrow.clockwise")
                }
                .help("Refresh external windows")
                .disabled(windowController.isRefreshing)

                boardActionsMenu
            }
        }
        .sheet(item: $editorRequest) { request in
            TreeBoardEditorView(request: request) { name in
                applyEditorRequest(request, name: name)
            }
        }
        .alert(
            deletionRequest?.title ?? "Delete Board?",
            isPresented: Binding(
                get: { deletionRequest != nil },
                set: { if !$0 { deletionRequest = nil } }
            ),
            presenting: deletionRequest
        ) { request in
            Button("Delete", role: .destructive) {
                _ = appState.deleteBoard(request.board.id)
                deletionRequest = nil
            }
            Button("Cancel", role: .cancel) {
                deletionRequest = nil
            }
        } message: { request in
            Text(request.message)
        }
        .alert(
            "Board Operation",
            isPresented: Binding(
                get: { appState.operationMessage != nil },
                set: { if !$0 { appState.clearOperationMessage() } }
            )
        ) {
            Button("OK") {
                appState.clearOperationMessage()
            }
        } message: {
            Text(appState.operationMessage ?? "")
        }
    }

    private var sidebar: some View {
        TreeSidebarView(
            appState: appState,
            onCreateChild: presentCreateBoard,
            onRename: presentRenameBoard,
            onDelete: presentDeleteBoard
        )
    }

    private var detail: some View {
        TreeBoardDetailView(
            directory: directory,
            windowController: windowController,
            onOpenBoard: selectBoard,
            onCreateChild: presentCreateBoard,
            onRename: presentRenameBoard,
            onDelete: presentDeleteBoard,
            isFavorite: appState.isFavorite,
            onToggleFavorite: toggleFavorite,
            onMoveBoard: moveBoard,
            onMoveWindow: moveWindow
        )
    }

    private func selectBoard(_ boardID: SavedWorkspace.ID) {
        _ = appState.selectBoard(boardID)
    }

    private func moveBoard(
        _ boardID: SavedWorkspace.ID,
        _ destinationBoardID: SavedWorkspace.ID
    ) -> Bool {
        appState.moveBoard(boardID, to: destinationBoardID)
    }

    private func moveWindow(
        _ payload: TreeWindowDragPayload,
        _ destinationBoardID: SavedWorkspace.ID
    ) -> Bool {
        windowController.moveWindow(
            referenceID: payload.referenceID,
            from: payload.sourceBoardID,
            to: destinationBoardID
        ) == .moved
    }

    private func toggleFavorite(_ boardID: SavedWorkspace.ID) {
        if appState.isFavorite(boardID) {
            _ = appState.removeFavorite(boardID)
        } else {
            _ = appState.addFavorite(boardID)
        }
    }

    private var addWindowMenu: some View {
        Menu {
            if windowController.candidates.isEmpty {
                Text("No external windows found")
            } else {
                ForEach(windowController.candidates) { window in
                    Button(window.displayName) {
                        Task { await windowController.attachWindow(id: window.id) }
                    }
                    .disabled(!windowController.canAttach(window))
                }
            }
        } label: {
            Label("Add Window", systemImage: "plus")
        }
        .help("Add an external window to this Board")
        .disabled(!windowController.isAccessibilityTrusted || windowController.isRefreshing)
    }

    private var boardActionsMenu: some View {
        Menu {
            Button(
                appState.isFavorite(directory.currentBoardID)
                    ? "Remove from Favorites"
                    : "Add to Favorites"
            ) {
                toggleFavorite(directory.currentBoardID)
            }

            Divider()

            Button("Rename Board") {
                presentRenameBoard(boardID: directory.currentBoardID)
            }
            .disabled(directory.currentBoardID == appState.treeStore.data.rootBoardID)

            Divider()

            Button("Delete Board", role: .destructive) {
                presentDeleteBoard(boardID: directory.currentBoardID)
            }
            .disabled(directory.currentBoardID == appState.treeStore.data.rootBoardID)
        } label: {
            Label("Board Actions", systemImage: "ellipsis.circle")
        }
        .help("Board actions")
    }

    private func presentCreateBoard(parentID: SavedWorkspace.ID) {
        guard let parent = appState.workspaceStore.workspaces.first(where: { $0.id == parentID }) else {
            return
        }
        editorRequest = .create(parent: parent)
    }

    private func presentRenameBoard(boardID: SavedWorkspace.ID) {
        guard let board = appState.workspaceStore.workspaces.first(where: { $0.id == boardID }),
              boardID != appState.treeStore.data.rootBoardID else {
            return
        }
        editorRequest = .rename(board: board)
    }

    private func presentDeleteBoard(boardID: SavedWorkspace.ID) {
        guard boardID != appState.treeStore.data.rootBoardID,
              let board = appState.workspaceStore.workspaces.first(where: { $0.id == boardID }) else {
            return
        }
        let descendantIDs = appState.treeStore.descendantIDs(of: boardID)
        let affectedIDs = descendantIDs.union([boardID])
        let windowCount = appState.workspaceStore.workspaces
            .filter { affectedIDs.contains($0.id) }
            .reduce(0) { $0 + $1.windows.count }
        deletionRequest = TreeBoardDeletionRequest(
            board: board,
            descendantCount: descendantIDs.count,
            windowCount: windowCount
        )
    }

    private func applyEditorRequest(_ request: TreeBoardEditorRequest, name: String) -> Bool {
        switch request.kind {
        case let .create(parentID):
            return appState.createBoard(name: name, under: parentID) != nil
        case let .rename(boardID):
            return appState.renameBoard(boardID, name: name)
        }
    }
}

private struct TreeBoardDeletionRequest: Identifiable {
    let board: SavedWorkspace
    let descendantCount: Int
    let windowCount: Int

    var id: SavedWorkspace.ID { board.id }
    var title: String { "Delete \(board.name)?" }

    var message: String {
        var affectedItems: [String] = []
        if descendantCount > 0 {
            affectedItems.append("\(descendantCount) child \(descendantCount == 1 ? "Board" : "Boards")")
        }
        if windowCount > 0 {
            affectedItems.append("\(windowCount) saved \(windowCount == 1 ? "window" : "windows")")
        }

        let detail = affectedItems.isEmpty
            ? "This Board is empty."
            : "This also removes " + affectedItems.joined(separator: " and ") + "."
        return "\(detail) External application windows will not be closed. This action cannot be undone."
    }
}
