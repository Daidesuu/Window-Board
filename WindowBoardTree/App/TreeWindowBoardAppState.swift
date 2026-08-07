import Combine
import Foundation

@MainActor
final class TreeWindowBoardAppState: ObservableObject {
    let workspaceStore: WorkspaceStore
    let treeStore: BoardTreeStore
    let directory: BoardDirectoryController
    let windowController: TreeBoardWindowController

    @Published private(set) var storageError: String?
    @Published private(set) var expandedBoardIDs: Set<SavedWorkspace.ID>
    @Published private(set) var navigationHistory: TreeNavigationHistory
    @Published var operationMessage: String?

    private let defaults: UserDefaults
    private var cancellables: Set<AnyCancellable> = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        storageError = nil
        operationMessage = nil
        let bootstrapResult: BoardStorageBootstrapResult?
        do {
            bootstrapResult = try BoardStorageBootstrapper.prepareDirectoryTreeStorage(
                defaults: defaults
            )
        } catch {
            bootstrapResult = nil
            storageError = "Tree storage could not be initialized."
        }

        let workspaceStore = WorkspaceStore(
            defaults: defaults,
            defaultWorkspaceName: BoardStorageBootstrapper.rootBoardName
        )
        let rootBoardID = bootstrapResult?.rootBoardID
            ?? workspaceStore.defaultWorkspace?.id
            ?? UUID()
        let treeStore = BoardTreeStore(
            rootBoardID: rootBoardID,
            availableBoardIDs: Set(workspaceStore.workspaces.map(\.id)),
            defaults: defaults
        )

        let storedSelectionID = defaults.string(forKey: BoardStorageKeys.treeSelectedBoardID)
            .flatMap(UUID.init(uuidString:))
        let directory = BoardDirectoryController(
            workspaceStore: workspaceStore,
            treeStore: treeStore,
            initialBoardID: storedSelectionID ?? rootBoardID
        )
        let storedExpandedIDs = Set(
            (defaults.stringArray(forKey: BoardStorageKeys.treeExpandedBoardIDs) ?? [])
                .compactMap(UUID.init(uuidString:))
        )

        self.workspaceStore = workspaceStore
        self.treeStore = treeStore
        self.directory = directory
        windowController = TreeBoardWindowController(workspaceStore: workspaceStore)
        navigationHistory = TreeNavigationHistory(currentBoardID: directory.currentBoardID)
        expandedBoardIDs = storedExpandedIDs
            .filter { treeStore.contains($0) }
            .union(treeStore.pathIDs(to: directory.currentBoardID))

        persistSelection(directory.currentBoardID)
        persistExpandedBoardIDs()

        directory.$currentBoardID
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] boardID in
                self?.persistSelection(boardID)
                self?.revealBoard(boardID)
                self?.reconcileNavigationHistory(currentBoardID: boardID)
            }
            .store(in: &cancellables)

        treeStore.$data
            .dropFirst()
            .sink { [weak self] _ in
                self?.reconcileExpandedBoardIDs()
                self?.reconcileNavigationHistory()
            }
            .store(in: &cancellables)
    }

    func isExpanded(_ boardID: SavedWorkspace.ID) -> Bool {
        expandedBoardIDs.contains(boardID)
    }

    func setExpanded(_ isExpanded: Bool, for boardID: SavedWorkspace.ID) {
        var updatedIDs = expandedBoardIDs
        if isExpanded {
            updatedIDs.insert(boardID)
        } else {
            updatedIDs.remove(boardID)
        }
        guard updatedIDs != expandedBoardIDs else { return }
        expandedBoardIDs = updatedIDs
        persistExpandedBoardIDs()
    }

    @discardableResult
    func selectBoard(_ boardID: SavedWorkspace.ID) -> Bool {
        guard treeStore.contains(boardID),
              workspaceStore.workspaces.contains(where: { $0.id == boardID }) else {
            operationMessage = "Board is no longer available."
            return false
        }

        var updatedHistory = navigationHistory
        updatedHistory.visit(boardID)
        navigationHistory = updatedHistory

        guard directory.openBoard(boardID) else {
            reconcileNavigationHistory()
            operationMessage = "Board is no longer available."
            return false
        }
        revealBoard(boardID)
        return true
    }

    var canNavigateBack: Bool { navigationHistory.canGoBack }
    var canNavigateForward: Bool { navigationHistory.canGoForward }

    @discardableResult
    func navigateBack() -> Bool {
        navigateHistory(goingBack: true)
    }

    @discardableResult
    func navigateForward() -> Bool {
        navigateHistory(goingBack: false)
    }

    @discardableResult
    func createBoard(name: String, under parentID: SavedWorkspace.ID) -> SavedWorkspace? {
        guard let board = directory.createBoard(name: name, under: parentID) else {
            operationMessage = "Enter a Board name."
            return nil
        }
        setExpanded(true, for: parentID)
        _ = selectBoard(board.id)
        return board
    }

    @discardableResult
    func renameBoard(_ boardID: SavedWorkspace.ID, name: String) -> Bool {
        guard directory.renameBoard(id: boardID, name: name) else {
            operationMessage = boardID == treeStore.data.rootBoardID
                ? "Root Board cannot be renamed."
                : "Enter a Board name."
            return false
        }
        return true
    }

    @discardableResult
    func deleteBoard(_ boardID: SavedWorkspace.ID) -> Bool {
        let result = directory.deleteBoard(boardID)
        guard result == .removed else {
            operationMessage = message(for: result)
            return false
        }
        reconcileExpandedBoardIDs()
        return true
    }

    @discardableResult
    func moveBoard(
        _ boardID: SavedWorkspace.ID,
        to parentID: SavedWorkspace.ID,
        at displayedIndex: Int? = nil
    ) -> Bool {
        var resolvedIndex = displayedIndex
        if let displayedIndex,
           let oldParentID = treeStore.parentID(of: boardID),
           oldParentID == parentID,
           let oldIndex = treeStore.childIDs(of: oldParentID).firstIndex(of: boardID),
           oldIndex < displayedIndex {
            resolvedIndex = displayedIndex - 1
        }

        let result = directory.moveBoard(boardID, to: parentID, at: resolvedIndex)
        guard result == .moved || result == .reordered else {
            operationMessage = message(for: result)
            return false
        }
        setExpanded(true, for: parentID)
        revealBoard(directory.currentBoardID)
        return true
    }

    func isFavorite(_ boardID: SavedWorkspace.ID) -> Bool {
        treeStore.data.favoriteBoardIDs.contains(boardID)
    }

    @discardableResult
    func addFavorite(_ boardID: SavedWorkspace.ID) -> Bool {
        let result = treeStore.addFavorite(boardID)
        guard result == .inserted else {
            operationMessage = result == .duplicate
                ? "Board is already in Favorites."
                : message(for: result)
            return false
        }
        return true
    }

    @discardableResult
    func removeFavorite(_ boardID: SavedWorkspace.ID) -> Bool {
        let result = treeStore.removeFavorite(boardID)
        guard result == .removed else {
            operationMessage = "Favorite is no longer available."
            return false
        }
        return true
    }

    @discardableResult
    func moveFavorite(_ boardID: SavedWorkspace.ID, to displayedIndex: Int) -> Bool {
        guard let oldIndex = treeStore.data.favoriteBoardIDs.firstIndex(of: boardID) else {
            operationMessage = "Favorite is no longer available."
            return false
        }
        let resolvedIndex = oldIndex < displayedIndex ? displayedIndex - 1 : displayedIndex
        let result = treeStore.moveFavorite(boardID, to: resolvedIndex)
        guard result == .reordered else {
            if result != .duplicate {
                operationMessage = message(for: result)
            }
            return false
        }
        return true
    }

    func clearOperationMessage() {
        operationMessage = nil
    }

    private func revealBoard(_ boardID: SavedWorkspace.ID) {
        let pathIDs = treeStore.pathIDs(to: boardID)
        guard !pathIDs.isEmpty else { return }
        let updatedIDs = expandedBoardIDs.union(pathIDs.dropLast())
        guard updatedIDs != expandedBoardIDs else { return }
        expandedBoardIDs = updatedIDs
        persistExpandedBoardIDs()
    }

    private func reconcileExpandedBoardIDs() {
        let validIDs = expandedBoardIDs.filter { treeStore.contains($0) }
        let requiredIDs = treeStore.pathIDs(to: directory.currentBoardID).dropLast()
        let updatedIDs = validIDs.union(requiredIDs)
        guard updatedIDs != expandedBoardIDs else { return }
        expandedBoardIDs = updatedIDs
        persistExpandedBoardIDs()
    }

    @discardableResult
    private func navigateHistory(goingBack: Bool) -> Bool {
        var updatedHistory = navigationHistory
        updatedHistory.reconcile(
            validBoardIDs: Set(workspaceStore.workspaces.map(\.id)),
            currentBoardID: directory.currentBoardID
        )
        let destinationID = goingBack
            ? updatedHistory.goBack()
            : updatedHistory.goForward()
        guard let destinationID,
              directory.openBoard(destinationID) else {
            navigationHistory = updatedHistory
            reconcileNavigationHistory()
            return false
        }

        navigationHistory = updatedHistory
        revealBoard(destinationID)
        return true
    }

    private func reconcileNavigationHistory(
        currentBoardID: SavedWorkspace.ID? = nil
    ) {
        var updatedHistory = navigationHistory
        updatedHistory.reconcile(
            validBoardIDs: Set(workspaceStore.workspaces.map(\.id)),
            currentBoardID: currentBoardID ?? directory.currentBoardID
        )
        guard updatedHistory != navigationHistory else { return }
        navigationHistory = updatedHistory
    }

    private func persistSelection(_ boardID: SavedWorkspace.ID) {
        defaults.set(boardID.uuidString, forKey: BoardStorageKeys.treeSelectedBoardID)
    }

    private func persistExpandedBoardIDs() {
        defaults.set(
            expandedBoardIDs.map(\.uuidString).sorted(),
            forKey: BoardStorageKeys.treeExpandedBoardIDs
        )
    }

    private func message(for result: BoardTreeMutationResult) -> String {
        switch result {
        case .rootImmutable:
            return "Root Board cannot be moved or deleted."
        case .selfReference:
            return "A Board cannot contain itself."
        case .cycle:
            return "That move would create a cycle."
        case .duplicate:
            return "Board is already in that position."
        case .missingBoard, .missingParent:
            return "Board is no longer available."
        case .invalidIndex:
            return "Board could not be moved to that position."
        case .inserted, .moved, .reordered, .removed:
            return "Board operation could not be completed."
        }
    }
}
