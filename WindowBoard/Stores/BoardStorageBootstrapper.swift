import Foundation

enum BoardStorageKeys {
    static let generation = "boardStorageGeneration"
    static let workspaces = "savedWorkspaces"
    static let legacyComposition = "boardComposition.v2"
    static let legacyIncludedBoards = "includedBoardIDs"
    static let legacyNeverMinimizeWindows = "neverMinimizeWindows"
    static let tree = "boardTree.v1"
    static let activeBoardID = "activeWorkspaceID"
    static let treeSelectedBoardID = "treeSelectedBoardID"
    static let treeExpandedBoardIDs = "treeExpandedBoardIDs"
}

struct BoardStorageBootstrapResult: Equatable {
    let rootBoardID: SavedWorkspace.ID
    let didInitialize: Bool
}

enum BoardStorageBootstrapper {
    static let currentGeneration = 1
    static let rootBoardName = "Root Board"

    static func prepareDirectoryTreeStorage(
        defaults: UserDefaults,
        now: Date = Date(),
        id: () -> UUID = UUID.init,
        encodeWorkspaces: ([SavedWorkspace]) throws -> Data = { try JSONEncoder().encode($0) },
        encodeTree: (BoardTreeData) throws -> Data = { try JSONEncoder().encode($0) }
    ) throws -> BoardStorageBootstrapResult {
        if let existingRootID = validExistingRootID(defaults: defaults) {
            return BoardStorageBootstrapResult(rootBoardID: existingRootID, didInitialize: false)
        }

        let rootBoardID = id()
        let rootBoard = SavedWorkspace(
            id: rootBoardID,
            name: rootBoardName,
            statusItemSymbolName: nil,
            createdAt: now,
            updatedAt: now,
            windows: [],
            isDefault: true
        )
        let tree = BoardTreeData(rootBoardID: rootBoardID)

        // Finish all throwable work before replacing any existing Board data.
        let encodedWorkspaces = try encodeWorkspaces([rootBoard])
        let encodedTree = try encodeTree(tree)

        defaults.removeObject(forKey: BoardStorageKeys.generation)
        resetBoardStorageKeys(defaults: defaults)
        defaults.set(encodedWorkspaces, forKey: BoardStorageKeys.workspaces)
        defaults.set(encodedTree, forKey: BoardStorageKeys.tree)
        defaults.removeObject(forKey: BoardStorageKeys.activeBoardID)
        defaults.set(currentGeneration, forKey: BoardStorageKeys.generation)

        return BoardStorageBootstrapResult(rootBoardID: rootBoardID, didInitialize: true)
    }

    private static func validExistingRootID(defaults: UserDefaults) -> SavedWorkspace.ID? {
        guard defaults.integer(forKey: BoardStorageKeys.generation) == currentGeneration,
              let workspaceData = defaults.data(forKey: BoardStorageKeys.workspaces),
              let workspaces = try? JSONDecoder().decode([SavedWorkspace].self, from: workspaceData),
              workspaces.filter(\.isDefault).count == 1,
              let rootBoard = workspaces.first(where: \.isDefault),
              rootBoard.name == rootBoardName,
              rootBoard.isDefault,
              let treeData = defaults.data(forKey: BoardStorageKeys.tree),
              let tree = try? JSONDecoder().decode(BoardTreeData.self, from: treeData),
              tree.version == BoardTreeData.currentVersion,
              tree.rootBoardID == rootBoard.id else {
            return nil
        }
        return rootBoard.id
    }

    private static func resetBoardStorageKeys(defaults: UserDefaults) {
        [
            BoardStorageKeys.workspaces,
            BoardStorageKeys.legacyComposition,
            BoardStorageKeys.legacyIncludedBoards,
            BoardStorageKeys.legacyNeverMinimizeWindows,
            BoardStorageKeys.tree,
            BoardStorageKeys.activeBoardID,
            BoardStorageKeys.treeSelectedBoardID,
            BoardStorageKeys.treeExpandedBoardIDs
        ].forEach { defaults.removeObject(forKey: $0) }
    }
}
