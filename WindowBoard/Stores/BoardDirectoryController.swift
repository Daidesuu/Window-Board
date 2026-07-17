import Combine
import Foundation

struct BoardDirectorySnapshot: Equatable {
    let rootBoard: SavedWorkspace?
    let currentBoard: SavedWorkspace?
    let parentBoard: SavedWorkspace?
    let breadcrumbs: [SavedWorkspace]
    let childBoards: [SavedWorkspace]
    let windows: [SavedWindowReference]
    let favoriteBoards: [SavedWorkspace]

    var canMoveCurrentBoard: Bool {
        guard let rootBoard, let currentBoard else { return false }
        return rootBoard.id != currentBoard.id
    }

    var canDeleteCurrentBoard: Bool {
        canMoveCurrentBoard
    }
}

enum BoardDirectoryResolver {
    static func resolve(
        tree: BoardTreeData,
        workspaces: [SavedWorkspace],
        currentBoardID: SavedWorkspace.ID
    ) -> BoardDirectorySnapshot {
        let workspaceByID = Dictionary(uniqueKeysWithValues: workspaces.map { ($0.id, $0) })
        let rootBoard = workspaceByID[tree.rootBoardID]
        let resolvedCurrentBoardID = workspaceByID[currentBoardID] != nil
            && contains(currentBoardID, in: tree)
            ? currentBoardID
            : tree.rootBoardID
        let currentBoard = workspaceByID[resolvedCurrentBoardID]
        let parentID = parentID(of: resolvedCurrentBoardID, in: tree)
        let breadcrumbIDs = pathIDs(to: resolvedCurrentBoardID, in: tree)

        return BoardDirectorySnapshot(
            rootBoard: rootBoard,
            currentBoard: currentBoard,
            parentBoard: parentID.flatMap { workspaceByID[$0] },
            breadcrumbs: breadcrumbIDs.compactMap { workspaceByID[$0] },
            childBoards: (tree.childBoardIDsByParentID[resolvedCurrentBoardID] ?? [])
                .compactMap { workspaceByID[$0] },
            windows: currentBoard?.windows ?? [],
            favoriteBoards: tree.favoriteBoardIDs.compactMap { workspaceByID[$0] }
        )
    }

    static func contains(_ boardID: SavedWorkspace.ID, in tree: BoardTreeData) -> Bool {
        !pathIDs(to: boardID, in: tree).isEmpty
    }

    static func parentID(
        of boardID: SavedWorkspace.ID,
        in tree: BoardTreeData
    ) -> SavedWorkspace.ID? {
        guard boardID != tree.rootBoardID else { return nil }
        return tree.childBoardIDsByParentID.first { _, childIDs in
            childIDs.contains(boardID)
        }?.key
    }

    static func pathIDs(
        to boardID: SavedWorkspace.ID,
        in tree: BoardTreeData
    ) -> [SavedWorkspace.ID] {
        guard boardID != tree.rootBoardID else { return [tree.rootBoardID] }

        var path = [boardID]
        var currentID = boardID
        var visited: Set<SavedWorkspace.ID> = [boardID]

        while let parentID = parentID(
            of: currentID,
            in: tree
        ) {
            guard visited.insert(parentID).inserted else { return [] }
            path.append(parentID)
            currentID = parentID
        }

        guard path.last == tree.rootBoardID else { return [] }
        return path.reversed()
    }
}

@MainActor
final class BoardDirectoryController: ObservableObject {
    @Published private(set) var currentBoardID: SavedWorkspace.ID
    @Published private(set) var snapshot: BoardDirectorySnapshot

    let workspaceStore: WorkspaceStore
    let treeStore: BoardTreeStore

    private var cancellables: Set<AnyCancellable> = []
    private var lastKnownPathIDs: [SavedWorkspace.ID]
    private var isReconciling = false
    private var isApplyingTreeMutation = false

    init(
        workspaceStore: WorkspaceStore,
        treeStore: BoardTreeStore,
        initialBoardID: SavedWorkspace.ID? = nil
    ) {
        self.workspaceStore = workspaceStore
        self.treeStore = treeStore

        let requestedBoardID = initialBoardID ?? treeStore.data.rootBoardID
        let validInitialBoardID = treeStore.contains(requestedBoardID)
            && workspaceStore.workspaces.contains(where: { $0.id == requestedBoardID })
            ? requestedBoardID
            : treeStore.data.rootBoardID
        currentBoardID = validInitialBoardID
        lastKnownPathIDs = treeStore.pathIDs(to: validInitialBoardID)
        snapshot = BoardDirectoryResolver.resolve(
            tree: treeStore.data,
            workspaces: workspaceStore.workspaces,
            currentBoardID: validInitialBoardID
        )

        workspaceStore.$workspaces
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] workspaces in
                self?.reconcile(using: workspaces)
            }
            .store(in: &cancellables)

        treeStore.$data
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] tree in
                guard let self, !self.isReconciling, !self.isApplyingTreeMutation else { return }
                self.refreshSnapshot(tree: tree, workspaces: self.workspaceStore.workspaces)
            }
            .store(in: &cancellables)
    }

    @discardableResult
    func openBoard(_ boardID: SavedWorkspace.ID) -> Bool {
        guard treeStore.contains(boardID),
              workspaceStore.workspaces.contains(where: { $0.id == boardID }) else {
            return false
        }
        currentBoardID = boardID
        refreshSnapshot()
        return true
    }

    @discardableResult
    func openParent() -> Bool {
        guard let parentID = treeStore.parentID(of: currentBoardID) else { return false }
        return openBoard(parentID)
    }

    func openRoot() {
        _ = openBoard(treeStore.data.rootBoardID)
    }

    @discardableResult
    func createBoard(
        name: String,
        under parentID: SavedWorkspace.ID? = nil
    ) -> SavedWorkspace? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return nil }

        let resolvedParentID = parentID ?? currentBoardID
        guard treeStore.contains(resolvedParentID) else { return nil }

        let workspace = workspaceStore.saveWorkspace(name: trimmedName, windows: [])
        let insertionResult = performTreeMutation {
            treeStore.insertBoard(workspace.id, under: resolvedParentID)
        }
        guard insertionResult == .inserted else {
            workspaceStore.deleteWorkspace(id: workspace.id)
            return nil
        }
        refreshSnapshot()
        return workspace
    }

    @discardableResult
    func renameBoard(id boardID: SavedWorkspace.ID, name: String) -> Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty,
              boardID != treeStore.data.rootBoardID,
              workspaceStore.workspaces.first(where: { $0.id == boardID })?.isDefault != true,
              workspaceStore.updateWorkspace(id: boardID, name: trimmedName) != nil else {
            return false
        }
        refreshSnapshot()
        return true
    }

    @discardableResult
    func moveBoard(
        _ boardID: SavedWorkspace.ID,
        to parentID: SavedWorkspace.ID,
        at index: Int? = nil
    ) -> BoardTreeMutationResult {
        let result = performTreeMutation {
            treeStore.moveBoard(boardID, to: parentID, at: index)
        }
        if result == .moved || result == .reordered {
            refreshSnapshot()
        }
        return result
    }

    @discardableResult
    func deleteBoard(_ boardID: SavedWorkspace.ID) -> BoardTreeMutationResult {
        guard boardID != treeStore.data.rootBoardID else { return .rootImmutable }
        guard treeStore.contains(boardID) else { return .missingBoard }

        let parentID = treeStore.parentID(of: boardID) ?? treeStore.data.rootBoardID
        let removedBoardIDs = treeStore.descendantIDs(of: boardID).union([boardID])
        let shouldMoveCurrentBoard = removedBoardIDs.contains(currentBoardID)
        let result = performTreeMutation {
            treeStore.removeSubtreeReferences(rootedAt: boardID)
        }
        guard result == .removed else { return result }

        removedBoardIDs.forEach { workspaceStore.deleteWorkspace(id: $0) }
        if shouldMoveCurrentBoard {
            currentBoardID = parentID
        }
        reconcile()
        return .removed
    }

    @discardableResult
    func addFavorite(_ boardID: SavedWorkspace.ID, at index: Int? = nil) -> BoardTreeMutationResult {
        let result = performTreeMutation {
            treeStore.addFavorite(boardID, at: index)
        }
        if result == .inserted {
            refreshSnapshot()
        }
        return result
    }

    @discardableResult
    func removeFavorite(_ boardID: SavedWorkspace.ID) -> BoardTreeMutationResult {
        let result = performTreeMutation {
            treeStore.removeFavorite(boardID)
        }
        if result == .removed {
            refreshSnapshot()
        }
        return result
    }

    @discardableResult
    func moveFavorite(_ boardID: SavedWorkspace.ID, to index: Int) -> BoardTreeMutationResult {
        let result = performTreeMutation {
            treeStore.moveFavorite(boardID, to: index)
        }
        if result == .reordered {
            refreshSnapshot()
        }
        return result
    }

    func reconcile() {
        reconcile(using: workspaceStore.workspaces)
    }

    private func reconcile(using workspaces: [SavedWorkspace]) {
        guard !isReconciling else { return }
        isReconciling = true
        defer { isReconciling = false }

        let previousTree = treeStore.data
        let previousPathIDs = BoardDirectoryResolver.contains(currentBoardID, in: previousTree)
            ? BoardDirectoryResolver.pathIDs(to: currentBoardID, in: previousTree)
            : lastKnownPathIDs
        let availableBoardIDs = Set(workspaces.map(\.id))
        treeStore.reconcile(availableBoardIDs: availableBoardIDs)
        let normalizedTree = treeStore.data

        currentBoardID = previousPathIDs.reversed().first { boardID in
            BoardDirectoryResolver.contains(boardID, in: normalizedTree)
                && availableBoardIDs.contains(boardID)
        } ?? normalizedTree.rootBoardID
        refreshSnapshot(tree: normalizedTree, workspaces: workspaces)
    }

    private func refreshSnapshot(
        tree: BoardTreeData? = nil,
        workspaces: [SavedWorkspace]? = nil
    ) {
        let resolvedTree = tree ?? treeStore.data
        let resolvedWorkspaces = workspaces ?? workspaceStore.workspaces
        let availableBoardIDs = Set(resolvedWorkspaces.map(\.id))
        if !BoardDirectoryResolver.contains(currentBoardID, in: resolvedTree)
            || !availableBoardIDs.contains(currentBoardID) {
            currentBoardID = lastKnownPathIDs.reversed().first { boardID in
                BoardDirectoryResolver.contains(boardID, in: resolvedTree)
                    && availableBoardIDs.contains(boardID)
            } ?? resolvedTree.rootBoardID
        }

        let pathIDs = BoardDirectoryResolver.pathIDs(to: currentBoardID, in: resolvedTree)
        if !pathIDs.isEmpty {
            lastKnownPathIDs = pathIDs
        }
        snapshot = BoardDirectoryResolver.resolve(
            tree: resolvedTree,
            workspaces: resolvedWorkspaces,
            currentBoardID: currentBoardID
        )
    }

    private func performTreeMutation<Result>(_ operation: () -> Result) -> Result {
        isApplyingTreeMutation = true
        defer { isApplyingTreeMutation = false }
        return operation()
    }
}
