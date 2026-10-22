import ApplicationServices
import XCTest
@testable import WindowBoard

final class WindowMatchingTests: XCTestCase {
    func testBoardAndWindowDragPayloadsRetainTheirKinds() {
        let id = UUID()

        let windowPayload = WindowBoardDragPayload.window(id)

        XCTAssertEqual(windowPayload.kind, .window)
        XCTAssertEqual(WindowBoardDragPayload.id(from: Data(id.uuidString.utf8)), id)
        XCTAssertNil(WindowBoardDragPayload.id(from: Data("invalid".utf8)))
        XCTAssertEqual(DragPayload.boardID(from: DragPayload.board(id)), id)
        XCTAssertNil(DragPayload.boardID(from: id.uuidString))
        XCTAssertTrue(
            WindowBoardDragPayload.windowProvider(id: id)
                .hasItemConformingToTypeIdentifier(WindowBoardDragKind.window.type.identifier)
        )
    }

    func testSidebarBoardDragPayloadPreservesItsRootOrigin() {
        let boardID = UUID()
        let primaryID = UUID()

        let payload = DragPayload.board(boardID, sourcePrimaryBoardID: primaryID)
        let decoded = DragPayload.boardPayload(from: payload)

        XCTAssertEqual(decoded?.boardID, boardID)
        XCTAssertEqual(decoded?.sourcePrimaryBoardID, primaryID)
        XCTAssertTrue(decoded?.canRemoveFromCurrentBoard == true)
        XCTAssertEqual(DragPayload.boardID(from: payload), boardID)
    }

    func testSidebarBoardDragPayloadWithoutRootOriginCannotRemoveComposition() {
        let boardID = UUID()
        let decoded = DragPayload.boardPayload(from: DragPayload.board(boardID))

        XCTAssertEqual(decoded?.boardID, boardID)
        XCTAssertNil(decoded?.sourcePrimaryBoardID)
        XCTAssertFalse(decoded?.canRemoveFromCurrentBoard == true)
    }

    func testLegacyDefaultBoardNameMigratesToPermanentBoard() {
        let suiteName = "WindowBoardTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let now = Date()
        let legacyDefault = SavedWorkspace(
            id: UUID(),
            name: "Default",
            statusItemSymbolName: nil,
            createdAt: now,
            updatedAt: now,
            windows: [],
            isDefault: true
        )
        defaults.set(try! JSONEncoder().encode([legacyDefault]), forKey: "savedWorkspaces")

        let store = WorkspaceStore(defaults: defaults)

        XCTAssertEqual(store.defaultWorkspace?.id, legacyDefault.id)
        XCTAssertEqual(store.defaultWorkspace?.name, "Permanent Board")
    }

    func testDefaultWorkspaceRemainsFirstAndCannotBeRenamedOrDeleted() {
        let service = FakeWorkspaceWindowService(windows: [])
        let session = makeSession(service: service)
        let defaultWorkspace = try! XCTUnwrap(session.workspaceStore.defaultWorkspace)

        session.selectedWorkspaceID = defaultWorkspace.id
        session.renameSelectedWorkspace(name: "Renamed Default")
        session.deleteSelectedWorkspace()

        XCTAssertEqual(session.workspaceStore.workspaces.first?.id, defaultWorkspace.id)
        XCTAssertEqual(session.workspaceStore.defaultWorkspace?.name, WorkspaceStore.defaultWorkspaceName)
        XCTAssertTrue(session.workspaceStore.workspaces.contains(where: { $0.id == defaultWorkspace.id }))
    }

    func testOverwritingDefaultUpdatesWindowsButKeepsDefaultIdentityAndName() {
        let liveWindow = window(id: "default-live", title: "Default Tool")
        let service = FakeWorkspaceWindowService(windows: [liveWindow])
        let session = makeSession(service: service)
        let defaultWorkspace = try! XCTUnwrap(session.workspaceStore.defaultWorkspace)
        session.selectedWorkspaceID = defaultWorkspace.id
        session.activeWorkspaceID = defaultWorkspace.id
        session.attachedWindows = [
            AttachedWindow(
                window: liveWindow,
                lastBoardOrigin: .zero,
                lastWindowOrigin: CGPoint(x: 40, y: 60),
                lastAppliedOrigin: nil,
                pendingReleaseOrigin: nil
            )
        ]

        session.overwriteSelectedWorkspace(name: "Renamed Default", boardOrigin: .zero)

        let updatedDefault = try! XCTUnwrap(session.workspaceStore.defaultWorkspace)
        XCTAssertEqual(updatedDefault.id, defaultWorkspace.id)
        XCTAssertEqual(updatedDefault.name, WorkspaceStore.defaultWorkspaceName)
        XCTAssertEqual(updatedDefault.windows.count, 1)
        XCTAssertEqual(updatedDefault.windows.first?.title, liveWindow.title)
    }

    func testPersistingAttachedWindowRefreshesCurrentBoardCompositionImmediately() {
        let liveWindow = window(id: "newly-attached", title: "New Window")
        let service = FakeWorkspaceWindowService(windows: [liveWindow])
        let session = makeSession(service: service)
        let activeBoard = try! XCTUnwrap(session.workspaceStore.defaultWorkspace)
        session.activeWorkspaceID = activeBoard.id
        session.selectedWorkspaceID = activeBoard.id
        session.attachedWindows = [
            AttachedWindow(
                window: liveWindow,
                lastBoardOrigin: .zero,
                lastWindowOrigin: liveWindow.position ?? .zero,
                lastAppliedOrigin: liveWindow.position,
                pendingReleaseOrigin: nil
            )
        ]

        _ = session.persistActiveWorkspaceState(boardOrigin: .zero)

        XCTAssertEqual(
            session.currentBoardComposition.roots.first?.board.windows.map(\.id),
            session.attachedWindows.map(\.id)
        )
    }

    @MainActor
    func testStatusItemSwitchPersistsPreviousPrimaryLayoutBeforeReplacement() async {
        let firstReference = savedReference(title: "First", origin: CGPoint(x: 10, y: 20))
        let firstWorkspace = makeWorkspace(name: "First Board", windows: [firstReference])
        let secondWorkspace = makeWorkspace(name: "Second Board", windows: [])
        let firstWindow = window(
            id: "first-live",
            title: "First",
            position: CGPoint(x: 10, y: 20)
        )
        let service = FakeWorkspaceWindowService(windows: [firstWindow])
        let session = makeSession(workspaces: [firstWorkspace, secondWorkspace], service: service)
        let storedFirst = try! XCTUnwrap(
            session.workspaceStore.workspaces.first { $0.name == firstWorkspace.name }
        )
        let storedSecond = try! XCTUnwrap(
            session.workspaceStore.workspaces.first { $0.name == secondWorkspace.name }
        )

        session.switchWorkspace(
            id: storedFirst.id,
            boardOrigin: .zero,
            source: .statusItem,
            followMode: .none,
            windowCache: [firstWindow]
        )
        await waitForWorkspaceSwitch(session)

        let updatedOrigin = CGPoint(x: 420, y: 260)
        session.attachedWindows[0].lastWindowOrigin = updatedOrigin
        session.switchWorkspace(
            id: storedSecond.id,
            boardOrigin: .zero,
            source: .statusItem,
            followMode: .none,
            windowCache: [firstWindow]
        )
        await waitForWorkspaceSwitch(session)

        let persistedFirst = try! XCTUnwrap(
            session.workspaceStore.workspaces.first { $0.id == storedFirst.id }
        )
        XCTAssertEqual(persistedFirst.windows.first?.savedOrigin, updatedOrigin)
        XCTAssertEqual(session.activeWorkspaceID, storedSecond.id)
        XCTAssertTrue(session.attachedWindows.isEmpty)
    }

    func testLegacyNeverMinimizeWindowsMigrateIntoPermanentBoard() {
        let suiteName = "WindowBoardTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let legacyData = try! JSONSerialization.data(withJSONObject: [[
            "bundleIdentifier": "com.example.permanent",
            "appName": "Permanent Tool",
            "title": "Document",
            "documentURLString": "file:///document",
            "windowNumber": 42,
            "displayName": "Permanent Tool - Document"
        ]])
        defaults.set(legacyData, forKey: "neverMinimizeWindows")

        let appState = WindowBoardAppState(defaults: defaults)
        let permanentBoard = try! XCTUnwrap(appState.workspaceStore.defaultWorkspace)

        XCTAssertEqual(permanentBoard.windows.count, 1)
        XCTAssertEqual(permanentBoard.windows.first?.bundleIdentifier, "com.example.permanent")
        XCTAssertEqual(permanentBoard.windows.first?.documentURLString, "file:///document")
        XCTAssertTrue(permanentBoard.isDefault)
        XCTAssertNil(defaults.data(forKey: "neverMinimizeWindows"))
    }

    func testBoardCompositionPersistsRootsWithoutDuplicates() {
        let suiteName = "WindowBoardTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let primaryID = UUID()
        let boardID = UUID()
        let available: Set<UUID> = [primaryID, boardID]

        let firstStore = BoardCompositionStore(defaults: defaults)
        XCTAssertEqual(firstStore.includeRoot(boardID, for: primaryID, availableBoardIDs: available), .inserted)
        XCTAssertEqual(firstStore.includeRoot(boardID, for: primaryID, availableBoardIDs: available), .duplicate)
        let restoredStore = BoardCompositionStore(defaults: defaults)

        XCTAssertEqual(restoredStore.rootBoardIDs(for: primaryID), [boardID])
    }

    func testExcludingAdditionalRootKeepsTheBoardAndItsWindows() {
        let suiteName = "WindowBoardTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let primary = makeWorkspace(name: "Primary", windows: [])
        let included = makeWorkspace(name: "Included", windows: [savedReference(title: "Window")])
        let store = BoardCompositionStore(defaults: defaults)
        let available: Set<UUID> = [primary.id, included.id]

        XCTAssertEqual(store.includeRoot(included.id, for: primary.id, availableBoardIDs: available), .inserted)
        XCTAssertEqual(store.excludeRoot(included.id, for: primary.id), .removed)
        XCTAssertTrue(store.rootBoardIDs(for: primary.id).isEmpty)
        XCTAssertEqual(included.windows.count, 1)
    }

    func testBoardCompositionInsertsAdditionalRootsBesideTheDropTarget() {
        let suiteName = "WindowBoardTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let primary = makeWorkspace(name: "Primary", windows: [])
        let first = makeWorkspace(name: "First", windows: [])
        let second = makeWorkspace(name: "Second", windows: [])
        let third = makeWorkspace(name: "Third", windows: [])
        let workspaces = [primary, first, second, third]
        let available = Set(workspaces.map(\.id))
        let store = BoardCompositionStore(defaults: defaults)

        XCTAssertEqual(store.includeRoot(first.id, for: primary.id, availableBoardIDs: available), .inserted)
        XCTAssertEqual(
            store.includeRoot(
                second.id,
                for: primary.id,
                availableBoardIDs: available,
                relativeTo: first.id,
                insertion: .after
            ),
            .inserted
        )
        XCTAssertEqual(
            store.includeRoot(
                third.id,
                for: primary.id,
                availableBoardIDs: available,
                relativeTo: second.id,
                insertion: .before
            ),
            .inserted
        )

        XCTAssertEqual(store.rootBoardIDs(for: primary.id), [first.id, third.id, second.id])
        XCTAssertEqual(
            store.resolveCurrentBoard(primaryID: primary.id, workspaces: workspaces).roots.map(\.board.id),
            [primary.id, first.id, third.id, second.id]
        )
    }

    func testBoardCompositionResolvesPrimaryRootAndChildHierarchy() {
        let suiteName = "WindowBoardTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let primary = makeWorkspace(name: "Primary", windows: [])
        let included = makeWorkspace(name: "Included", windows: [])
        let child = makeWorkspace(name: "Child", windows: [])
        let store = BoardCompositionStore(defaults: defaults)
        let available: Set<UUID> = [primary.id, included.id, child.id]
        XCTAssertEqual(store.includeRoot(included.id, for: primary.id, availableBoardIDs: available), .inserted)
        XCTAssertEqual(store.includeChild(child.id, in: included.id, availableBoardIDs: available), .inserted)

        let resolved = store.resolveCurrentBoard(primaryID: primary.id, workspaces: [primary, included, child])

        XCTAssertEqual(resolved.roots.map(\.board.id), [primary.id, included.id])
        XCTAssertEqual(resolved.roots[1].children.map(\.board.id), [child.id])
    }

    func testBoardCompositionKeepsDifferentRootSetsForEachPrimaryBoard() {
        let suiteName = "WindowBoardTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let primaryA = makeWorkspace(name: "Primary A", windows: [])
        let primaryB = makeWorkspace(name: "Primary B", windows: [])
        let rootA = makeWorkspace(name: "Root A", windows: [])
        let rootB = makeWorkspace(name: "Root B", windows: [])
        let workspaces = [primaryA, primaryB, rootA, rootB]
        let available = Set(workspaces.map(\.id))
        let store = BoardCompositionStore(defaults: defaults)
        _ = store.includeRoot(rootA.id, for: primaryA.id, availableBoardIDs: available)
        _ = store.includeRoot(rootB.id, for: primaryB.id, availableBoardIDs: available)

        XCTAssertEqual(store.resolveCurrentBoard(primaryID: primaryA.id, workspaces: workspaces).roots.map(\.board.id), [primaryA.id, rootA.id])
        XCTAssertEqual(store.resolveCurrentBoard(primaryID: primaryB.id, workspaces: workspaces).roots.map(\.board.id), [primaryB.id, rootB.id])
    }

    func testSidebarProjectionKeepsSavedGroupsIndependentOfSelection() {
        let suiteName = "WindowBoardTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let permanent = makeWorkspace(name: "Permanent Board", windows: [], isDefault: true)
        let board1 = makeWorkspace(name: "Board 1", windows: [])
        let board2 = makeWorkspace(name: "Board 2", windows: [])
        let board3 = makeWorkspace(name: "Board 3", windows: [])
        let workspaces = [permanent, board1, board2, board3]
        let available = Set(workspaces.map(\.id))
        let store = BoardCompositionStore(defaults: defaults)
        _ = store.includeRoot(board2.id, for: board1.id, availableBoardIDs: available)

        let projection = store.sidebarProjection(workspaces: workspaces)

        XCTAssertEqual(projection.groups.map(\.primaryBoardID), [board1.id])
        XCTAssertEqual(projection.groups.first?.boards.map(\.id), [board1.id, board2.id])
        XCTAssertEqual(projection.standaloneBoards.map(\.id), [permanent.id, board3.id])
        XCTAssertEqual(projection.standaloneBoards.filter(\.isDefault).count, 1)
    }

    func testSidebarProjectionAllowsBoardToAppearInMultipleGroups() {
        let suiteName = "WindowBoardTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let board1 = makeWorkspace(name: "Board 1", windows: [])
        let board2 = makeWorkspace(name: "Board 2", windows: [])
        let board3 = makeWorkspace(name: "Board 3", windows: [])
        let workspaces = [board1, board2, board3]
        let available = Set(workspaces.map(\.id))
        let store = BoardCompositionStore(defaults: defaults)
        _ = store.includeRoot(board2.id, for: board1.id, availableBoardIDs: available)
        _ = store.includeRoot(board2.id, for: board3.id, availableBoardIDs: available)

        let projection = store.sidebarProjection(workspaces: workspaces)

        XCTAssertEqual(projection.groups.map(\.primaryBoardID), [board1.id, board3.id])
        XCTAssertTrue(projection.groups.allSatisfy { $0.boards.contains(where: { $0.id == board2.id }) })
    }

    func testSidebarProjectionKeepsChildBoardStandaloneInsteadOfShowingItAsParallelTab() {
        let suiteName = "WindowBoardTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let parent = makeWorkspace(name: "Board 2", windows: [])
        let child = makeWorkspace(name: "Board 1", windows: [])
        let workspaces = [parent, child]
        let available = Set(workspaces.map(\.id))
        let store = BoardCompositionStore(defaults: defaults)
        _ = store.includeChild(child.id, in: parent.id, availableBoardIDs: available)

        let projection = store.sidebarProjection(workspaces: workspaces)

        XCTAssertTrue(projection.groups.isEmpty)
        XCTAssertEqual(projection.standaloneBoards.map(\.id), [parent.id, child.id])
    }

    func testSidebarProjectionShowsOnlyRootBoardsInParallelGroupAndKeepsChildrenStandalone() {
        let suiteName = "WindowBoardTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let primary = makeWorkspace(name: "Primary", windows: [])
        let root = makeWorkspace(name: "Root", windows: [])
        let child = makeWorkspace(name: "Child", windows: [])
        let workspaces = [primary, root, child]
        let available = Set(workspaces.map(\.id))
        let store = BoardCompositionStore(defaults: defaults)
        _ = store.includeRoot(root.id, for: primary.id, availableBoardIDs: available)
        _ = store.includeChild(child.id, in: primary.id, availableBoardIDs: available)

        let projection = store.sidebarProjection(workspaces: workspaces)

        XCTAssertEqual(projection.groups.first?.boards.map(\.id), [primary.id, root.id])
        XCTAssertEqual(projection.groups.first?.displayTitle, "Primary / Root")
        XCTAssertEqual(projection.standaloneBoards.map(\.id), [child.id])
    }

    @MainActor
    func testEditingIncludedBoardDoesNotChangeCurrentBoardSelection() async {
        let suiteName = "WindowBoardTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let workspaceStore = WorkspaceStore(defaults: defaults)
        let primary = workspaceStore.saveWorkspace(name: "Primary", windows: [])
        let included = workspaceStore.saveWorkspace(name: "Included", windows: [])
        let compositionStore = BoardCompositionStore(defaults: defaults)
        _ = compositionStore.includeRoot(
            included.id,
            for: primary.id,
            availableBoardIDs: Set(workspaceStore.workspaces.map(\.id))
        )
        let session = WorkspaceSessionController(
            workspaceStore: workspaceStore,
            defaults: defaults,
            boardCompositionStore: compositionStore,
            windowServiceFactory: { FakeWorkspaceWindowService(windows: []) }
        )
        session.switchWorkspace(
            id: primary.id,
            selectedBoardID: primary.id,
            boardOrigin: .zero,
            source: .mainWindow,
            followMode: .none,
            windowCache: []
        )
        await waitForWorkspaceSwitch(session)

        session.renameWorkspace(id: included.id, name: "Renamed Included")

        XCTAssertEqual(session.activeWorkspaceID, primary.id)
        XCTAssertEqual(session.selectedWorkspaceID, primary.id)
        XCTAssertEqual(workspaceStore.workspaces.first(where: { $0.id == included.id })?.name, "Renamed Included")
    }

    func testGlobalRootRemainsVisibleAcrossPrimaryBoardSwitches() {
        let suiteName = "WindowBoardTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let primaryA = makeWorkspace(name: "Primary A", windows: [])
        let primaryB = makeWorkspace(name: "Primary B", windows: [])
        let permanent = makeWorkspace(name: "Permanent Board", windows: [], isDefault: true)
        let workspaces = [primaryA, primaryB, permanent]
        let available = Set(workspaces.map(\.id))
        let store = BoardCompositionStore(
            defaults: defaults,
            availableBoardIDs: available,
            permanentBoardID: permanent.id
        )

        XCTAssertEqual(store.includeGlobalRoot(permanent.id, availableBoardIDs: available), .inserted)
        XCTAssertEqual(
            store.resolveCurrentBoard(primaryID: primaryA.id, workspaces: workspaces).roots.map(\.board.id),
            [primaryA.id, permanent.id]
        )
        XCTAssertEqual(
            store.resolveCurrentBoard(primaryID: primaryB.id, workspaces: workspaces).roots.map(\.board.id),
            [primaryB.id, permanent.id]
        )
        XCTAssertEqual(
            store.resolveCurrentBoard(primaryID: permanent.id, workspaces: workspaces).roots.map(\.board.id),
            [permanent.id]
        )
    }

    func testExistingPermanentRootMigratesToGlobalComposition() {
        let suiteName = "WindowBoardTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let primaryA = UUID()
        let primaryB = UUID()
        let permanent = UUID()
        let legacyData = BoardCompositionData(
            version: 2,
            rootBoardIDsByPrimaryID: [primaryA: [permanent]]
        )
        defaults.set(try! JSONEncoder().encode(legacyData), forKey: "boardComposition.v2")

        let store = BoardCompositionStore(
            defaults: defaults,
            availableBoardIDs: [primaryA, primaryB, permanent],
            permanentBoardID: permanent
        )

        XCTAssertTrue(store.isGloballyIncluded(permanent))
        XCTAssertEqual(store.rootBoardIDs(for: primaryA), [])
        XCTAssertEqual(store.displayedRootBoardIDs(for: primaryB), [permanent])
    }

    func testExcludingPermanentGlobalRootRemovesItFromEveryPrimary() {
        let suiteName = "WindowBoardTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let primary = UUID()
        let permanent = UUID()
        let available: Set<UUID> = [primary, permanent]
        let store = BoardCompositionStore(defaults: defaults)
        _ = store.includeGlobalRoot(permanent, availableBoardIDs: available)

        XCTAssertEqual(store.excludeGlobalRoot(permanent), .removed)
        XCTAssertFalse(store.isGloballyIncluded(permanent))
        XCTAssertEqual(store.displayedRootBoardIDs(for: primary), [])
    }

    func testLegacyGlobalCompositionMigratesToActiveBoardRoots() {
        let suiteName = "WindowBoardTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let primaryID = UUID()
        let includedID = UUID()
        defaults.set([includedID.uuidString], forKey: "includedBoardIDs")

        let store = BoardCompositionStore(
            defaults: defaults,
            migrationPrimaryID: primaryID,
            availableBoardIDs: [primaryID, includedID]
        )

        XCTAssertEqual(store.rootBoardIDs(for: primaryID), [includedID])
        XCTAssertNil(defaults.array(forKey: "includedBoardIDs"))
    }

    func testBoardCompositionRejectsSelfDuplicateAndCyclesButAllowsMultipleParents() {
        let suiteName = "WindowBoardTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = BoardCompositionStore(defaults: defaults)
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        let available: Set<UUID> = [a, b, c, d]
        XCTAssertEqual(store.includeChild(a, in: a, availableBoardIDs: available), .selfReference)
        XCTAssertEqual(store.includeChild(b, in: a, availableBoardIDs: available), .inserted)
        XCTAssertEqual(store.includeChild(b, in: a, availableBoardIDs: available), .duplicate)
        XCTAssertEqual(store.includeChild(c, in: b, availableBoardIDs: available), .inserted)
        XCTAssertEqual(store.includeChild(a, in: c, availableBoardIDs: available), .cycle)
        XCTAssertEqual(store.includeChild(c, in: d, availableBoardIDs: available), .inserted)
    }

    func testDeletingIncludedBoardRemovesCompositionReferenceImmediately() {
        let suiteName = "WindowBoardTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let workspaceStore = WorkspaceStore(defaults: defaults)
        let defaultBoard = try! XCTUnwrap(workspaceStore.defaultWorkspace)
        let includedBoard = workspaceStore.saveWorkspace(name: "Included", windows: [])
        let compositionStore = BoardCompositionStore(defaults: defaults)
        _ = compositionStore.includeRoot(
            includedBoard.id,
            for: defaultBoard.id,
            availableBoardIDs: Set(workspaceStore.workspaces.map(\.id))
        )
        let session = WorkspaceSessionController(
            workspaceStore: workspaceStore,
            defaults: defaults,
            boardCompositionStore: compositionStore,
            windowServiceFactory: { FakeWorkspaceWindowService(windows: []) }
        )
        session.activeWorkspaceID = defaultBoard.id
        session.selectedWorkspaceID = includedBoard.id

        session.deleteSelectedWorkspace()

        XCTAssertFalse(workspaceStore.workspaces.contains { $0.id == includedBoard.id })
        XCTAssertFalse(compositionStore.rootBoardIDs(for: defaultBoard.id).contains(includedBoard.id))
        XCTAssertEqual(session.activeWorkspaceID, defaultBoard.id)
    }

    @MainActor
    func testNewBoardLoadsIncludedCompositionThroughWorkspaceSwitch() async {
        let suiteName = "WindowBoardTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let includedReference = savedReference(title: "Shared Window", origin: CGPoint(x: 160, y: 180))
        let includedWindow = window(
            id: "shared-live",
            title: "Shared Window",
            position: CGPoint(x: 160, y: 180)
        )
        let workspaceStore = WorkspaceStore(defaults: defaults)
        let defaultBoard = try! XCTUnwrap(workspaceStore.defaultWorkspace)
        _ = workspaceStore.updateWorkspace(id: defaultBoard.id, windows: [includedReference])
        let compositionStore = BoardCompositionStore(defaults: defaults)
        let service = FakeWorkspaceWindowService(windows: [includedWindow])
        let session = WorkspaceSessionController(
            workspaceStore: workspaceStore,
            defaults: defaults,
            boardCompositionStore: compositionStore,
            windowServiceFactory: { service }
        )

        let newBoard = session.createWorkspace(boardOrigin: .zero)
        _ = compositionStore.includeRoot(
            defaultBoard.id,
            for: newBoard.id,
            availableBoardIDs: Set(workspaceStore.workspaces.map(\.id))
        )
        session.switchWorkspace(
            id: newBoard.id,
            boardOrigin: .zero,
            source: .mainWindow,
            followMode: .none,
            windowCache: [includedWindow]
        )
        await waitForWorkspaceSwitch(session)

        XCTAssertEqual(session.activeWorkspaceID, newBoard.id)
        XCTAssertEqual(session.attachedWindows.map(\.window.id), [includedWindow.id])
        _ = session.persistActiveWorkspaceSnapshotForSwitch(boardOrigin: .zero)
        let persistedNewBoard = try! XCTUnwrap(
            workspaceStore.workspaces.first { $0.id == newBoard.id }
        )
        XCTAssertTrue(persistedNewBoard.windows.isEmpty)
    }

    @MainActor
    func testWorkspaceSwitchIncludesComposedBoardWithoutCopyingItsWindowsIntoPrimary() async {
        let suiteName = "WindowBoardTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let primaryReference = savedReference(title: "Primary Window", origin: CGPoint(x: 20, y: 30))
        let includedReference = savedReference(title: "Included Window", origin: CGPoint(x: 200, y: 240))
        let primaryWindow = window(id: "primary-live", title: "Primary Window", position: CGPoint(x: 20, y: 30))
        let includedWindow = window(id: "included-live", title: "Included Window", position: CGPoint(x: 200, y: 240))
        let workspaceStore = WorkspaceStore(defaults: defaults)
        let defaultBoard = try! XCTUnwrap(workspaceStore.defaultWorkspace)
        _ = workspaceStore.updateWorkspace(id: defaultBoard.id, windows: [includedReference])
        let primaryBoard = workspaceStore.saveWorkspace(name: "Primary", windows: [primaryReference])
        let compositionStore = BoardCompositionStore(defaults: defaults)
        _ = compositionStore.includeRoot(
            defaultBoard.id,
            for: primaryBoard.id,
            availableBoardIDs: Set(workspaceStore.workspaces.map(\.id))
        )
        let service = FakeWorkspaceWindowService(windows: [primaryWindow, includedWindow])
        let session = WorkspaceSessionController(
            workspaceStore: workspaceStore,
            defaults: defaults,
            boardCompositionStore: compositionStore,
            windowServiceFactory: { service }
        )

        session.switchWorkspace(
            id: primaryBoard.id,
            boardOrigin: .zero,
            source: .statusItem,
            followMode: .none,
            windowCache: [primaryWindow, includedWindow]
        )
        await waitForWorkspaceSwitch(session)

        XCTAssertEqual(session.attachedWindows.map(\.window.title), ["Primary Window", "Included Window"])

        _ = session.persistActiveWorkspaceSnapshotForSwitch(boardOrigin: .zero)

        let persistedPrimary = try! XCTUnwrap(workspaceStore.workspaces.first { $0.id == primaryBoard.id })
        let persistedDefault = try! XCTUnwrap(workspaceStore.defaultWorkspace)
        XCTAssertEqual(persistedPrimary.windows.map(\.title), ["Primary Window"])
        XCTAssertEqual(persistedDefault.windows.map(\.title), ["Included Window"])
    }

    @MainActor
    func testSelectingMemberBoardKeepsCurrentBoardPrimaryLoaded() async {
        let suiteName = "WindowBoardTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let workspaceStore = WorkspaceStore(defaults: defaults)
        _ = try! XCTUnwrap(workspaceStore.defaultWorkspace)
        let board1 = workspaceStore.saveWorkspace(name: "Board 1", windows: [])
        let board2 = workspaceStore.saveWorkspace(name: "Board 2", windows: [])
        let board3 = workspaceStore.saveWorkspace(name: "Board 3", windows: [])
        let compositionStore = BoardCompositionStore(defaults: defaults)
        _ = compositionStore.includeRoot(
            board2.id,
            for: board1.id,
            availableBoardIDs: Set(workspaceStore.workspaces.map(\.id))
        )
        let session = WorkspaceSessionController(
            workspaceStore: workspaceStore,
            defaults: defaults,
            boardCompositionStore: compositionStore,
            windowServiceFactory: { FakeWorkspaceWindowService(windows: []) }
        )

        session.switchWorkspace(
            id: board1.id,
            selectedBoardID: board2.id,
            boardOrigin: .zero,
            source: .mainWindow,
            followMode: .none,
            windowCache: []
        )
        await waitForWorkspaceSwitch(session)

        XCTAssertEqual(session.activeWorkspaceID, board1.id)
        XCTAssertEqual(session.selectedWorkspaceID, board2.id)
        XCTAssertEqual(session.currentBoardComposition.uniqueBoards.map(\.id), [board1.id, board2.id])

        XCTAssertTrue(session.selectMemberBoard(board1.id))
        XCTAssertEqual(session.activeWorkspaceID, board1.id)
        XCTAssertEqual(session.selectedWorkspaceID, board1.id)

        XCTAssertFalse(session.selectMemberBoard(board3.id))
        XCTAssertEqual(session.activeWorkspaceID, board1.id)
        XCTAssertEqual(session.selectedWorkspaceID, board1.id)
    }

    @MainActor
    func testSelectingMemberDuringLoadIsNotOverwrittenByCompletion() async {
        let suiteName = "WindowBoardTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let workspaceStore = WorkspaceStore(defaults: defaults)
        let board1 = workspaceStore.saveWorkspace(name: "Board 1", windows: [])
        let board2 = workspaceStore.saveWorkspace(name: "Board 2", windows: [])
        let compositionStore = BoardCompositionStore(defaults: defaults)
        _ = compositionStore.includeRoot(
            board2.id,
            for: board1.id,
            availableBoardIDs: Set(workspaceStore.workspaces.map(\.id))
        )
        let service = FakeWorkspaceWindowService(windows: [])
        service.listWindowsDelay = 0.08
        let session = WorkspaceSessionController(
            workspaceStore: workspaceStore,
            defaults: defaults,
            boardCompositionStore: compositionStore,
            windowServiceFactory: { service }
        )

        session.switchWorkspace(
            id: board1.id,
            selectedBoardID: board1.id,
            boardOrigin: .zero,
            source: .mainWindow,
            followMode: .none
        )
        XCTAssertTrue(
            session.requestMemberSelection(
                memberBoardID: board2.id,
                groupPrimaryID: board1.id
            )
        )
        await waitForWorkspaceSwitch(session)

        XCTAssertEqual(session.activeWorkspaceID, board1.id)
        XCTAssertEqual(session.selectedWorkspaceID, board2.id)
    }

    @MainActor
    func testQueuedStatusItemSwitchKeepsItsSavedOriginSemantics() async {
        let suiteName = "WindowBoardTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let targetReference = savedReference(
            title: "Target",
            origin: CGPoint(x: 220, y: 260)
        )
        let targetWindow = window(
            id: "target-live",
            title: "Target",
            position: CGPoint(x: 900, y: 700)
        )
        let workspaceStore = WorkspaceStore(defaults: defaults)
        let firstBoard = workspaceStore.saveWorkspace(name: "First", windows: [])
        let targetBoard = workspaceStore.saveWorkspace(name: "Target", windows: [targetReference])
        let service = FakeWorkspaceWindowService(windows: [])
        service.listWindowsDelay = 0.08
        let session = WorkspaceSessionController(
            workspaceStore: workspaceStore,
            defaults: defaults,
            windowServiceFactory: { service }
        )

        session.switchWorkspace(
            id: firstBoard.id,
            boardOrigin: CGPoint(x: 500, y: 500),
            source: .mainWindow,
            followMode: .smooth
        )
        session.switchWorkspace(
            id: targetBoard.id,
            boardOrigin: nil,
            source: .statusItem,
            followMode: .smooth,
            windowCache: [targetWindow]
        )
        await waitForWorkspaceSwitch(session)

        XCTAssertEqual(session.activeWorkspaceID, targetBoard.id)
        XCTAssertEqual(service.positions[targetWindow.id], CGPoint(x: 220, y: 260))
    }

    @MainActor
    func testLauncherBoardTargetsPreservePrimaryAndSelectedMemberIDs() async {
        let suiteName = "WindowBoardTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let workspaceStore = WorkspaceStore(defaults: defaults)
        let primary = workspaceStore.saveWorkspace(name: "Primary", windows: [])
        let included = workspaceStore.saveWorkspace(name: "Included", windows: [])
        let standalone = workspaceStore.saveWorkspace(name: "Standalone", windows: [])
        let compositionStore = BoardCompositionStore(defaults: defaults)
        _ = compositionStore.includeRoot(
            included.id,
            for: primary.id,
            availableBoardIDs: Set(workspaceStore.workspaces.map(\.id))
        )
        let session = WorkspaceSessionController(
            workspaceStore: workspaceStore,
            defaults: defaults,
            boardCompositionStore: compositionStore,
            windowServiceFactory: { FakeWorkspaceWindowService(windows: []) }
        )

        let includedTarget = try! XCTUnwrap(session.boardSwitchTargets.first(where: {
            $0.primaryBoardID == primary.id && $0.selectedBoardID == included.id
        }))
        XCTAssertEqual(includedTarget.board.id, included.id)
        XCTAssertTrue(session.boardSwitchTargets.contains(where: {
            $0.primaryBoardID == standalone.id && $0.selectedBoardID == standalone.id
        }))

        XCTAssertTrue(session.switchWorkspaceFromLauncher(includedTarget, followMode: .smooth))
        await waitForWorkspaceSwitch(session)

        XCTAssertEqual(session.activeWorkspaceID, primary.id)
        XCTAssertEqual(session.selectedWorkspaceID, included.id)
    }

    @MainActor
    func testLauncherSwitchUsesSavedAbsoluteOriginWithFollowEnabled() async {
        let suiteName = "WindowBoardTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let reference = savedReference(
            title: "Target",
            origin: CGPoint(x: 220, y: 260)
        )
        let targetWindow = window(
            id: "launcher-target-live",
            title: "Target",
            position: CGPoint(x: 900, y: 700)
        )
        let workspaceStore = WorkspaceStore(defaults: defaults)
        let targetBoard = workspaceStore.saveWorkspace(name: "Target", windows: [reference])
        let service = FakeWorkspaceWindowService(windows: [targetWindow])
        let session = WorkspaceSessionController(
            workspaceStore: workspaceStore,
            defaults: defaults,
            windowServiceFactory: { service }
        )
        let target = try! XCTUnwrap(session.boardSwitchTargets.first(where: {
            $0.primaryBoardID == targetBoard.id && $0.selectedBoardID == targetBoard.id
        }))

        XCTAssertTrue(session.switchWorkspaceFromLauncher(target, followMode: .smooth))
        await waitForWorkspaceSwitch(session)

        XCTAssertEqual(session.activeWorkspaceID, targetBoard.id)
        XCTAssertEqual(service.positions[targetWindow.id], CGPoint(x: 220, y: 260))
    }

    @MainActor
    func testLauncherSwitchUsesCompleteCandidateCacheWithoutListingWindows() async {
        let suiteName = "WindowBoardTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let reference = savedReference(
            title: "Cached",
            origin: CGPoint(x: 240, y: 280)
        )
        let cachedWindow = window(
            id: "launcher-cached-window",
            title: "Cached",
            position: CGPoint(x: 900, y: 700)
        )
        let workspaceStore = WorkspaceStore(defaults: defaults)
        let board = workspaceStore.saveWorkspace(name: "Cached Board", windows: [reference])
        let service = FakeWorkspaceWindowService(windows: [cachedWindow])
        let session = WorkspaceSessionController(
            workspaceStore: workspaceStore,
            defaults: defaults,
            windowServiceFactory: { service }
        )
        let target = try! XCTUnwrap(session.boardSwitchTargets.first(where: {
            $0.primaryBoardID == board.id && $0.selectedBoardID == board.id
        }))

        XCTAssertTrue(
            session.switchWorkspaceFromLauncher(
                target,
                followMode: .smooth,
                candidateWindows: [cachedWindow]
            )
        )
        await waitForWorkspaceSwitch(session)

        XCTAssertEqual(service.listWindowsCallCount, 0)
        XCTAssertEqual(session.attachedWindows.first?.window.id, cachedWindow.id)
        XCTAssertEqual(service.positions[cachedWindow.id], CGPoint(x: 240, y: 280))
    }

    @MainActor
    func testLauncherCachedSwitchPublishesPlaceholderBeforeDeferredLayoutApplication() async {
        let suiteName = "WindowBoardTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let savedOrigin = CGPoint(x: 260, y: 300)
        let reference = savedReference(title: "Deferred", origin: savedOrigin)
        let cachedWindow = window(
            id: "launcher-deferred-window",
            title: "Deferred",
            position: CGPoint(x: 820, y: 640)
        )
        let workspaceStore = WorkspaceStore(defaults: defaults)
        let board = workspaceStore.saveWorkspace(name: "Deferred Board", windows: [reference])
        let service = FakeWorkspaceWindowService(windows: [cachedWindow])
        let session = WorkspaceSessionController(
            workspaceStore: workspaceStore,
            defaults: defaults,
            windowServiceFactory: { service }
        )
        let target = try! XCTUnwrap(session.boardSwitchTargets.first(where: {
            $0.primaryBoardID == board.id && $0.selectedBoardID == board.id
        }))

        XCTAssertTrue(
            session.switchWorkspaceFromLauncher(
                target,
                followMode: .smooth,
                candidateWindows: [cachedWindow]
            )
        )

        XCTAssertTrue(session.isLoadingWorkspace)
        XCTAssertEqual(session.attachedWindows.count, 1)
        XCTAssertEqual(session.attachedWindows.first?.id, reference.id)
        XCTAssertEqual(session.attachedWindows.first?.window.pid, 0)
        XCTAssertTrue(session.unavailableAttachedWindowIDs.contains(reference.id))
        XCTAssertEqual(service.positions[cachedWindow.id], CGPoint(x: 820, y: 640))

        await waitForWorkspaceSwitch(session)

        XCTAssertEqual(session.attachedWindows.first?.window.id, cachedWindow.id)
        XCTAssertEqual(service.positions[cachedWindow.id], savedOrigin)
    }

    @MainActor
    func testLauncherRestoreLayoutDoesNotOverwriteSavedLayoutWithCurrentPosition() async {
        let suiteName = "WindowBoardTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let savedOrigin = CGPoint(x: 220, y: 260)
        let reference = savedReference(title: "Target", origin: savedOrigin)
        let targetWindow = window(
            id: "restore-layout-live",
            title: "Target",
            position: CGPoint(x: 900, y: 700)
        )
        let workspaceStore = WorkspaceStore(defaults: defaults)
        let board = workspaceStore.saveWorkspace(name: "Target", windows: [reference])
        let service = FakeWorkspaceWindowService(windows: [targetWindow])
        let session = WorkspaceSessionController(
            workspaceStore: workspaceStore,
            defaults: defaults,
            windowServiceFactory: { service }
        )
        let target = try! XCTUnwrap(session.boardSwitchTargets.first(where: {
            $0.primaryBoardID == board.id && $0.selectedBoardID == board.id
        }))
        XCTAssertTrue(session.switchWorkspaceFromLauncher(target, followMode: .smooth))
        await waitForWorkspaceSwitch(session)

        let movedOrigin = CGPoint(x: 620, y: 480)
        service.positions[targetWindow.id] = movedOrigin
        session.attachedWindows[0].lastWindowOrigin = movedOrigin

        XCTAssertTrue(session.restoreLayoutFromLauncher(followMode: .smooth))
        await waitForWorkspaceSwitch(session)

        XCTAssertEqual(service.positions[targetWindow.id], savedOrigin)
        let storedBoard = try! XCTUnwrap(workspaceStore.workspaces.first(where: { $0.id == board.id }))
        XCTAssertEqual(storedBoard.windows.first?.savedOrigin, savedOrigin)
    }

    func testAttachedWindowSessionSnapshotsExposeCachedRuntimeState() {
        let workspace = makeWorkspace(name: "Current", windows: [])
        let session = makeSession(
            workspaces: [workspace],
            service: FakeWorkspaceWindowService(windows: [])
        )
        let storedWorkspace = try! XCTUnwrap(
            session.workspaceStore.workspaces.first(where: { $0.name == workspace.name })
        )
        session.activeWorkspaceID = storedWorkspace.id
        let liveWindow = window(
            id: "snapshot-live",
            title: "Document",
            bundleIdentifier: "com.example.Editor"
        )
        let attachment = AttachedWindow(
            window: liveWindow,
            lastBoardOrigin: .zero,
            lastWindowOrigin: .zero,
            lastAppliedOrigin: nil,
            pendingReleaseOrigin: nil
        )
        session.attachedWindows = [attachment]
        session.minimizedAttachedWindowIDs.insert(attachment.id)

        var snapshot = try! XCTUnwrap(session.attachedWindowSessionSnapshots.first)
        XCTAssertEqual(snapshot.state, .minimized)
        XCTAssertEqual(snapshot.ownerBoardID, storedWorkspace.id)
        XCTAssertEqual(snapshot.ownerBoardName, storedWorkspace.name)
        XCTAssertTrue(snapshot.isFromPrimaryBoard)
        XCTAssertEqual(snapshot.bundleIdentifier, "com.example.Editor")
        XCTAssertEqual(snapshot.displayName, "Editor - Document")

        session.unavailableAttachedWindowIDs.insert(attachment.id)
        snapshot = try! XCTUnwrap(session.attachedWindowSessionSnapshots.first)
        XCTAssertEqual(snapshot.state, .unavailable)

        session.reconnectingAttachedWindowIDs.insert(attachment.id)
        snapshot = try! XCTUnwrap(session.attachedWindowSessionSnapshots.first)
        XCTAssertEqual(snapshot.state, .reconnecting)

        session.isLoadingWorkspace = true
        snapshot = try! XCTUnwrap(session.attachedWindowSessionSnapshots.first)
        XCTAssertEqual(snapshot.state, .resolving)
    }

    func testSessionAttachWindowPersistsAndUpdatesDuplicateWithoutAddingAnotherReference() {
        let suiteName = "WindowBoardTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let workspaceStore = WorkspaceStore(defaults: defaults)
        let board = workspaceStore.saveWorkspace(name: "Target", windows: [])
        let session = WorkspaceSessionController(
            workspaceStore: workspaceStore,
            defaults: defaults,
            windowServiceFactory: { FakeWorkspaceWindowService(windows: []) }
        )
        session.activeWorkspaceID = board.id
        session.selectedWorkspaceID = board.id
        let firstWindow = window(
            id: "first-identity",
            title: "Document",
            windowNumber: 42,
            position: CGPoint(x: 320, y: 240)
        )

        let firstResult = session.attachWindow(
            firstWindow,
            boardOrigin: CGPoint(x: 20, y: 40)
        )
        guard case let .attached(attachmentID) = firstResult else {
            return XCTFail("Expected a new attachment")
        }
        XCTAssertEqual(session.attachedWindows.map(\.id), [attachmentID])
        var storedBoard = try! XCTUnwrap(workspaceStore.workspaces.first(where: { $0.id == board.id }))
        XCTAssertEqual(storedBoard.windows.count, 1)
        XCTAssertEqual(storedBoard.windows.first?.id, attachmentID)
        XCTAssertEqual(storedBoard.windows.first?.offsetX, 300)
        XCTAssertEqual(storedBoard.windows.first?.offsetY, 200)

        let replacement = window(
            id: "replacement-identity",
            title: "Document",
            windowNumber: 42,
            position: CGPoint(x: 500, y: 360)
        )
        let replacementResult = session.attachWindow(
            replacement,
            boardOrigin: CGPoint(x: 20, y: 40)
        )

        XCTAssertEqual(replacementResult, .updatedExisting(attachmentID))
        XCTAssertEqual(session.attachedWindows.count, 1)
        storedBoard = try! XCTUnwrap(workspaceStore.workspaces.first(where: { $0.id == board.id }))
        XCTAssertEqual(storedBoard.windows.count, 1)
        XCTAssertEqual(storedBoard.windows.first?.id, attachmentID)
        XCTAssertEqual(storedBoard.windows.first?.offsetX, 480)
        XCTAssertEqual(storedBoard.windows.first?.offsetY, 320)
    }

    func testSessionAttachWindowRejectsMissingPositionWithoutMutation() {
        let workspace = makeWorkspace(name: "Target", windows: [])
        let session = makeSession(
            workspaces: [workspace],
            service: FakeWorkspaceWindowService(windows: [])
        )
        let storedWorkspace = try! XCTUnwrap(
            session.workspaceStore.workspaces.first(where: { $0.name == workspace.name })
        )
        session.activeWorkspaceID = storedWorkspace.id
        let unreadableWindow = window(id: "missing-position", title: "Document", position: nil)

        XCTAssertEqual(
            session.attachWindow(unreadableWindow, boardOrigin: .zero),
            .missingWindowPosition
        )
        XCTAssertTrue(session.attachedWindows.isEmpty)
        XCTAssertTrue(
            session.workspaceStore.workspaces.first(where: { $0.id == storedWorkspace.id })?.windows.isEmpty == true
        )
    }

    func testBestExpectedFrontWindowRejectsDifferentAppAndUsesMatchingCandidate() {
        let unrelatedWindow = window(
            id: "unrelated",
            title: "Other",
            bundleIdentifier: "com.example.Other"
        )
        let matchingWindow = window(
            id: "matching",
            title: "Expected",
            bundleIdentifier: "com.example.Editor"
        )

        let resolved = WindowMatching.bestExpectedFrontWindow(
            in: [unrelatedWindow, matchingWindow],
            expectedBundleIdentifier: "com.example.Editor",
            expectedAppName: "Editor"
        )

        XCTAssertEqual(resolved?.id, matchingWindow.id)
    }

    @MainActor
    func testSwitchDoesNotStartAutomaticRecoveryWhenRestoreMissingIsDisabled() async {
        let reference = savedReference(title: "Missing")
        let workspace = makeWorkspace(name: "No Recovery", windows: [reference])
        let service = FakeWorkspaceWindowService(windows: [])
        let session = makeSession(workspaces: [workspace], service: service)
        let storedWorkspace = try! XCTUnwrap(session.workspaceStore.workspaces.first { $0.name == workspace.name })

        session.switchWorkspace(
            id: storedWorkspace.id,
            boardOrigin: .zero,
            source: .mainWindow,
            followMode: .none,
            windowCache: []
        )

        await waitForWorkspaceSwitch(session)

        XCTAssertTrue(service.openedReferences.isEmpty)
        XCTAssertTrue(service.activatedReferences.isEmpty)
        XCTAssertTrue(session.isUnavailable(reference.id))
    }

    @MainActor
    func testSwitchDefersAutomaticRecoveryUntilAfterInitialResolution() async {
        let reference = savedReference(title: "Recovered")
        let workspace = makeWorkspace(name: "Deferred Recovery", windows: [reference])
        let recoveredWindow = window(id: "recovered-window", title: "Recovered")
        let service = FakeWorkspaceWindowService(windows: [])
        service.listWindowsResponses = [[], [recoveredWindow]]
        service.openSavedReferenceResult = true
        let session = makeSession(
            workspaces: [workspace],
            service: service,
            restoreMissingWindowsOnSwitch: true
        )
        let storedWorkspace = try! XCTUnwrap(session.workspaceStore.workspaces.first { $0.name == workspace.name })

        session.switchWorkspace(
            id: storedWorkspace.id,
            boardOrigin: .zero,
            source: .mainWindow,
            followMode: .none,
            windowCache: []
        )

        await wait {
            !session.isLoadingWorkspace &&
                !session.isApplyingWorkspaceWindows &&
                !session.isReconnecting(reference.id) &&
                session.attachedWindows.first?.window.id == recoveredWindow.id
        }

        XCTAssertEqual(service.openedReferences.map(\.id), [reference.id])
        XCTAssertFalse(session.isUnavailable(reference.id))
    }

    @MainActor
    func testSwitchWorkspaceUsesSavedOriginForStatusItemWithCachedWindow() async {
        let reference = savedReference(title: "Saved", origin: CGPoint(x: 480, y: 320))
        let workspace = makeWorkspace(name: "Status", windows: [reference])
        let liveWindow = window(id: "saved-window", title: "Saved", position: CGPoint(x: 40, y: 50))
        let service = FakeWorkspaceWindowService(windows: [liveWindow])
        let session = makeSession(workspaces: [workspace], service: service)
        let storedWorkspace = try! XCTUnwrap(session.workspaceStore.workspaces.first { $0.name == workspace.name })

        session.switchWorkspace(
            id: storedWorkspace.id,
            boardOrigin: CGPoint(x: 10, y: 10),
            source: .statusItem,
            followMode: .none,
            windowCache: [liveWindow]
        )

        await waitForWorkspaceSwitch(session)

        XCTAssertEqual(session.activeWorkspaceID, storedWorkspace.id)
        XCTAssertEqual(session.attachedWindows.first?.lastWindowOrigin, CGPoint(x: 480, y: 320))
        XCTAssertEqual(service.positions[liveWindow.id], CGPoint(x: 480, y: 320))
        XCTAssertFalse(session.isUnavailable(reference.id))
    }

    @MainActor
    func testLayoutWriteFailureDoesNotMarkLiveWindowUnavailable() async {
        let reference = savedReference(title: "Live", origin: CGPoint(x: 320, y: 220))
        let workspace = makeWorkspace(name: "Live", windows: [reference])
        let liveWindow = window(id: "live-window", title: "Live", position: CGPoint(x: 10, y: 10))
        let service = FakeWorkspaceWindowService(windows: [liveWindow])
        service.positionWriteFailureIDs = [liveWindow.id]
        let session = makeSession(workspaces: [workspace], service: service)
        let storedWorkspace = try! XCTUnwrap(session.workspaceStore.workspaces.first { $0.name == workspace.name })

        session.switchWorkspace(
            id: storedWorkspace.id,
            boardOrigin: .zero,
            source: .mainWindow,
            followMode: .none,
            windowCache: [liveWindow]
        )

        await waitForWorkspaceSwitch(session)

        XCTAssertEqual(session.attachedWindows.map(\.window.id), [liveWindow.id])
        XCTAssertFalse(session.isUnavailable(reference.id))
    }

    @MainActor
    func testSwitchWorkspaceKeepsUnresolvedReferenceAttachedAsUnavailable() async {
        let reference = savedReference(title: "Missing", origin: CGPoint(x: 240, y: 180))
        let workspace = makeWorkspace(name: "Missing", windows: [reference])
        let session = makeSession(
            workspaces: [workspace],
            service: FakeWorkspaceWindowService(windows: [])
        )
        let storedWorkspace = try! XCTUnwrap(session.workspaceStore.workspaces.first { $0.name == workspace.name })

        session.switchWorkspace(
            id: storedWorkspace.id,
            boardOrigin: .zero,
            source: .mainWindow,
            followMode: .none,
            windowCache: []
        )

        await waitForWorkspaceSwitch(session)

        XCTAssertEqual(session.attachedWindows.count, 1)
        XCTAssertEqual(session.attachedWindows.first?.id, reference.id)
        XCTAssertEqual(session.attachedWindows.first?.window.pid, 0)
        XCTAssertTrue(session.isUnavailable(reference.id))
    }

    @MainActor
    func testMinimizeUnattachedProtectsOnlyAttachedWindows() async {
        let attached = window(id: "attached", title: "Attached", bundleIdentifier: "com.example.attached")
        let permanent = window(id: "permanent", title: "Permanent", bundleIdentifier: "com.example.permanent")
        let other = window(id: "other", title: "Other", bundleIdentifier: "com.example.other")
        let service = FakeWorkspaceWindowService(windows: [attached, permanent, other])
        let session = makeSession(service: service)
        session.attachedWindows = [
            AttachedWindow(
                window: attached,
                lastBoardOrigin: .zero,
                lastWindowOrigin: CGPoint(x: 20, y: 20),
                lastAppliedOrigin: nil,
                pendingReleaseOrigin: nil
            )
        ]
        session.minimizeUnattachedWindows(
            knownWindows: [attached, permanent, other],
            refreshWindowList: false
        )

        await waitForMinimization(session)

        XCTAssertFalse(service.minimizedWindowIDs.contains(attached.id))
        XCTAssertTrue(service.minimizedWindowIDs.contains(permanent.id))
        XCTAssertTrue(service.minimizedWindowIDs.contains(other.id))
        XCTAssertEqual(Set(session.minimizedWindows.map(\.id)), [permanent.id, other.id])
    }

    @MainActor
    func testRestoreKeepsOnlyWindowsThatCouldNotBeRestored() async {
        let restored = window(id: "restored", title: "Restored")
        let failed = window(id: "failed", title: "Failed")
        let service = FakeWorkspaceWindowService(windows: [restored, failed])
        service.minimizedWindowIDs = [restored.id, failed.id]
        service.minimizeWriteFailureIDs = [failed.id]
        let session = makeSession(service: service)
        session.minimizedWindows = [restored, failed]

        session.restoreMinimizedWindows()

        await waitForRestore(session)

        XCTAssertFalse(service.minimizedWindowIDs.contains(restored.id))
        XCTAssertTrue(service.minimizedWindowIDs.contains(failed.id))
        XCTAssertEqual(session.minimizedWindows.map(\.id), [failed.id])
    }

    @MainActor
    func testNewerSwitchRemainsActiveWhenPreviousResolutionFinishesLater() async {
        let firstReference = savedReference(title: "First")
        let secondReference = savedReference(title: "Second")
        let firstWorkspace = makeWorkspace(name: "First", windows: [firstReference])
        let secondWorkspace = makeWorkspace(name: "Second", windows: [secondReference])
        let secondWindow = window(id: "second-window", title: "Second")
        let service = FakeWorkspaceWindowService(windows: [secondWindow])
        service.listWindowsDelay = 0.05
        let session = makeSession(workspaces: [firstWorkspace, secondWorkspace], service: service)
        let storedFirstWorkspace = try! XCTUnwrap(session.workspaceStore.workspaces.first { $0.name == firstWorkspace.name })
        let storedSecondWorkspace = try! XCTUnwrap(session.workspaceStore.workspaces.first { $0.name == secondWorkspace.name })

        session.switchWorkspace(
            id: storedFirstWorkspace.id,
            boardOrigin: .zero,
            source: .mainWindow,
            followMode: .none,
            windowCache: []
        )
        session.switchWorkspace(
            id: storedSecondWorkspace.id,
            boardOrigin: .zero,
            source: .mainWindow,
            followMode: .none,
            windowCache: []
        )

        await waitForWorkspaceSwitch(session)

        XCTAssertEqual(session.activeWorkspaceID, storedSecondWorkspace.id)
        XCTAssertEqual(session.selectedWorkspaceID, storedSecondWorkspace.id)
        XCTAssertEqual(session.attachedWindows.map(\.window.id), [secondWindow.id])
    }

    func testBestReplacementPrefersDocumentURLBeforeTitle() {
        let original = window(title: "Report", documentURL: "file:///original")
        let documentMatch = window(id: "document", title: "Different", documentURL: "file:///original")
        let titleMatch = window(id: "title", title: "Report", documentURL: "file:///other")

        XCTAssertEqual(
            WindowMatching.bestReplacement(for: original, in: [titleMatch, documentMatch])?.id,
            documentMatch.id
        )
    }

    func testBestSavedWindowExcludesAlreadyUsedCandidates() {
        let reference = savedReference(title: "Report")
        let usedTitleMatch = window(id: "used", title: "Report")
        let availableFallback = window(id: "available", title: "Other")

        XCTAssertEqual(
            WindowMatching.bestSavedWindow(
                for: reference,
                in: [usedTitleMatch, availableFallback],
                excluding: [usedTitleMatch.id]
            )?.id,
            availableFallback.id
        )
    }

    func testBestSavedWindowSkipsDocumentURLForVisualStudioCode() {
        let reference = savedReference(
            title: "Expected Title",
            bundleIdentifier: "com.microsoft.VSCode",
            documentURL: "file:///workspace-a"
        )
        let documentMatch = window(
            id: "document",
            title: "Different Title",
            bundleIdentifier: "com.microsoft.VSCode",
            documentURL: "file:///workspace-a"
        )
        let titleMatch = window(
            id: "title",
            title: "Expected Title",
            bundleIdentifier: "com.microsoft.VSCode",
            documentURL: "file:///workspace-b"
        )

        XCTAssertEqual(
            WindowMatching.bestSavedWindow(for: reference, in: [documentMatch, titleMatch], excluding: [])?.id,
            titleMatch.id
        )
    }

    func testSavedReferenceUsesAbsoluteOriginAndValidSize() {
        let reference = savedReference(
            title: "Report",
            origin: CGPoint(x: 480, y: 240),
            size: CGSize(width: 1280, height: 800)
        )

        XCTAssertEqual(reference.targetOrigin(from: CGPoint(x: 20, y: 30), useSavedOrigin: true), CGPoint(x: 480, y: 240))
        XCTAssertEqual(reference.savedSize, CGSize(width: 1280, height: 800))
    }

    func testResolverUsesCachedWindowsWithoutASecondCandidatePass() {
        let first = savedReference(title: "First")
        let second = savedReference(title: "Second")
        let firstWindow = window(id: "first", title: "First")
        let secondWindow = window(id: "second", title: "Second")

        let resolution = WorkspaceWindowResolver.resolve(
            references: [first, second],
            candidates: [firstWindow, secondWindow],
            cachedWindowIDs: [first.id: firstWindow.id, second.id: secondWindow.id]
        )

        XCTAssertEqual(resolution.matches.map(\.window.id), [firstWindow.id, secondWindow.id])
        XCTAssertTrue(resolution.unresolvedReferences.isEmpty)
        XCTAssertEqual(resolution.loadedWindowIDs, [first.id: firstWindow.id, second.id: secondWindow.id])
    }

    func testResolverCompletesUnresolvedReferencesWithASecondCandidatePass() {
        let first = savedReference(title: "First")
        let second = savedReference(title: "Second")
        let firstWindow = window(id: "first", title: "First")
        let secondWindow = window(id: "second", title: "Second")

        let initial = WorkspaceWindowResolver.resolve(
            references: [first, second],
            candidates: [firstWindow],
            cachedWindowIDs: [first.id: firstWindow.id]
        )
        let resolved = WorkspaceWindowResolver.resolve(
            references: initial.unresolvedReferences,
            candidates: [firstWindow, secondWindow],
            cachedWindowIDs: [first.id: firstWindow.id, second.id: secondWindow.id],
            previous: initial
        )

        XCTAssertEqual(resolved.matches.map(\.window.id), [firstWindow.id, secondWindow.id])
        XCTAssertTrue(resolved.unresolvedReferences.isEmpty)
    }

    func testResolverDoesNotReuseOneWindowForMultipleReferences() {
        let first = savedReference(title: "Shared")
        let second = savedReference(title: "Shared")
        let sharedWindow = window(id: "shared", title: "Shared")

        let resolution = WorkspaceWindowResolver.resolve(
            references: [first, second],
            candidates: [sharedWindow],
            cachedWindowIDs: [:]
        )

        XCTAssertEqual(resolution.matches.count, 1)
        XCTAssertEqual(resolution.unresolvedReferences.map(\.id), [second.id])
    }

    func testResolverCreatesSavedOriginPlaceholderForUnresolvedReference() {
        let reference = savedReference(title: "Missing", origin: CGPoint(x: 640, y: 480))

        let placeholders = WorkspaceWindowResolver.placeholderAttachments(
            for: [reference],
            boardOrigin: CGPoint(x: 20, y: 30),
            useSavedOrigin: true
        )

        XCTAssertEqual(placeholders.count, 1)
        XCTAssertEqual(placeholders[0].id, reference.id)
        XCTAssertEqual(placeholders[0].lastWindowOrigin, CGPoint(x: 640, y: 480))
        XCTAssertEqual(placeholders[0].window.pid, 0)
    }

    func testRecoveryResolverUsesSavedReferenceMatchingWhenAvailable() {
        let reference = savedReference(title: "Saved", documentURL: "file:///saved")
        let original = window(id: "original", title: "Original", documentURL: "file:///original")
        let documentMatch = window(id: "document", title: "Different", documentURL: "file:///saved")
        let originalMatch = window(id: "original-match", title: "Original", documentURL: "file:///other")

        let replacement = AttachedWindowRecoveryResolver.replacementWindow(
            savedReference: reference,
            originalWindow: original,
            candidates: [originalMatch, documentMatch]
        )

        XCTAssertEqual(replacement?.id, documentMatch.id)
    }

    func testRecoveryResolverFallsBackToOriginalWindowMatchingWithoutSavedReference() {
        let original = window(id: "original", title: "Original", documentURL: "file:///original")
        let documentMatch = window(id: "document", title: "Different", documentURL: "file:///original")
        let titleMatch = window(id: "title", title: "Original", documentURL: "file:///other")

        let replacement = AttachedWindowRecoveryResolver.replacementWindow(
            savedReference: nil,
            originalWindow: original,
            candidates: [titleMatch, documentMatch]
        )

        XCTAssertEqual(replacement?.id, documentMatch.id)
    }

    func testRecoveryResolverFailureIssuePrefersReopenThenActivation() {
        XCTAssertEqual(
            AttachedWindowRecoveryResolver.failureIssue(
                didReopen: true,
                didActivateApplication: true
            ),
            .openedButNotMatched
        )
        XCTAssertEqual(
            AttachedWindowRecoveryResolver.failureIssue(
                didReopen: false,
                didActivateApplication: true
            ),
            .activatedButNotMatched
        )
        XCTAssertEqual(
            AttachedWindowRecoveryResolver.failureIssue(
                didReopen: false,
                didActivateApplication: false
            ),
            .couldNotOpen
        )
    }

    func testApplicationWindowCatalogMergesWithoutDuplicateIDsAndSortsByDisplayName() {
        let catalog = ApplicationWindowCatalog()
        let cached = window(id: "cached", title: "Zulu")
        let duplicate = window(id: "cached", title: "Updated")
        let added = window(id: "added", title: "Alpha")

        let merged = catalog.merging([duplicate, added], into: [cached])

        XCTAssertEqual(merged.map(\.id), [added.id, cached.id])
        XCTAssertEqual(merged.first(where: { $0.id == cached.id })?.title, cached.title)
    }

    func testApplicationWindowCatalogMergingEmptyInputStillSortsCachedWindows() {
        let catalog = ApplicationWindowCatalog()
        let second = window(id: "second", title: "Beta")
        let first = window(id: "first", title: "Alpha")

        XCTAssertEqual(
            catalog.merging([], into: [second, first]).map(\.id),
            [first.id, second.id]
        )
    }

    func testRecoveryCoordinatorReturnsAlreadyConnectedForLiveWindow() async {
        let original = window(id: "live", title: "Live", position: CGPoint(x: 220, y: 180))
        let service = FakeWorkspaceWindowService(windows: [original])
        let coordinator = makeRecoveryCoordinator(service: service)

        let result = await coordinator.recover(
            AttachedWindowRecoveryRequest(
                originalWindow: original,
                savedReference: nil,
                shouldTryMinimizedRestore: false
            )
        )

        guard case let .alreadyConnected(position) = result else {
            return XCTFail("Expected an already-connected result.")
        }
        XCTAssertEqual(position, CGPoint(x: 220, y: 180))
    }

    func testRecoveryCoordinatorRestoresMinimizedOriginalWindow() async {
        let original = window(id: "minimized", title: "Minimized")
        let service = FakeWorkspaceWindowService(windows: [original])
        service.minimizedWindowIDs.insert(original.id)
        let coordinator = makeRecoveryCoordinator(service: service)

        let result = await coordinator.recover(
            AttachedWindowRecoveryRequest(
                originalWindow: original,
                savedReference: nil,
                shouldTryMinimizedRestore: true
            )
        )

        guard case .restoredOriginal = result else {
            return XCTFail("Expected the minimized original window to be restored.")
        }
        XCTAssertFalse(service.minimizedWindowIDs.contains(original.id))
    }

    func testRecoveryCoordinatorReconnectsUsingSavedReference() async {
        let original = window(id: "stale", title: "Old", position: nil)
        let replacement = window(id: "replacement", title: "Saved")
        let reference = savedReference(title: "Saved")
        let service = FakeWorkspaceWindowService(windows: [replacement])
        service.openSavedReferenceResult = true
        let coordinator = makeRecoveryCoordinator(service: service)

        let result = await coordinator.recover(
            AttachedWindowRecoveryRequest(
                originalWindow: original,
                savedReference: reference,
                shouldTryMinimizedRestore: false
            )
        )

        guard case let .reconnected(window, discoveredWindows) = result else {
            return XCTFail("Expected a reconnected result.")
        }
        XCTAssertEqual(window.id, replacement.id)
        XCTAssertEqual(discoveredWindows.map(\.id), [replacement.id])
        XCTAssertEqual(service.openedReferences.count, 1)
    }

    func testRecoveryCoordinatorReportsActivationWithoutMatch() async {
        let original = window(id: "missing", title: "Missing", position: nil)
        let service = FakeWorkspaceWindowService(windows: [])
        service.activateOrOpenApplicationResult = true
        let coordinator = makeRecoveryCoordinator(service: service)

        let result = await coordinator.recover(
            AttachedWindowRecoveryRequest(
                originalWindow: original,
                savedReference: nil,
                shouldTryMinimizedRestore: false
            )
        )

        guard case let .notMatched(issue, discoveredWindows) = result else {
            return XCTFail("Expected a not-matched result.")
        }
        XCTAssertEqual(issue, .activatedButNotMatched)
        XCTAssertTrue(discoveredWindows.isEmpty)
    }

    func testRecoveryCoordinatorFindsExpectedVisibleFrontWindow() async {
        let expected = window(id: "front", title: "Front")
        let service = FakeWorkspaceWindowService(windows: [expected])
        service.frontmostVisibleWindow = expected
        let coordinator = makeRecoveryCoordinator(service: service)

        let result = await coordinator.findFrontWindow(
            application: nil,
            expectedBundleIdentifier: expected.bundleIdentifier,
            expectedAppName: expected.appName
        )

        guard case let .matched(window, position, size) = result else {
            return XCTFail("Expected the visible front window to match.")
        }
        XCTAssertEqual(window.id, expected.id)
        XCTAssertEqual(position, expected.position)
        XCTAssertEqual(size, CGSize(width: 800, height: 600))
    }

    func testBoardFollowPlannerAppliesXDeltaAndInvertsYDelta() {
        let attached = AttachedWindow(
            window: window(id: "follow", title: "Follow"),
            lastBoardOrigin: CGPoint(x: 100, y: 100),
            lastWindowOrigin: CGPoint(x: 400, y: 300),
            lastAppliedOrigin: CGPoint(x: 400, y: 300),
            pendingReleaseOrigin: nil
        )

        let update = BoardFollowPlanner.updates(
            for: CGPoint(x: 125, y: 140),
            attachedWindows: [attached],
            unavailableAttachmentIDs: []
        ).first

        XCTAssertEqual(update?.targetOrigin, CGPoint(x: 425, y: 260))
    }

    func testBoardFollowPlannerOnlyUpdatesBaselineForUnavailableWindow() {
        let attached = AttachedWindow(
            window: window(id: "unavailable", title: "Unavailable"),
            lastBoardOrigin: .zero,
            lastWindowOrigin: CGPoint(x: 300, y: 200),
            lastAppliedOrigin: CGPoint(x: 300, y: 200),
            pendingReleaseOrigin: nil
        )

        let update = BoardFollowPlanner.updates(
            for: CGPoint(x: 40, y: 30),
            attachedWindows: [attached],
            unavailableAttachmentIDs: [attached.id]
        ).first

        XCTAssertEqual(update?.boardOrigin, CGPoint(x: 40, y: 30))
        XCTAssertNil(update?.targetOrigin)
    }

    func testBoardFollowPlannerSkipsSubpointMove() {
        let attached = AttachedWindow(
            window: window(id: "small", title: "Small"),
            lastBoardOrigin: .zero,
            lastWindowOrigin: CGPoint(x: 200, y: 200),
            lastAppliedOrigin: CGPoint(x: 200.5, y: 199.5),
            pendingReleaseOrigin: nil
        )

        let update = BoardFollowPlanner.updates(
            for: CGPoint(x: 0.5, y: 0.5),
            attachedWindows: [attached],
            unavailableAttachmentIDs: []
        ).first

        XCTAssertNil(update?.targetOrigin)
    }

    func testBoardFollowPlannerMovesAtExactlyOnePointAndPreservesOrder() {
        let first = AttachedWindow(
            window: window(id: "first-follow", title: "First"),
            lastBoardOrigin: .zero,
            lastWindowOrigin: CGPoint(x: 100, y: 100),
            lastAppliedOrigin: CGPoint(x: 100, y: 100),
            pendingReleaseOrigin: nil
        )
        let second = AttachedWindow(
            window: window(id: "second-follow", title: "Second"),
            lastBoardOrigin: .zero,
            lastWindowOrigin: CGPoint(x: 200, y: 200),
            lastAppliedOrigin: CGPoint(x: 200, y: 200),
            pendingReleaseOrigin: nil
        )

        let updates = BoardFollowPlanner.updates(
            for: CGPoint(x: 1, y: 0),
            attachedWindows: [first, second],
            unavailableAttachmentIDs: []
        )

        XCTAssertEqual(updates.map(\.attachmentID), [first.id, second.id])
        XCTAssertEqual(updates[0].targetOrigin, CGPoint(x: 101, y: 100))
        XCTAssertEqual(updates[1].targetOrigin, CGPoint(x: 201, y: 200))
    }

    @MainActor
    func testBoardFollowCoordinatorDebouncesReleaseToLatestOrigin() async {
        let coordinator = BoardFollowCoordinator(releaseIdleDelay: 0.01, autoFrontIdleDelay: 0.01)
        var releasedOrigin: CGPoint?
        var usedImmediateStyle = false

        for origin in [CGPoint(x: 10, y: 10), CGPoint(x: 30, y: 40)] {
            coordinator.recordMovement(
                to: origin,
                mode: .onRelease,
                hasAttachedWindows: true,
                currentMode: { .onRelease },
                applySmoothMove: { _ in XCTFail("On Release must not move immediately.") },
                applyReleaseMove: { origin, style in
                    releasedOrigin = origin
                    if case .immediate = style {
                        usedImmediateStyle = true
                    }
                }
            )
        }

        try? await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(releasedOrigin, CGPoint(x: 30, y: 40))
        XCTAssertTrue(usedImmediateStyle)
    }

    @MainActor
    func testBoardFollowCoordinatorUsesAnimatedStyleForAnimatedRelease() async {
        let coordinator = BoardFollowCoordinator(releaseIdleDelay: 0.01, autoFrontIdleDelay: 0.01)
        var usedAnimatedStyle = false

        coordinator.recordMovement(
            to: CGPoint(x: 12, y: 18),
            mode: .animatedRelease,
            hasAttachedWindows: true,
            currentMode: { .animatedRelease },
            applySmoothMove: { _ in XCTFail("Animated Release must not move immediately.") },
            applyReleaseMove: { _, style in
                if case .animated = style {
                    usedAnimatedStyle = true
                }
            }
        )

        try? await Task.sleep(for: .milliseconds(40))
        XCTAssertTrue(usedAnimatedStyle)
    }

    private func window(
        id: String = UUID().uuidString,
        title: String,
        bundleIdentifier: String? = "com.example.Editor",
        documentURL: String? = nil,
        windowNumber: CGWindowID? = nil,
        position: CGPoint? = CGPoint(x: 100, y: 100)
    ) -> WindowInfo {
        WindowInfo(
            id: id,
            appName: "Editor",
            title: title,
            pid: 1,
            bundleIdentifier: bundleIdentifier,
            bundleURL: nil,
            documentURL: documentURL.flatMap(URL.init(string:)),
            axWindow: AXUIElementCreateApplication(1),
            windowNumber: windowNumber,
            position: position
        )
    }

    private func savedReference(
        title: String,
        bundleIdentifier: String? = "com.example.Editor",
        documentURL: String? = nil,
        origin: CGPoint? = nil,
        size: CGSize? = nil
    ) -> SavedWindowReference {
        SavedWindowReference(
            id: UUID(),
            displayName: "Editor - \(title)",
            appName: "Editor",
            title: title,
            bundleIdentifier: bundleIdentifier,
            bundleURLString: nil,
            documentURLString: documentURL,
            workspaceURLString: nil,
            offsetX: 40,
            offsetY: 60,
            originX: origin?.x,
            originY: origin?.y,
            width: size?.width,
            height: size?.height
        )
    }

    private func makeWorkspace(
        name: String,
        windows: [SavedWindowReference],
        isDefault: Bool = false
    ) -> SavedWorkspace {
        SavedWorkspace(
            id: UUID(),
            name: name,
            statusItemSymbolName: nil,
            createdAt: Date(),
            updatedAt: Date(),
            windows: windows,
            isDefault: isDefault
        )
    }

    private func makeRecoveryCoordinator(
        service: FakeWorkspaceWindowService
    ) -> AttachedWindowRecoveryCoordinator {
        AttachedWindowRecoveryCoordinator(
            serviceFactory: { service },
            maximumAttempts: 1,
            shortDelayAttemptLimit: 1,
            shortRetryDelay: .zero,
            longRetryDelay: .zero,
            restoreSettleDelay: .zero
        )
    }

    private func makeSession(
        workspaces: [SavedWorkspace] = [],
        service: FakeWorkspaceWindowService,
        restoreMissingWindowsOnSwitch: Bool = false
    ) -> WorkspaceSessionController {
        let suiteName = "WindowBoardTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(restoreMissingWindowsOnSwitch, forKey: "restoreMissingWindowsOnWorkspaceSwitch")
        let store = WorkspaceStore(defaults: defaults)
        for workspace in workspaces {
            _ = store.saveWorkspace(name: workspace.name, windows: workspace.windows)
        }

        return WorkspaceSessionController(
            workspaceStore: store,
            defaults: defaults,
            windowServiceFactory: { service }
        )
    }

    private func waitForWorkspaceSwitch(
        _ session: WorkspaceSessionController,
        timeout: TimeInterval = 2
    ) async {
        await wait(timeout: timeout) {
            !session.isLoadingWorkspace && !session.isApplyingWorkspaceWindows
        }
    }

    private func waitForMinimization(_ session: WorkspaceSessionController) async {
        await wait {
            !session.isMinimizingUnattached
        }
    }

    private func waitForRestore(_ session: WorkspaceSessionController) async {
        await wait {
            !session.isRestoringMinimized
        }
    }

    private func wait(
        timeout: TimeInterval = 2,
        until condition: @escaping () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertTrue(condition(), "Timed out waiting for asynchronous state to settle.")
    }
}

private final class FakeWorkspaceWindowService: ContentWindowOperating, @unchecked Sendable {
    var windowsToList: [WindowInfo]
    var matchingWindowsByID: [WindowInfo.ID: [WindowInfo]] = [:]
    var positions: [WindowInfo.ID: CGPoint] = [:]
    var sizes: [WindowInfo.ID: CGSize] = [:]
    var minimizedWindowIDs: Set<WindowInfo.ID> = []
    var positionReadFailureIDs: Set<WindowInfo.ID> = []
    var positionWriteFailureIDs: Set<WindowInfo.ID> = []
    var sizeReadFailureIDs: Set<WindowInfo.ID> = []
    var sizeWriteFailureIDs: Set<WindowInfo.ID> = []
    var minimizeWriteFailureIDs: Set<WindowInfo.ID> = []
    var listWindowsDelay: TimeInterval = 0
    var listWindowsResponses: [[WindowInfo]] = []
    var openSavedReferenceResult = false
    var activateSavedApplicationResult = false
    var openDocumentResult = false
    var activateOrOpenApplicationResult = false
    var frontmostVisibleWindow: WindowInfo?
    private(set) var openedReferences: [SavedWindowReference] = []
    private(set) var activatedReferences: [SavedWindowReference] = []
    private(set) var raisedWindowIDs: [WindowInfo.ID] = []
    private(set) var listWindowsCallCount = 0

    init(windows: [WindowInfo]) {
        windowsToList = windows
        positions = Dictionary(uniqueKeysWithValues: windows.compactMap { window in
            window.position.map { (window.id, $0) }
        })
        sizes = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, CGSize(width: 800, height: 600)) })
    }

    func listWindows() -> [WindowInfo] {
        if listWindowsDelay > 0 {
            Thread.sleep(forTimeInterval: listWindowsDelay)
        }

        let callIndex = listWindowsCallCount
        listWindowsCallCount += 1
        if !listWindowsResponses.isEmpty {
            let index = min(callIndex, listWindowsResponses.count - 1)
            return listWindowsResponses[index]
        }

        return windowsToList
    }

    func windows(matching window: WindowInfo) -> [WindowInfo] {
        matchingWindowsByID[window.id] ?? windowsToList.filter {
            $0.pid == window.pid || $0.bundleIdentifier == window.bundleIdentifier || $0.appName == window.appName
        }
    }

    func position(of window: WindowInfo) throws -> CGPoint {
        guard !positionReadFailureIDs.contains(window.id), let position = positions[window.id] else {
            throw WindowBoardAXError.missingPosition
        }
        return position
    }

    func size(of window: WindowInfo) throws -> CGSize {
        guard !sizeReadFailureIDs.contains(window.id), let size = sizes[window.id] else {
            throw WindowBoardAXError.missingSize
        }
        return size
    }

    func setPosition(_ position: CGPoint, for window: WindowInfo) throws {
        guard !positionWriteFailureIDs.contains(window.id) else {
            throw WindowBoardAXError.missingPosition
        }
        positions[window.id] = position
    }

    func setSize(_ size: CGSize, for window: WindowInfo) throws {
        guard !sizeWriteFailureIDs.contains(window.id) else {
            throw WindowBoardAXError.missingSize
        }
        sizes[window.id] = size
    }

    func isMinimized(_ window: WindowInfo) -> Bool {
        minimizedWindowIDs.contains(window.id)
    }

    func setMinimized(_ minimized: Bool, for window: WindowInfo) throws {
        guard !minimizeWriteFailureIDs.contains(window.id) else {
            throw WindowBoardAXError.missingPosition
        }

        if minimized {
            minimizedWindowIDs.insert(window.id)
        } else {
            minimizedWindowIDs.remove(window.id)
        }
    }

    func raise(_ window: WindowInfo) {
        raisedWindowIDs.append(window.id)
    }

    func openSavedWindowReference(_ reference: SavedWindowReference) -> Bool {
        openedReferences.append(reference)
        return openSavedReferenceResult
    }

    func activateSavedApplication(_ reference: SavedWindowReference) -> Bool {
        activatedReferences.append(reference)
        return activateSavedApplicationResult
    }

    func isTrusted() -> Bool { true }
    func requestAccessPrompt() {}
    func openAccessibilitySettings() {}

    func frontmostWindow(for application: NSRunningApplication) -> WindowInfo? {
        windowsToList.first { $0.pid == application.processIdentifier }
    }

    func frontmostVisibleExternalWindow(excludingProcessID excludedPID: pid_t) -> WindowInfo? {
        frontmostVisibleWindow
    }

    func windows(for application: NSRunningApplication) -> [WindowInfo] {
        windowsToList.filter { $0.pid == application.processIdentifier }
    }

    func title(of window: WindowInfo) -> String? { window.title }
    func raiseWindowOnly(_ window: WindowInfo) {}
    func activateApplication(for window: WindowInfo) {}
    func activateApplication(pid: pid_t) -> Bool { true }

    func openDocument(for window: WindowInfo) -> Bool {
        openDocumentResult
    }

    func activateOrOpenApplication(for window: WindowInfo) -> Bool {
        activateOrOpenApplicationResult
    }

    func focusWindow(_ window: WindowInfo) {}
}
