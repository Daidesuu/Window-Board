import XCTest
@testable import WindowBoard

@MainActor
final class BoardTreeStoreTests: XCTestCase {
    func testInsertingBoardsBuildsOrderedPathsAndAncestors() {
        let root = UUID()
        let classes = UUID()
        let math = UUID()
        let physics = UUID()
        let context = makeStore(root: root, boards: [classes, math, physics])

        XCTAssertEqual(context.store.insertBoard(classes, under: root), .inserted)
        XCTAssertEqual(context.store.insertBoard(math, under: classes), .inserted)
        XCTAssertEqual(context.store.insertBoard(physics, under: classes), .inserted)

        XCTAssertEqual(context.store.childIDs(of: classes), [math, physics])
        XCTAssertEqual(context.store.parentID(of: math), classes)
        XCTAssertEqual(context.store.ancestorIDs(of: math), [root, classes])
        XCTAssertEqual(context.store.pathIDs(to: math), [root, classes, math])
        XCTAssertEqual(context.store.descendantIDs(of: classes), Set([math, physics]))
    }

    func testInsertRejectsMissingDuplicateSelfAndInvalidIndex() {
        let root = UUID()
        let child = UUID()
        let missing = UUID()
        let context = makeStore(root: root, boards: [child])

        XCTAssertEqual(context.store.insertBoard(missing, under: root), .missingBoard)
        XCTAssertEqual(context.store.insertBoard(child, under: missing), .missingParent)
        XCTAssertEqual(context.store.insertBoard(root, under: root), .selfReference)
        XCTAssertEqual(context.store.insertBoard(child, under: root, at: 1), .invalidIndex)
        XCTAssertEqual(context.store.insertBoard(child, under: root), .inserted)
        XCTAssertEqual(context.store.insertBoard(child, under: root), .duplicate)
    }

    func testMovingBoardChangesParentAndRejectsCyclesAndRootMovement() {
        let root = UUID()
        let classes = UUID()
        let math = UUID()
        let archive = UUID()
        let context = makeStore(root: root, boards: [classes, math, archive])
        XCTAssertEqual(context.store.insertBoard(classes, under: root), .inserted)
        XCTAssertEqual(context.store.insertBoard(archive, under: root), .inserted)
        XCTAssertEqual(context.store.insertBoard(math, under: classes), .inserted)

        XCTAssertEqual(context.store.moveBoard(math, to: archive), .moved)
        XCTAssertEqual(context.store.parentID(of: math), archive)
        XCTAssertEqual(context.store.moveBoard(archive, to: math), .cycle)
        XCTAssertEqual(context.store.moveBoard(math, to: math), .selfReference)
        XCTAssertEqual(context.store.moveBoard(root, to: archive), .rootImmutable)
    }

    func testMovingWithinParentReordersChildren() {
        let root = UUID()
        let first = UUID()
        let second = UUID()
        let third = UUID()
        let context = makeStore(root: root, boards: [first, second, third])
        XCTAssertEqual(context.store.insertBoard(first, under: root), .inserted)
        XCTAssertEqual(context.store.insertBoard(second, under: root), .inserted)
        XCTAssertEqual(context.store.insertBoard(third, under: root), .inserted)

        XCTAssertEqual(context.store.moveBoard(first, to: root, at: 2), .reordered)
        XCTAssertEqual(context.store.childIDs(of: root), [second, third, first])
        XCTAssertEqual(context.store.moveBoard(first, to: root, at: 2), .duplicate)
        XCTAssertEqual(context.store.moveBoard(first, to: root, at: 4), .invalidIndex)
    }

    func testRemovingSubtreeRemovesDescendantsAndFavoritesOnlyFromTreeData() {
        let root = UUID()
        let classes = UUID()
        let math = UUID()
        let other = UUID()
        let context = makeStore(root: root, boards: [classes, math, other])
        XCTAssertEqual(context.store.insertBoard(classes, under: root), .inserted)
        XCTAssertEqual(context.store.insertBoard(other, under: root), .inserted)
        XCTAssertEqual(context.store.insertBoard(math, under: classes), .inserted)
        XCTAssertEqual(context.store.addFavorite(classes), .inserted)
        XCTAssertEqual(context.store.addFavorite(math), .inserted)
        XCTAssertEqual(context.store.addFavorite(other), .inserted)

        XCTAssertEqual(context.store.removeSubtreeReferences(rootedAt: classes), .removed)

        XCTAssertFalse(context.store.contains(classes))
        XCTAssertFalse(context.store.contains(math))
        XCTAssertTrue(context.store.contains(other))
        XCTAssertEqual(context.store.childIDs(of: root), [other])
        XCTAssertEqual(context.store.data.favoriteBoardIDs, [other])
        XCTAssertEqual(context.store.removeSubtreeReferences(rootedAt: root), .rootImmutable)
    }

    func testFavoritesAreOrderedIndependentFromTreeStructure() {
        let root = UUID()
        let classes = UUID()
        let math = UUID()
        let context = makeStore(root: root, boards: [classes, math])
        XCTAssertEqual(context.store.insertBoard(classes, under: root), .inserted)
        XCTAssertEqual(context.store.insertBoard(math, under: classes), .inserted)

        XCTAssertEqual(context.store.addFavorite(math), .inserted)
        XCTAssertEqual(context.store.addFavorite(root, at: 0), .inserted)
        XCTAssertEqual(context.store.addFavorite(math), .duplicate)
        XCTAssertEqual(context.store.moveFavorite(math, to: 0), .reordered)
        XCTAssertEqual(context.store.data.favoriteBoardIDs, [math, root])
        XCTAssertEqual(context.store.parentID(of: math), classes)
        XCTAssertEqual(context.store.removeFavorite(math), .removed)
        XCTAssertEqual(context.store.data.favoriteBoardIDs, [root])
    }

    func testTreePersistsWithoutChangingLegacyCompositionData() throws {
        let root = UUID()
        let child = UUID()
        let suiteName = "WindowBoardTests.BoardTree.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let legacyData = Data("legacy-composition".utf8)
        defaults.set(legacyData, forKey: "boardComposition.v2")

        let firstStore = BoardTreeStore(
            rootBoardID: root,
            availableBoardIDs: [root, child],
            defaults: defaults
        )
        XCTAssertEqual(firstStore.insertBoard(child, under: root), .inserted)
        XCTAssertEqual(firstStore.addFavorite(child), .inserted)

        let restoredStore = BoardTreeStore(
            rootBoardID: root,
            availableBoardIDs: [root, child],
            defaults: defaults
        )

        XCTAssertEqual(restoredStore.childIDs(of: root), [child])
        XCTAssertEqual(restoredStore.data.favoriteBoardIDs, [child])
        XCTAssertEqual(defaults.data(forKey: "boardComposition.v2"), legacyData)
    }

    func testReconcileRemovesMissingDuplicateMultipleParentAndCycleEdges() throws {
        let root = UUID()
        let first = UUID()
        let second = UUID()
        let shared = UUID()
        let missing = UUID()
        let suiteName = "WindowBoardTests.BoardTree.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let malformed = BoardTreeData(
            rootBoardID: root,
            childBoardIDsByParentID: [
                root: [first, first, missing, second],
                first: [shared],
                second: [shared],
                shared: [first]
            ],
            favoriteBoardIDs: [shared, shared, missing]
        )
        defaults.set(try JSONEncoder().encode(malformed), forKey: "boardTree.v1")

        let store = BoardTreeStore(
            rootBoardID: root,
            availableBoardIDs: [root, first, second, shared],
            defaults: defaults
        )

        XCTAssertEqual(store.childIDs(of: root), [first, second])
        XCTAssertEqual(store.childIDs(of: first), [shared])
        XCTAssertTrue(store.childIDs(of: second).isEmpty)
        XCTAssertTrue(store.childIDs(of: shared).isEmpty)
        XCTAssertEqual(store.parentID(of: shared), first)
        XCTAssertEqual(store.data.favoriteBoardIDs, [shared])
    }

    func testReconcileDropsUnavailableBoardsWithoutAttachingOrphans() {
        let root = UUID()
        let first = UUID()
        let second = UUID()
        let context = makeStore(root: root, boards: [first, second])
        XCTAssertEqual(context.store.insertBoard(first, under: root), .inserted)
        XCTAssertEqual(context.store.insertBoard(second, under: first), .inserted)
        XCTAssertEqual(context.store.addFavorite(second), .inserted)

        context.store.reconcile(availableBoardIDs: [root, second])

        XCTAssertEqual(context.store.childIDs(of: root), [])
        XCTAssertFalse(context.store.contains(second))
        XCTAssertEqual(context.store.data.favoriteBoardIDs, [])
    }

    private func makeStore(
        root: SavedWorkspace.ID,
        boards: Set<SavedWorkspace.ID>
    ) -> (store: BoardTreeStore, defaults: UserDefaults, suiteName: String) {
        let suiteName = "WindowBoardTests.BoardTree.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return (
            BoardTreeStore(
                rootBoardID: root,
                availableBoardIDs: boards.union([root]),
                defaults: defaults
            ),
            defaults,
            suiteName
        )
    }
}
