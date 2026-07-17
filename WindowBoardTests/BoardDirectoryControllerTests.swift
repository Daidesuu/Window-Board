import XCTest
@testable import WindowBoard

@MainActor
final class BoardDirectoryControllerTests: XCTestCase {
    func testResolverProjectsCurrentDirectoryWithoutMixingChildWindows() {
        let rootID = UUID()
        let classesID = UUID()
        let mathID = UUID()
        let rootWindow = windowReference(name: "Root Window")
        let classesWindow = windowReference(name: "Classes Window")
        let mathWindow = windowReference(name: "Math Window")
        let root = workspace(id: rootID, name: "Root Board", windows: [rootWindow])
        let classes = workspace(id: classesID, name: "Classes", windows: [classesWindow])
        let math = workspace(id: mathID, name: "Math", windows: [mathWindow])
        let tree = BoardTreeData(
            rootBoardID: rootID,
            childBoardIDsByParentID: [rootID: [classesID], classesID: [mathID]],
            favoriteBoardIDs: [mathID]
        )

        let snapshot = BoardDirectoryResolver.resolve(
            tree: tree,
            workspaces: [root, classes, math],
            currentBoardID: classesID
        )

        XCTAssertEqual(snapshot.rootBoard, root)
        XCTAssertEqual(snapshot.currentBoard, classes)
        XCTAssertEqual(snapshot.parentBoard, root)
        XCTAssertEqual(snapshot.breadcrumbs, [root, classes])
        XCTAssertEqual(snapshot.childBoards, [math])
        XCTAssertEqual(snapshot.windows, [classesWindow])
        XCTAssertEqual(snapshot.favoriteBoards, [math])
        XCTAssertTrue(snapshot.canMoveCurrentBoard)
        XCTAssertTrue(snapshot.canDeleteCurrentBoard)
    }

    func testResolverFallsBackToRootForBoardOutsideTheTree() {
        let root = workspace(name: "Root Board")
        let orphan = workspace(name: "Orphan")
        let tree = BoardTreeData(rootBoardID: root.id)

        let snapshot = BoardDirectoryResolver.resolve(
            tree: tree,
            workspaces: [root, orphan],
            currentBoardID: orphan.id
        )

        XCTAssertEqual(snapshot.currentBoard, root)
        XCTAssertEqual(snapshot.breadcrumbs, [root])
    }

    func testControllerStartsAtRootAndNavigatesBetweenParentAndChild() throws {
        let root = workspace(name: "Root Board")
        let classes = workspace(name: "Classes")
        let context = try makeContext(root: root, boards: [classes])
        defer { context.cleanup() }
        XCTAssertEqual(context.treeStore.insertBoard(classes.id, under: root.id), .inserted)
        let controller = BoardDirectoryController(
            workspaceStore: context.workspaceStore,
            treeStore: context.treeStore
        )

        XCTAssertEqual(controller.currentBoardID, root.id)
        XCTAssertEqual(controller.snapshot.breadcrumbs.map(\.id), [root.id])
        XCTAssertTrue(controller.openBoard(classes.id))
        XCTAssertEqual(controller.snapshot.breadcrumbs.map(\.id), [root.id, classes.id])
        XCTAssertTrue(controller.openParent())
        XCTAssertEqual(controller.currentBoardID, root.id)
        XCTAssertFalse(controller.openParent())
    }

    func testCreateBoardAddsAnEmptyChildToCurrentDirectory() throws {
        let root = workspace(name: "Root Board")
        let context = try makeContext(root: root)
        defer { context.cleanup() }
        let controller = BoardDirectoryController(
            workspaceStore: context.workspaceStore,
            treeStore: context.treeStore
        )

        let created = try XCTUnwrap(controller.createBoard(name: "  Classes  "))

        XCTAssertEqual(created.name, "Classes")
        XCTAssertTrue(created.windows.isEmpty)
        XCTAssertEqual(context.treeStore.parentID(of: created.id), root.id)
        XCTAssertEqual(controller.snapshot.childBoards.map(\.id), [created.id])
        XCTAssertNil(controller.createBoard(name: "   "))
    }

    func testCreateNestedBoardCanBeSelectedImmediately() throws {
        let root = workspace(name: "Root Board")
        let context = try makeContext(root: root)
        defer { context.cleanup() }
        let controller = BoardDirectoryController(
            workspaceStore: context.workspaceStore,
            treeStore: context.treeStore
        )

        let classes = try XCTUnwrap(controller.createBoard(name: "Classes", under: root.id))
        let math = try XCTUnwrap(controller.createBoard(name: "Math", under: classes.id))

        XCTAssertTrue(controller.openBoard(math.id))
        XCTAssertEqual(controller.currentBoardID, math.id)
        XCTAssertEqual(controller.snapshot.breadcrumbs.map(\.id), [root.id, classes.id, math.id])
        XCTAssertEqual(context.treeStore.parentID(of: math.id), classes.id)
    }

    func testRenameChangesOnlyRequestedNonRootBoard() throws {
        let root = workspace(name: "Root Board")
        let classes = workspace(name: "Classes")
        let math = workspace(name: "Math")
        let context = try makeContext(root: root, boards: [classes, math])
        defer { context.cleanup() }
        XCTAssertEqual(context.treeStore.insertBoard(classes.id, under: root.id), .inserted)
        XCTAssertEqual(context.treeStore.insertBoard(math.id, under: root.id), .inserted)
        let controller = BoardDirectoryController(
            workspaceStore: context.workspaceStore,
            treeStore: context.treeStore
        )

        XCTAssertTrue(controller.renameBoard(id: classes.id, name: "  School  "))
        XCTAssertEqual(context.workspaceStore.workspaces.first(where: { $0.id == classes.id })?.name, "School")
        XCTAssertEqual(context.workspaceStore.workspaces.first(where: { $0.id == math.id })?.name, "Math")
        XCTAssertFalse(controller.renameBoard(id: root.id, name: "Changed Root"))
        XCTAssertEqual(context.workspaceStore.workspaces.first(where: { $0.id == root.id })?.name, "Root Board")
    }

    func testFavoritesRemainIndependentFromTreeNavigationAndOrdering() throws {
        let root = workspace(name: "Root Board")
        let classes = workspace(name: "Classes")
        let math = workspace(name: "Math")
        let context = try makeContext(root: root, boards: [classes, math])
        defer { context.cleanup() }
        XCTAssertEqual(context.treeStore.insertBoard(classes.id, under: root.id), .inserted)
        XCTAssertEqual(context.treeStore.insertBoard(math.id, under: classes.id), .inserted)
        let controller = BoardDirectoryController(
            workspaceStore: context.workspaceStore,
            treeStore: context.treeStore
        )

        XCTAssertEqual(controller.addFavorite(math.id), .inserted)
        XCTAssertEqual(controller.addFavorite(root.id, at: 0), .inserted)
        XCTAssertEqual(controller.snapshot.favoriteBoards.map(\.id), [root.id, math.id])
        XCTAssertEqual(context.treeStore.parentID(of: math.id), classes.id)
        XCTAssertEqual(controller.moveFavorite(math.id, to: 0), .reordered)
        XCTAssertEqual(controller.snapshot.favoriteBoards.map(\.id), [math.id, root.id])
        XCTAssertEqual(controller.removeFavorite(math.id), .removed)
        XCTAssertEqual(controller.snapshot.favoriteBoards.map(\.id), [root.id])
    }

    func testMovingCurrentBoardUpdatesItsBreadcrumbs() throws {
        let root = workspace(name: "Root Board")
        let classes = workspace(name: "Classes")
        let archive = workspace(name: "Archive")
        let math = workspace(name: "Math")
        let context = try makeContext(root: root, boards: [classes, archive, math])
        defer { context.cleanup() }
        XCTAssertEqual(context.treeStore.insertBoard(classes.id, under: root.id), .inserted)
        XCTAssertEqual(context.treeStore.insertBoard(archive.id, under: root.id), .inserted)
        XCTAssertEqual(context.treeStore.insertBoard(math.id, under: classes.id), .inserted)
        let controller = BoardDirectoryController(
            workspaceStore: context.workspaceStore,
            treeStore: context.treeStore,
            initialBoardID: math.id
        )

        XCTAssertEqual(controller.moveBoard(math.id, to: archive.id), .moved)

        XCTAssertEqual(controller.currentBoardID, math.id)
        XCTAssertEqual(controller.snapshot.breadcrumbs.map(\.id), [root.id, archive.id, math.id])
    }

    func testMoveKeepsSelectionAndRejectsMovingParentIntoDescendant() throws {
        let root = workspace(name: "Root Board")
        let classes = workspace(name: "Classes")
        let archive = workspace(name: "Archive")
        let math = workspace(name: "Math")
        let context = try makeContext(root: root, boards: [classes, archive, math])
        defer { context.cleanup() }
        XCTAssertEqual(context.treeStore.insertBoard(classes.id, under: root.id), .inserted)
        XCTAssertEqual(context.treeStore.insertBoard(archive.id, under: root.id), .inserted)
        XCTAssertEqual(context.treeStore.insertBoard(math.id, under: classes.id), .inserted)
        let controller = BoardDirectoryController(
            workspaceStore: context.workspaceStore,
            treeStore: context.treeStore,
            initialBoardID: math.id
        )

        XCTAssertEqual(controller.moveBoard(math.id, to: archive.id, at: 0), .moved)
        XCTAssertEqual(controller.currentBoardID, math.id)
        XCTAssertEqual(controller.snapshot.breadcrumbs.map(\.id), [root.id, archive.id, math.id])
        XCTAssertEqual(controller.moveBoard(archive.id, to: math.id), .cycle)
        XCTAssertEqual(context.treeStore.parentID(of: archive.id), root.id)
    }

    func testDeletingCurrentSubtreeFallsBackToParentAndRemovesSavedBoards() throws {
        let root = workspace(name: "Root Board")
        let classes = workspace(name: "Classes", windows: [windowReference(name: "Classes Window")])
        let math = workspace(name: "Math", windows: [windowReference(name: "Math Window")])
        let other = workspace(name: "Other")
        let context = try makeContext(root: root, boards: [classes, math, other])
        defer { context.cleanup() }
        XCTAssertEqual(context.treeStore.insertBoard(classes.id, under: root.id), .inserted)
        XCTAssertEqual(context.treeStore.insertBoard(other.id, under: root.id), .inserted)
        XCTAssertEqual(context.treeStore.insertBoard(math.id, under: classes.id), .inserted)
        XCTAssertEqual(context.treeStore.addFavorite(math.id), .inserted)
        let controller = BoardDirectoryController(
            workspaceStore: context.workspaceStore,
            treeStore: context.treeStore,
            initialBoardID: math.id
        )

        XCTAssertEqual(controller.deleteBoard(classes.id), .removed)

        XCTAssertEqual(controller.currentBoardID, root.id)
        XCTAssertFalse(context.workspaceStore.workspaces.contains(where: { $0.id == classes.id }))
        XCTAssertFalse(context.workspaceStore.workspaces.contains(where: { $0.id == math.id }))
        XCTAssertTrue(context.workspaceStore.workspaces.contains(where: { $0.id == other.id }))
        XCTAssertEqual(context.treeStore.childIDs(of: root.id), [other.id])
        XCTAssertTrue(context.treeStore.data.favoriteBoardIDs.isEmpty)
    }

    func testRootCannotBeMovedOrDeleted() throws {
        let root = workspace(name: "Root Board")
        let child = workspace(name: "Child")
        let context = try makeContext(root: root, boards: [child])
        defer { context.cleanup() }
        XCTAssertEqual(context.treeStore.insertBoard(child.id, under: root.id), .inserted)
        let controller = BoardDirectoryController(
            workspaceStore: context.workspaceStore,
            treeStore: context.treeStore
        )

        XCTAssertEqual(controller.moveBoard(root.id, to: child.id), .rootImmutable)
        XCTAssertEqual(controller.deleteBoard(root.id), .rootImmutable)
        XCTAssertEqual(controller.currentBoardID, root.id)
        XCTAssertFalse(controller.snapshot.canMoveCurrentBoard)
        XCTAssertFalse(controller.snapshot.canDeleteCurrentBoard)
    }

    func testRemovingCurrentWorkspaceExternallyFallsBackToNearestExistingAncestor() throws {
        let root = workspace(name: "Root Board")
        let classes = workspace(name: "Classes")
        let math = workspace(name: "Math")
        let context = try makeContext(root: root, boards: [classes, math])
        defer { context.cleanup() }
        XCTAssertEqual(context.treeStore.insertBoard(classes.id, under: root.id), .inserted)
        XCTAssertEqual(context.treeStore.insertBoard(math.id, under: classes.id), .inserted)
        let controller = BoardDirectoryController(
            workspaceStore: context.workspaceStore,
            treeStore: context.treeStore,
            initialBoardID: math.id
        )

        context.workspaceStore.deleteWorkspace(id: math.id)

        XCTAssertEqual(controller.currentBoardID, classes.id)
        XCTAssertEqual(controller.snapshot.breadcrumbs.map(\.id), [root.id, classes.id])
        XCTAssertFalse(context.treeStore.contains(math.id))
    }

    private func makeContext(
        root: SavedWorkspace,
        boards: [SavedWorkspace] = []
    ) throws -> DirectoryTestContext {
        let suiteName = "WindowBoardTests.BoardDirectory.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(
            try JSONEncoder().encode([root] + boards),
            forKey: BoardStorageKeys.workspaces
        )
        let workspaceStore = WorkspaceStore(defaults: defaults)
        let availableBoardIDs = Set(workspaceStore.workspaces.map(\.id))
        let treeStore = BoardTreeStore(
            rootBoardID: root.id,
            availableBoardIDs: availableBoardIDs,
            defaults: defaults
        )
        return DirectoryTestContext(
            workspaceStore: workspaceStore,
            treeStore: treeStore,
            defaults: defaults,
            suiteName: suiteName
        )
    }

    private func workspace(
        id: SavedWorkspace.ID = UUID(),
        name: String,
        windows: [SavedWindowReference] = []
    ) -> SavedWorkspace {
        SavedWorkspace(
            id: id,
            name: name,
            statusItemSymbolName: nil,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            windows: windows
        )
    }

    private func windowReference(name: String) -> SavedWindowReference {
        SavedWindowReference(
            id: UUID(),
            displayName: name,
            appName: "Test App",
            title: name,
            bundleIdentifier: "com.example.test",
            bundleURLString: nil,
            documentURLString: nil,
            workspaceURLString: nil,
            offsetX: 0,
            offsetY: 0,
            originX: 100,
            originY: 100,
            width: 800,
            height: 600
        )
    }
}

private struct DirectoryTestContext {
    let workspaceStore: WorkspaceStore
    let treeStore: BoardTreeStore
    let defaults: UserDefaults
    let suiteName: String

    func cleanup() {
        defaults.removePersistentDomain(forName: suiteName)
    }
}
