import ApplicationServices
import XCTest
@testable import WindowBoard

@MainActor
final class TreeBoardWindowControllerTests: XCTestCase {
    func testTreeDragPayloadsRoundTripThroughCodable() throws {
        let boardPayload = TreeBoardDragPayload(boardID: UUID())
        let windowPayload = TreeWindowDragPayload(
            referenceID: UUID(),
            sourceBoardID: UUID()
        )
        let favoritePayload = TreeFavoriteDragPayload(boardID: UUID())

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        XCTAssertEqual(
            try decoder.decode(TreeBoardDragPayload.self, from: encoder.encode(boardPayload)),
            boardPayload
        )
        XCTAssertEqual(
            try decoder.decode(TreeWindowDragPayload.self, from: encoder.encode(windowPayload)),
            windowPayload
        )
        XCTAssertEqual(
            try decoder.decode(TreeFavoriteDragPayload.self, from: encoder.encode(favoritePayload)),
            favoritePayload
        )
    }

    func testResolverKeepsUnmatchedReferenceUnavailable() {
        let reference = makeReference(title: "Missing")

        let rows = TreeBoardWindowResolver.resolve(
            references: [reference],
            candidates: []
        )

        XCTAssertEqual(rows.map(\.id), [reference.id])
        XCTAssertEqual(rows.first?.state, .unavailable)
        XCTAssertNil(rows.first?.liveWindow)
    }

    func testResolverDoesNotReuseOneLiveWindowForTwoReferences() {
        let first = makeReference(title: "Report")
        let second = makeReference(title: "Report")
        let liveWindow = makeWindow(id: "live", title: "Report")

        let rows = TreeBoardWindowResolver.resolve(
            references: [first, second],
            candidates: [liveWindow]
        )

        XCTAssertEqual(rows[0].state, .available)
        XCTAssertEqual(rows[1].state, .unavailable)
    }

    func testAttachAndDetachPersistOnlySelectedBoard() async throws {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }
        let store = WorkspaceStore(defaults: defaults, defaultWorkspaceName: "Root Board")
        let root = try XCTUnwrap(store.defaultWorkspace)
        let other = store.saveWorkspace(name: "Other", windows: [])
        let window = makeWindow(id: "live", title: "Report")
        let service = FakeTreeWindowService(windows: [window])
        let controller = TreeBoardWindowController(
            workspaceStore: store,
            serviceFactory: { service }
        )

        await controller.loadBoard(root.id)
        await controller.attachWindow(id: window.id)

        XCTAssertEqual(store.workspaces.first(where: { $0.id == root.id })?.windows.count, 1)
        XCTAssertTrue(store.workspaces.first(where: { $0.id == other.id })?.windows.isEmpty == true)
        let referenceID = try XCTUnwrap(controller.rows.first?.id)

        controller.detach(referenceID: referenceID)

        XCTAssertTrue(store.workspaces.first(where: { $0.id == root.id })?.windows.isEmpty == true)
        XCTAssertTrue(store.workspaces.first(where: { $0.id == other.id })?.windows.isEmpty == true)
    }

    func testLoadingAnotherBoardDoesNotCopyWindows() async throws {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }
        let store = WorkspaceStore(defaults: defaults, defaultWorkspaceName: "Root Board")
        let root = try XCTUnwrap(store.defaultWorkspace)
        let reference = makeReference(title: "Child Window")
        let child = store.saveWorkspace(name: "Child", windows: [reference])
        let liveWindow = makeWindow(id: "child-live", title: "Child Window")
        let service = FakeTreeWindowService(windows: [liveWindow])
        let controller = TreeBoardWindowController(
            workspaceStore: store,
            serviceFactory: { service }
        )

        await controller.loadBoard(child.id)
        XCTAssertEqual(controller.rows.map(\.id), [reference.id])
        XCTAssertEqual(controller.rows.first?.state, .available)

        await controller.loadBoard(root.id)
        XCTAssertTrue(controller.rows.isEmpty)
        XCTAssertTrue(store.workspaces.first(where: { $0.id == root.id })?.windows.isEmpty == true)
        XCTAssertEqual(store.workspaces.first(where: { $0.id == child.id })?.windows, [reference])
    }

    func testShowRestoresMinimizedWindowBeforeRaising() async throws {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }
        let window = makeWindow(id: "minimized", title: "Minimized")
        let reference = makeReference(title: "Minimized")
        let store = WorkspaceStore(defaults: defaults, defaultWorkspaceName: "Root Board")
        let root = try XCTUnwrap(store.defaultWorkspace)
        _ = store.updateWorkspace(id: root.id, windows: [reference])
        let service = FakeTreeWindowService(windows: [window], minimizedWindowIDs: [window.id])
        let controller = TreeBoardWindowController(
            workspaceStore: store,
            serviceFactory: { service }
        )

        await controller.loadBoard(root.id)
        XCTAssertEqual(controller.rows.first?.state, .minimized)

        await controller.showWindow(referenceID: reference.id)

        XCTAssertFalse(service.minimizedWindowIDs.contains(window.id))
        XCTAssertEqual(service.raisedWindowIDs, [window.id])
        XCTAssertEqual(controller.rows.first?.state, .available)
    }

    func testMoveWindowTransfersReferenceWithoutAccessibilityWork() throws {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }
        let reference = makeReference(title: "Move Me")
        let store = WorkspaceStore(defaults: defaults, defaultWorkspaceName: "Root Board")
        let source = try XCTUnwrap(store.defaultWorkspace)
        _ = store.updateWorkspace(id: source.id, windows: [reference])
        let destination = store.saveWorkspace(name: "Destination", windows: [])
        let service = FakeTreeWindowService(windows: [])
        let controller = TreeBoardWindowController(
            workspaceStore: store,
            serviceFactory: { service }
        )

        let result = controller.moveWindow(
            referenceID: reference.id,
            from: source.id,
            to: destination.id
        )

        XCTAssertEqual(result, .moved)
        XCTAssertTrue(store.workspaces.first(where: { $0.id == source.id })?.windows.isEmpty == true)
        XCTAssertEqual(
            store.workspaces.first(where: { $0.id == destination.id })?.windows,
            [reference]
        )
        XCTAssertEqual(service.listWindowsCallCount, 0)
        XCTAssertTrue(service.raisedWindowIDs.isEmpty)
    }

    func testMoveWindowRejectsDuplicateAndKeepsSourceReference() throws {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }
        let sourceReference = makeReference(title: "Same Window")
        let destinationReference = makeReference(title: "Same Window")
        let store = WorkspaceStore(defaults: defaults, defaultWorkspaceName: "Root Board")
        let source = try XCTUnwrap(store.defaultWorkspace)
        _ = store.updateWorkspace(id: source.id, windows: [sourceReference])
        let destination = store.saveWorkspace(
            name: "Destination",
            windows: [destinationReference]
        )
        let controller = TreeBoardWindowController(
            workspaceStore: store,
            serviceFactory: { FakeTreeWindowService(windows: []) }
        )

        let result = controller.moveWindow(
            referenceID: sourceReference.id,
            from: source.id,
            to: destination.id
        )

        XCTAssertEqual(result, .duplicate)
        XCTAssertEqual(
            store.workspaces.first(where: { $0.id == source.id })?.windows,
            [sourceReference]
        )
        XCTAssertEqual(
            store.workspaces.first(where: { $0.id == destination.id })?.windows,
            [destinationReference]
        )
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "TreeBoardWindowControllerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set(suiteName, forKey: "testSuiteName")
        return defaults
    }

    private func defaultsSuiteName(_ defaults: UserDefaults) -> String {
        defaults.string(forKey: "testSuiteName")!
    }

    private func makeReference(title: String) -> SavedWindowReference {
        SavedWindowReference(
            id: UUID(),
            displayName: "Test - \(title)",
            appName: "Test",
            title: title,
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

    private func makeWindow(id: String, title: String) -> WindowInfo {
        WindowInfo(
            id: id,
            appName: "Test",
            title: title,
            pid: 42,
            bundleIdentifier: "com.example.test",
            bundleURL: nil,
            documentURL: nil,
            axWindow: AXUIElementCreateApplication(42),
            windowNumber: nil,
            position: CGPoint(x: 100, y: 100)
        )
    }
}

private final class FakeTreeWindowService: TreeWindowOperating, @unchecked Sendable {
    var trusted = true
    var windows: [WindowInfo]
    var minimizedWindowIDs: Set<WindowInfo.ID>
    private(set) var raisedWindowIDs: [WindowInfo.ID] = []
    private(set) var listWindowsCallCount = 0

    init(
        windows: [WindowInfo],
        minimizedWindowIDs: Set<WindowInfo.ID> = []
    ) {
        self.windows = windows
        self.minimizedWindowIDs = minimizedWindowIDs
    }

    func isTrusted() -> Bool { trusted }
    func requestAccessPrompt() {}
    func openAccessibilitySettings() {}
    func listWindows() -> [WindowInfo] {
        listWindowsCallCount += 1
        return windows
    }
    func position(of window: WindowInfo) throws -> CGPoint { window.position ?? .zero }
    func size(of window: WindowInfo) throws -> CGSize { CGSize(width: 800, height: 600) }
    func isMinimized(_ window: WindowInfo) -> Bool { minimizedWindowIDs.contains(window.id) }

    func setMinimized(_ minimized: Bool, for window: WindowInfo) throws {
        if minimized {
            minimizedWindowIDs.insert(window.id)
        } else {
            minimizedWindowIDs.remove(window.id)
        }
    }

    func raise(_ window: WindowInfo) {
        raisedWindowIDs.append(window.id)
    }

    func frontmostVisibleExternalWindow(excludingProcessID excludedPID: pid_t) -> WindowInfo? {
        windows.first
    }
}
