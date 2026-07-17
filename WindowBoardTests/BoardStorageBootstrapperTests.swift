import XCTest
@testable import WindowBoard

@MainActor
final class BoardStorageBootstrapperTests: XCTestCase {
    func testBootstrapCreatesRootTreeAndRemovesOnlyBoardData() throws {
        let context = makeDefaults()
        defer { context.defaults.removePersistentDomain(forName: context.suiteName) }
        let rootID = UUID()
        let activeID = UUID()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        context.defaults.set(Data("old-workspaces".utf8), forKey: BoardStorageKeys.workspaces)
        context.defaults.set(Data("old-composition".utf8), forKey: BoardStorageKeys.legacyComposition)
        context.defaults.set([UUID().uuidString], forKey: BoardStorageKeys.legacyIncludedBoards)
        context.defaults.set(Data("old-never-minimize".utf8), forKey: BoardStorageKeys.legacyNeverMinimizeWindows)
        context.defaults.set(Data("old-tree".utf8), forKey: BoardStorageKeys.tree)
        context.defaults.set(activeID.uuidString, forKey: BoardStorageKeys.activeBoardID)
        context.defaults.set(activeID.uuidString, forKey: BoardStorageKeys.treeSelectedBoardID)
        context.defaults.set([activeID.uuidString], forKey: BoardStorageKeys.treeExpandedBoardIDs)
        context.defaults.set("smooth", forKey: "followMode")
        context.defaults.set(true, forKey: "boardAlwaysOnTop")

        let result = try BoardStorageBootstrapper.prepareDirectoryTreeStorage(
            defaults: context.defaults,
            now: now,
            id: { rootID }
        )

        XCTAssertEqual(result, BoardStorageBootstrapResult(rootBoardID: rootID, didInitialize: true))
        let workspaces = try decodedWorkspaces(from: context.defaults)
        let rootBoard = try XCTUnwrap(workspaces.first)
        XCTAssertEqual(workspaces.count, 1)
        XCTAssertEqual(rootBoard.id, rootID)
        XCTAssertEqual(rootBoard.name, BoardStorageBootstrapper.rootBoardName)
        XCTAssertEqual(rootBoard.createdAt, now)
        XCTAssertEqual(rootBoard.updatedAt, now)
        XCTAssertTrue(rootBoard.windows.isEmpty)
        XCTAssertTrue(rootBoard.isDefault)

        let tree = try decodedTree(from: context.defaults)
        XCTAssertEqual(tree, BoardTreeData(rootBoardID: rootID))
        XCTAssertEqual(context.defaults.integer(forKey: BoardStorageKeys.generation), 1)
        XCTAssertNil(context.defaults.object(forKey: BoardStorageKeys.legacyComposition))
        XCTAssertNil(context.defaults.object(forKey: BoardStorageKeys.legacyIncludedBoards))
        XCTAssertNil(context.defaults.object(forKey: BoardStorageKeys.legacyNeverMinimizeWindows))
        XCTAssertNil(context.defaults.string(forKey: BoardStorageKeys.activeBoardID))
        XCTAssertNil(context.defaults.string(forKey: BoardStorageKeys.treeSelectedBoardID))
        XCTAssertNil(context.defaults.stringArray(forKey: BoardStorageKeys.treeExpandedBoardIDs))
        XCTAssertEqual(context.defaults.string(forKey: "followMode"), "smooth")
        XCTAssertTrue(context.defaults.bool(forKey: "boardAlwaysOnTop"))
    }

    func testBootstrapIsIdempotentAfterAdditionalBoardsAreCreated() throws {
        let context = makeDefaults()
        defer { context.defaults.removePersistentDomain(forName: context.suiteName) }
        let rootID = UUID()
        let childID = UUID()
        _ = try BoardStorageBootstrapper.prepareDirectoryTreeStorage(
            defaults: context.defaults,
            id: { rootID }
        )

        var workspaces = try decodedWorkspaces(from: context.defaults)
        workspaces.append(workspace(id: childID, name: "Child"))
        context.defaults.set(try JSONEncoder().encode(workspaces), forKey: BoardStorageKeys.workspaces)
        context.defaults.set(
            try JSONEncoder().encode(
                BoardTreeData(rootBoardID: rootID, childBoardIDsByParentID: [rootID: [childID]])
            ),
            forKey: BoardStorageKeys.tree
        )
        context.defaults.set(childID.uuidString, forKey: BoardStorageKeys.activeBoardID)
        context.defaults.set(childID.uuidString, forKey: BoardStorageKeys.treeSelectedBoardID)
        context.defaults.set([rootID.uuidString, childID.uuidString], forKey: BoardStorageKeys.treeExpandedBoardIDs)

        let result = try BoardStorageBootstrapper.prepareDirectoryTreeStorage(
            defaults: context.defaults,
            id: { XCTFail("A valid store must not generate another Root Board."); return UUID() }
        )

        XCTAssertEqual(result, BoardStorageBootstrapResult(rootBoardID: rootID, didInitialize: false))
        XCTAssertEqual(try decodedWorkspaces(from: context.defaults).map(\.id), [rootID, childID])
        XCTAssertEqual(try decodedTree(from: context.defaults).childBoardIDsByParentID[rootID], [childID])
        XCTAssertEqual(context.defaults.string(forKey: BoardStorageKeys.activeBoardID), childID.uuidString)
        XCTAssertEqual(context.defaults.string(forKey: BoardStorageKeys.treeSelectedBoardID), childID.uuidString)
        XCTAssertEqual(
            context.defaults.stringArray(forKey: BoardStorageKeys.treeExpandedBoardIDs),
            [rootID.uuidString, childID.uuidString]
        )
    }

    func testBootstrapReinitializesMismatchedRootIDs() throws {
        let context = makeDefaults()
        defer { context.defaults.removePersistentDomain(forName: context.suiteName) }
        let oldRootID = UUID()
        let mismatchedTreeRootID = UUID()
        let newRootID = UUID()
        context.defaults.set(BoardStorageBootstrapper.currentGeneration, forKey: BoardStorageKeys.generation)
        context.defaults.set(
            try JSONEncoder().encode([workspace(id: oldRootID, name: BoardStorageBootstrapper.rootBoardName, isDefault: true)]),
            forKey: BoardStorageKeys.workspaces
        )
        context.defaults.set(
            try JSONEncoder().encode(BoardTreeData(rootBoardID: mismatchedTreeRootID)),
            forKey: BoardStorageKeys.tree
        )

        let result = try BoardStorageBootstrapper.prepareDirectoryTreeStorage(
            defaults: context.defaults,
            id: { newRootID }
        )

        XCTAssertEqual(result, BoardStorageBootstrapResult(rootBoardID: newRootID, didInitialize: true))
        XCTAssertEqual(try decodedWorkspaces(from: context.defaults).map(\.id), [newRootID])
        XCTAssertEqual(try decodedTree(from: context.defaults).rootBoardID, newRootID)
    }

    func testBootstrapReinitializesMalformedStorage() throws {
        let context = makeDefaults()
        defer { context.defaults.removePersistentDomain(forName: context.suiteName) }
        let newRootID = UUID()
        context.defaults.set(BoardStorageBootstrapper.currentGeneration, forKey: BoardStorageKeys.generation)
        context.defaults.set(Data("invalid".utf8), forKey: BoardStorageKeys.workspaces)
        context.defaults.set(Data("invalid".utf8), forKey: BoardStorageKeys.tree)

        let result = try BoardStorageBootstrapper.prepareDirectoryTreeStorage(
            defaults: context.defaults,
            id: { newRootID }
        )

        XCTAssertTrue(result.didInitialize)
        XCTAssertEqual(try decodedWorkspaces(from: context.defaults).first?.id, newRootID)
        XCTAssertEqual(try decodedTree(from: context.defaults).rootBoardID, newRootID)
    }

    func testEncodingFailureDoesNotDeleteExistingBoardData() throws {
        enum ExpectedError: Error { case encodingFailed }

        let context = makeDefaults()
        defer { context.defaults.removePersistentDomain(forName: context.suiteName) }
        let oldWorkspaceData = Data("old-workspaces".utf8)
        let oldCompositionData = Data("old-composition".utf8)
        let oldTreeData = Data("old-tree".utf8)
        let activeID = UUID()
        context.defaults.set(oldWorkspaceData, forKey: BoardStorageKeys.workspaces)
        context.defaults.set(oldCompositionData, forKey: BoardStorageKeys.legacyComposition)
        context.defaults.set(oldTreeData, forKey: BoardStorageKeys.tree)
        context.defaults.set(activeID.uuidString, forKey: BoardStorageKeys.activeBoardID)

        XCTAssertThrowsError(
            try BoardStorageBootstrapper.prepareDirectoryTreeStorage(
                defaults: context.defaults,
                encodeTree: { _ in throw ExpectedError.encodingFailed }
            )
        )

        XCTAssertEqual(context.defaults.data(forKey: BoardStorageKeys.workspaces), oldWorkspaceData)
        XCTAssertEqual(context.defaults.data(forKey: BoardStorageKeys.legacyComposition), oldCompositionData)
        XCTAssertEqual(context.defaults.data(forKey: BoardStorageKeys.tree), oldTreeData)
        XCTAssertEqual(context.defaults.string(forKey: BoardStorageKeys.activeBoardID), activeID.uuidString)
        XCTAssertNil(context.defaults.object(forKey: BoardStorageKeys.generation))
    }

    func testBoardTreeStoreRestoresBootstrappedTree() throws {
        let context = makeDefaults()
        defer { context.defaults.removePersistentDomain(forName: context.suiteName) }
        let result = try BoardStorageBootstrapper.prepareDirectoryTreeStorage(defaults: context.defaults)

        let store = BoardTreeStore(
            rootBoardID: result.rootBoardID,
            availableBoardIDs: [result.rootBoardID],
            defaults: context.defaults
        )

        XCTAssertEqual(store.data.rootBoardID, result.rootBoardID)
        XCTAssertTrue(store.contains(result.rootBoardID))
        XCTAssertTrue(store.childIDs(of: result.rootBoardID).isEmpty)
        XCTAssertTrue(store.data.favoriteBoardIDs.isEmpty)
    }

    private func makeDefaults() -> (defaults: UserDefaults, suiteName: String) {
        let suiteName = "WindowBoardTests.BoardBootstrap.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }

    private func decodedWorkspaces(from defaults: UserDefaults) throws -> [SavedWorkspace] {
        let data = try XCTUnwrap(defaults.data(forKey: BoardStorageKeys.workspaces))
        return try JSONDecoder().decode([SavedWorkspace].self, from: data)
    }

    private func decodedTree(from defaults: UserDefaults) throws -> BoardTreeData {
        let data = try XCTUnwrap(defaults.data(forKey: BoardStorageKeys.tree))
        return try JSONDecoder().decode(BoardTreeData.self, from: data)
    }

    private func workspace(
        id: SavedWorkspace.ID,
        name: String,
        isDefault: Bool = false
    ) -> SavedWorkspace {
        SavedWorkspace(
            id: id,
            name: name,
            statusItemSymbolName: nil,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            windows: [],
            isDefault: isDefault
        )
    }
}
