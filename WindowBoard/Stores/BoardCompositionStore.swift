import Foundation

struct BoardCompositionData: Codable, Equatable {
    static let currentVersion = 3

    var version: Int
    var globalRootBoardIDs: [SavedWorkspace.ID]
    var rootBoardIDsByPrimaryID: [SavedWorkspace.ID: [SavedWorkspace.ID]]
    var childBoardIDsByBoardID: [SavedWorkspace.ID: [SavedWorkspace.ID]]

    init(
        version: Int = currentVersion,
        globalRootBoardIDs: [SavedWorkspace.ID] = [],
        rootBoardIDsByPrimaryID: [SavedWorkspace.ID: [SavedWorkspace.ID]] = [:],
        childBoardIDsByBoardID: [SavedWorkspace.ID: [SavedWorkspace.ID]] = [:]
    ) {
        self.version = version
        self.globalRootBoardIDs = globalRootBoardIDs
        self.rootBoardIDsByPrimaryID = rootBoardIDsByPrimaryID
        self.childBoardIDsByBoardID = childBoardIDsByBoardID
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case globalRootBoardIDs
        case rootBoardIDsByPrimaryID
        case childBoardIDsByBoardID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        globalRootBoardIDs = try container.decodeIfPresent([SavedWorkspace.ID].self, forKey: .globalRootBoardIDs) ?? []
        rootBoardIDsByPrimaryID = try container.decodeIfPresent(
            [SavedWorkspace.ID: [SavedWorkspace.ID]].self,
            forKey: .rootBoardIDsByPrimaryID
        ) ?? [:]
        childBoardIDsByBoardID = try container.decodeIfPresent(
            [SavedWorkspace.ID: [SavedWorkspace.ID]].self,
            forKey: .childBoardIDsByBoardID
        ) ?? [:]
    }
}

enum BoardCompositionMutationResult: Equatable {
    case inserted
    case removed
    case missingBoard
    case selfReference
    case duplicate
    case cycle

    var userMessage: String {
        switch self {
        case .inserted:
            "Board added to Current Board."
        case .removed:
            "Board removed from Current Board."
        case .missingBoard:
            "Board not found."
        case .selfReference:
            "A board cannot include itself."
        case .duplicate:
            "That board is already included here."
        case .cycle:
            "That would create a circular board hierarchy."
        }
    }
}

enum BoardRootInsertion: Equatable {
    case before
    case after
}

struct BoardCompositionNode: Identifiable, Equatable {
    let id: String
    let board: SavedWorkspace
    let path: [SavedWorkspace.ID]
    let pathNames: [String]
    let children: [BoardCompositionNode]

    var pathDescription: String { path.map(\.uuidString).joined(separator: "/") }
}

struct BoardOwnedWindowReference: Equatable {
    let ownerBoardID: SavedWorkspace.ID
    let reference: SavedWindowReference
    let firstPath: [SavedWorkspace.ID]
}

struct ResolvedBoardComposition: Equatable {
    let roots: [BoardCompositionNode]
    let uniqueBoards: [SavedWorkspace]
    let uniqueWindowReferences: [BoardOwnedWindowReference]

    static let empty = ResolvedBoardComposition(roots: [], uniqueBoards: [], uniqueWindowReferences: [])
}

struct SidebarBoardSelection: Equatable {
    let memberBoardID: SavedWorkspace.ID
    let groupPrimaryID: SavedWorkspace.ID
}

enum SidebarSelection: Equatable {
    case board(SavedWorkspace.ID)
    case currentBoardGroup(primaryID: SavedWorkspace.ID)
}

struct SidebarBoardGroup: Identifiable, Equatable {
    var id: SavedWorkspace.ID { primaryBoardID }
    let primaryBoardID: SavedWorkspace.ID
    let boards: [SavedWorkspace]

    var displayTitle: String {
        boards.map(\.name).joined(separator: " / ")
    }
}

struct SidebarBoardProjection: Equatable {
    let groups: [SidebarBoardGroup]
    let standaloneBoards: [SavedWorkspace]
}

enum BoardCompositionResolver {
    static func resolve(
        primaryID: SavedWorkspace.ID,
        data: BoardCompositionData,
        workspaces: [SavedWorkspace]
    ) -> ResolvedBoardComposition {
        let workspaceByID = Dictionary(uniqueKeysWithValues: workspaces.map { ($0.id, $0) })
        guard workspaceByID[primaryID] != nil else { return .empty }

        let additionalRootIDs = BoardCompositionStore.unique(
            data.globalRootBoardIDs + (data.rootBoardIDsByPrimaryID[primaryID] ?? [])
        )
        let rootIDs = [primaryID] + additionalRootIDs.filter { $0 != primaryID }
        let roots = rootIDs.compactMap { boardID in
            makeNode(boardID: boardID, path: [], data: data, workspaceByID: workspaceByID)
        }

        var seenBoards: Set<SavedWorkspace.ID> = []
        var uniqueBoards: [SavedWorkspace] = []
        var seenReferences: Set<SavedWindowReference.ID> = []
        var uniqueReferences: [BoardOwnedWindowReference] = []

        func collect(_ node: BoardCompositionNode) {
            if seenBoards.insert(node.board.id).inserted {
                uniqueBoards.append(node.board)
            }
            for reference in node.board.windows where seenReferences.insert(reference.id).inserted {
                uniqueReferences.append(
                    BoardOwnedWindowReference(
                        ownerBoardID: node.board.id,
                        reference: reference,
                        firstPath: node.path
                    )
                )
            }
            node.children.forEach(collect)
        }
        roots.forEach(collect)

        return ResolvedBoardComposition(
            roots: roots,
            uniqueBoards: uniqueBoards,
            uniqueWindowReferences: uniqueReferences
        )
    }

    private static func makeNode(
        boardID: SavedWorkspace.ID,
        path: [SavedWorkspace.ID],
        data: BoardCompositionData,
        workspaceByID: [SavedWorkspace.ID: SavedWorkspace]
    ) -> BoardCompositionNode? {
        guard let board = workspaceByID[boardID], !path.contains(boardID) else { return nil }
        let nodePath = path + [boardID]
        let pathNames = nodePath.compactMap { workspaceByID[$0]?.name }
        let children = (data.childBoardIDsByBoardID[boardID] ?? []).compactMap { childID in
            makeNode(boardID: childID, path: nodePath, data: data, workspaceByID: workspaceByID)
        }
        return BoardCompositionNode(
            id: nodePath.map(\.uuidString).joined(separator: "/"),
            board: board,
            path: nodePath,
            pathNames: pathNames,
            children: children
        )
    }
}

final class BoardCompositionStore: ObservableObject {
    @Published private(set) var data: BoardCompositionData

    private let defaults: UserDefaults
    private let storageKey = BoardStorageKeys.legacyComposition
    private let legacyStorageKey = BoardStorageKeys.legacyIncludedBoards

    init(
        defaults: UserDefaults = .standard,
        migrationPrimaryID: SavedWorkspace.ID? = nil,
        availableBoardIDs: Set<SavedWorkspace.ID> = [],
        permanentBoardID: SavedWorkspace.ID? = nil
    ) {
        self.defaults = defaults
        var needsPermanentMigration = true
        if let stored = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode(BoardCompositionData.self, from: stored),
           (2...BoardCompositionData.currentVersion).contains(decoded.version) {
            data = decoded
            needsPermanentMigration = decoded.version < 3
            data.version = BoardCompositionData.currentVersion
        } else {
            data = BoardCompositionData()
            migrateLegacyRoots(primaryID: migrationPrimaryID, availableBoardIDs: availableBoardIDs)
        }
        if needsPermanentMigration, let permanentBoardID, availableBoardIDs.contains(permanentBoardID) {
            migratePermanentBoardToGlobalRoot(permanentBoardID)
        }
        persist()
    }

    func isGloballyIncluded(_ boardID: SavedWorkspace.ID) -> Bool {
        data.globalRootBoardIDs.contains(boardID)
    }

    @discardableResult
    func includeGlobalRoot(
        _ boardID: SavedWorkspace.ID,
        availableBoardIDs: Set<SavedWorkspace.ID>
    ) -> BoardCompositionMutationResult {
        guard availableBoardIDs.contains(boardID) else { return .missingBoard }
        guard !data.globalRootBoardIDs.contains(boardID) else { return .duplicate }
        removeExplicitReferences(to: boardID)
        data.globalRootBoardIDs.append(boardID)
        persist()
        return .inserted
    }

    @discardableResult
    func excludeGlobalRoot(_ boardID: SavedWorkspace.ID) -> BoardCompositionMutationResult {
        guard let index = data.globalRootBoardIDs.firstIndex(of: boardID) else { return .missingBoard }
        data.globalRootBoardIDs.remove(at: index)
        persist()
        return .removed
    }

    func rootBoardIDs(for primaryID: SavedWorkspace.ID) -> [SavedWorkspace.ID] {
        data.rootBoardIDsByPrimaryID[primaryID] ?? []
    }

    func displayedRootBoardIDs(for primaryID: SavedWorkspace.ID) -> [SavedWorkspace.ID] {
        Self.unique(data.globalRootBoardIDs + rootBoardIDs(for: primaryID)).filter { $0 != primaryID }
    }

    func childBoardIDs(for boardID: SavedWorkspace.ID) -> [SavedWorkspace.ID] {
        data.childBoardIDsByBoardID[boardID] ?? []
    }

    @discardableResult
    func includeRoot(
        _ boardID: SavedWorkspace.ID,
        for primaryID: SavedWorkspace.ID,
        availableBoardIDs: Set<SavedWorkspace.ID>,
        relativeTo relativeBoardID: SavedWorkspace.ID? = nil,
        insertion: BoardRootInsertion = .after
    ) -> BoardCompositionMutationResult {
        guard availableBoardIDs.contains(primaryID), availableBoardIDs.contains(boardID) else { return .missingBoard }
        guard boardID != primaryID else { return .selfReference }
        guard !isGloballyIncluded(boardID) else { return .duplicate }
        var roots = rootBoardIDs(for: primaryID)
        guard !roots.contains(boardID) else { return .duplicate }
        if let relativeBoardID {
            if let relativeIndex = roots.firstIndex(of: relativeBoardID) {
                let insertionIndex = insertion == .before ? relativeIndex : roots.index(after: relativeIndex)
                roots.insert(boardID, at: insertionIndex)
            } else if relativeBoardID == primaryID {
                roots.insert(boardID, at: 0)
            } else {
                roots.append(boardID)
            }
        } else {
            roots.append(boardID)
        }
        data.rootBoardIDsByPrimaryID[primaryID] = roots
        persist()
        return .inserted
    }

    @discardableResult
    func excludeRoot(_ boardID: SavedWorkspace.ID, for primaryID: SavedWorkspace.ID) -> BoardCompositionMutationResult {
        var roots = rootBoardIDs(for: primaryID)
        guard let index = roots.firstIndex(of: boardID) else { return .missingBoard }
        roots.remove(at: index)
        data.rootBoardIDsByPrimaryID[primaryID] = roots.isEmpty ? nil : roots
        persist()
        return .removed
    }

    @discardableResult
    func includeChild(
        _ childID: SavedWorkspace.ID,
        in parentID: SavedWorkspace.ID,
        availableBoardIDs: Set<SavedWorkspace.ID>
    ) -> BoardCompositionMutationResult {
        guard availableBoardIDs.contains(parentID), availableBoardIDs.contains(childID) else { return .missingBoard }
        guard parentID != childID else { return .selfReference }
        var children = childBoardIDs(for: parentID)
        guard !children.contains(childID) else { return .duplicate }
        guard !isReachable(parentID, from: childID) else { return .cycle }
        children.append(childID)
        data.childBoardIDsByBoardID[parentID] = children
        persist()
        return .inserted
    }

    @discardableResult
    func excludeChild(_ childID: SavedWorkspace.ID, from parentID: SavedWorkspace.ID) -> BoardCompositionMutationResult {
        var children = childBoardIDs(for: parentID)
        guard let index = children.firstIndex(of: childID) else { return .missingBoard }
        children.remove(at: index)
        data.childBoardIDsByBoardID[parentID] = children.isEmpty ? nil : children
        persist()
        return .removed
    }

    func resolveCurrentBoard(primaryID: SavedWorkspace.ID, workspaces: [SavedWorkspace]) -> ResolvedBoardComposition {
        BoardCompositionResolver.resolve(primaryID: primaryID, data: data, workspaces: workspaces)
    }

    func sidebarProjection(workspaces: [SavedWorkspace]) -> SidebarBoardProjection {
        let groups = workspaces.compactMap { workspace -> SidebarBoardGroup? in
            let resolved = resolveCurrentBoard(primaryID: workspace.id, workspaces: workspaces)
            let boards = resolved.roots
                .map(\.board)
                .filter { $0.id == workspace.id || !isGloballyIncluded($0.id) }
            guard boards.count > 1 else { return nil }
            return SidebarBoardGroup(primaryBoardID: workspace.id, boards: boards)
        }
        let groupedBoardIDs = Set(groups.flatMap { $0.boards.map(\.id) })
        let groupPrimaryIDs = Set(groups.map(\.primaryBoardID))
        let standaloneBoards = workspaces.filter { workspace in
            !groupedBoardIDs.contains(workspace.id) && !groupPrimaryIDs.contains(workspace.id)
        }
        return SidebarBoardProjection(groups: groups, standaloneBoards: standaloneBoards)
    }

    func removeBoardReferences(_ boardID: SavedWorkspace.ID) {
        data.globalRootBoardIDs.removeAll { $0 == boardID }
        data.rootBoardIDsByPrimaryID[boardID] = nil
        data.childBoardIDsByBoardID[boardID] = nil
        for primaryID in Array(data.rootBoardIDsByPrimaryID.keys) {
            data.rootBoardIDsByPrimaryID[primaryID]?.removeAll { $0 == boardID }
        }
        for parentID in Array(data.childBoardIDsByBoardID.keys) {
            data.childBoardIDsByBoardID[parentID]?.removeAll { $0 == boardID }
        }
        pruneEmptyCollections()
        persist()
    }

    func removeMissingBoards(availableBoardIDs: Set<SavedWorkspace.ID>) {
        data.globalRootBoardIDs = Self.unique(data.globalRootBoardIDs.filter(availableBoardIDs.contains))
        data.rootBoardIDsByPrimaryID = data.rootBoardIDsByPrimaryID.reduce(into: [:]) { result, entry in
            guard availableBoardIDs.contains(entry.key) else { return }
            let values = entry.value.filter(availableBoardIDs.contains)
            if !values.isEmpty { result[entry.key] = Self.unique(values) }
        }
        data.childBoardIDsByBoardID = data.childBoardIDsByBoardID.reduce(into: [:]) { result, entry in
            guard availableBoardIDs.contains(entry.key) else { return }
            let values = entry.value.filter(availableBoardIDs.contains)
            if !values.isEmpty { result[entry.key] = Self.unique(values) }
        }
        persist()
    }

    private func isReachable(_ targetID: SavedWorkspace.ID, from startID: SavedWorkspace.ID) -> Bool {
        var pending = [startID]
        var visited: Set<SavedWorkspace.ID> = []
        while let current = pending.popLast() {
            guard visited.insert(current).inserted else { continue }
            if current == targetID { return true }
            pending.append(contentsOf: childBoardIDs(for: current))
        }
        return false
    }

    private func migrateLegacyRoots(primaryID: SavedWorkspace.ID?, availableBoardIDs: Set<SavedWorkspace.ID>) {
        let legacyIDs = Self.loadLegacyIDs(from: defaults, key: legacyStorageKey).filter(availableBoardIDs.contains)
        if let primaryID, availableBoardIDs.contains(primaryID) {
            let roots = legacyIDs.filter { $0 != primaryID }
            if !roots.isEmpty { data.rootBoardIDsByPrimaryID[primaryID] = roots }
        }
        persist()
        defaults.removeObject(forKey: legacyStorageKey)
    }

    private func migratePermanentBoardToGlobalRoot(_ permanentBoardID: SavedWorkspace.ID) {
        let wasExplicitlyIncluded = data.rootBoardIDsByPrimaryID.values.contains { $0.contains(permanentBoardID) }
            || data.childBoardIDsByBoardID.values.contains { $0.contains(permanentBoardID) }
            || data.globalRootBoardIDs.contains(permanentBoardID)
        guard wasExplicitlyIncluded else { return }
        removeExplicitReferences(to: permanentBoardID)
        data.globalRootBoardIDs = Self.unique(data.globalRootBoardIDs + [permanentBoardID])
    }

    private func removeExplicitReferences(to boardID: SavedWorkspace.ID) {
        for primaryID in Array(data.rootBoardIDsByPrimaryID.keys) {
            data.rootBoardIDsByPrimaryID[primaryID]?.removeAll { $0 == boardID }
        }
        for parentID in Array(data.childBoardIDsByBoardID.keys) {
            data.childBoardIDsByBoardID[parentID]?.removeAll { $0 == boardID }
        }
        pruneEmptyCollections()
    }

    private func persist() {
        guard let encoded = try? JSONEncoder().encode(data) else { return }
        defaults.set(encoded, forKey: storageKey)
    }

    private func pruneEmptyCollections() {
        data.rootBoardIDsByPrimaryID = data.rootBoardIDsByPrimaryID.filter { !$0.value.isEmpty }
        data.childBoardIDsByBoardID = data.childBoardIDsByBoardID.filter { !$0.value.isEmpty }
    }

    static func unique(_ ids: [SavedWorkspace.ID]) -> [SavedWorkspace.ID] {
        var seen: Set<SavedWorkspace.ID> = []
        return ids.filter { seen.insert($0).inserted }
    }

    private static func loadLegacyIDs(from defaults: UserDefaults, key: String) -> [SavedWorkspace.ID] {
        unique((defaults.stringArray(forKey: key) ?? []).compactMap(UUID.init(uuidString:)))
    }
}
