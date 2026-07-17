import Foundation

struct BoardTreeData: Codable, Equatable {
    static let currentVersion = 1

    var version: Int
    var rootBoardID: SavedWorkspace.ID
    var childBoardIDsByParentID: [SavedWorkspace.ID: [SavedWorkspace.ID]]
    var favoriteBoardIDs: [SavedWorkspace.ID]

    init(
        version: Int = currentVersion,
        rootBoardID: SavedWorkspace.ID,
        childBoardIDsByParentID: [SavedWorkspace.ID: [SavedWorkspace.ID]] = [:],
        favoriteBoardIDs: [SavedWorkspace.ID] = []
    ) {
        self.version = version
        self.rootBoardID = rootBoardID
        self.childBoardIDsByParentID = childBoardIDsByParentID
        self.favoriteBoardIDs = favoriteBoardIDs
    }
}

enum BoardTreeMutationResult: Equatable {
    case inserted
    case moved
    case reordered
    case removed
    case missingBoard
    case missingParent
    case rootImmutable
    case selfReference
    case duplicate
    case cycle
    case invalidIndex
}

@MainActor
final class BoardTreeStore: ObservableObject {
    @Published private(set) var data: BoardTreeData

    private let defaults: UserDefaults
    private let storageKey = BoardStorageKeys.tree
    private var availableBoardIDs: Set<SavedWorkspace.ID>

    init(
        rootBoardID: SavedWorkspace.ID,
        availableBoardIDs: Set<SavedWorkspace.ID>,
        defaults: UserDefaults = .standard
    ) {
        self.defaults = defaults
        self.availableBoardIDs = availableBoardIDs.union([rootBoardID])

        if let stored = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode(BoardTreeData.self, from: stored),
           decoded.version == BoardTreeData.currentVersion,
           decoded.rootBoardID == rootBoardID {
            data = decoded
        } else {
            data = BoardTreeData(rootBoardID: rootBoardID)
        }

        normalize()
        persist()
    }

    func contains(_ boardID: SavedWorkspace.ID) -> Bool {
        boardID == data.rootBoardID || parentID(of: boardID) != nil
    }

    func parentID(of boardID: SavedWorkspace.ID) -> SavedWorkspace.ID? {
        guard boardID != data.rootBoardID else { return nil }
        return orderedBoardIDs().first { parentID in
            childIDs(of: parentID).contains(boardID)
        }
    }

    func childIDs(of boardID: SavedWorkspace.ID) -> [SavedWorkspace.ID] {
        data.childBoardIDsByParentID[boardID] ?? []
    }

    func ancestorIDs(of boardID: SavedWorkspace.ID) -> [SavedWorkspace.ID] {
        guard contains(boardID) else { return [] }
        return Array(pathIDs(to: boardID).dropLast())
    }

    func descendantIDs(of boardID: SavedWorkspace.ID) -> Set<SavedWorkspace.ID> {
        guard contains(boardID) else { return [] }
        var descendants: Set<SavedWorkspace.ID> = []
        var pending = childIDs(of: boardID)

        while let current = pending.popLast() {
            guard descendants.insert(current).inserted else { continue }
            pending.append(contentsOf: childIDs(of: current))
        }
        return descendants
    }

    func pathIDs(to boardID: SavedWorkspace.ID) -> [SavedWorkspace.ID] {
        guard contains(boardID) else { return [] }
        var path = [boardID]
        var current = boardID

        while let parent = parentID(of: current) {
            path.append(parent)
            current = parent
        }
        return path.reversed()
    }

    @discardableResult
    func insertBoard(
        _ boardID: SavedWorkspace.ID,
        under parentID: SavedWorkspace.ID,
        at index: Int? = nil
    ) -> BoardTreeMutationResult {
        guard availableBoardIDs.contains(boardID) else { return .missingBoard }
        guard availableBoardIDs.contains(parentID), contains(parentID) else { return .missingParent }
        guard boardID != parentID else { return .selfReference }
        guard !contains(boardID) else { return .duplicate }

        var children = childIDs(of: parentID)
        guard let insertionIndex = insertionIndex(index, count: children.count) else { return .invalidIndex }
        children.insert(boardID, at: insertionIndex)
        data.childBoardIDsByParentID[parentID] = children
        persist()
        return .inserted
    }

    @discardableResult
    func moveBoard(
        _ boardID: SavedWorkspace.ID,
        to newParentID: SavedWorkspace.ID,
        at index: Int? = nil
    ) -> BoardTreeMutationResult {
        guard availableBoardIDs.contains(boardID), contains(boardID) else { return .missingBoard }
        guard availableBoardIDs.contains(newParentID), contains(newParentID) else { return .missingParent }
        guard boardID != data.rootBoardID else { return .rootImmutable }
        guard boardID != newParentID else { return .selfReference }
        guard !descendantIDs(of: boardID).contains(newParentID) else { return .cycle }
        guard let oldParentID = parentID(of: boardID) else { return .missingParent }

        var oldChildren = childIDs(of: oldParentID)
        guard let oldIndex = oldChildren.firstIndex(of: boardID) else { return .missingBoard }
        oldChildren.remove(at: oldIndex)

        var newChildren = oldParentID == newParentID ? oldChildren : childIDs(of: newParentID)
        guard let insertionIndex = insertionIndex(index, count: newChildren.count) else { return .invalidIndex }
        newChildren.insert(boardID, at: insertionIndex)

        if oldParentID == newParentID {
            guard newChildren != childIDs(of: oldParentID) else { return .duplicate }
            data.childBoardIDsByParentID[oldParentID] = newChildren
            persist()
            return .reordered
        }

        setChildren(oldChildren, for: oldParentID)
        data.childBoardIDsByParentID[newParentID] = newChildren
        persist()
        return .moved
    }

    @discardableResult
    func removeSubtreeReferences(rootedAt boardID: SavedWorkspace.ID) -> BoardTreeMutationResult {
        guard contains(boardID) else { return .missingBoard }
        guard boardID != data.rootBoardID else { return .rootImmutable }
        guard let parentID = parentID(of: boardID) else { return .missingParent }

        let removedIDs = descendantIDs(of: boardID).union([boardID])
        setChildren(childIDs(of: parentID).filter { $0 != boardID }, for: parentID)
        removedIDs.forEach { data.childBoardIDsByParentID[$0] = nil }
        for parentID in Array(data.childBoardIDsByParentID.keys) {
            setChildren(childIDs(of: parentID).filter { !removedIDs.contains($0) }, for: parentID)
        }
        data.favoriteBoardIDs.removeAll { removedIDs.contains($0) }
        persist()
        return .removed
    }

    @discardableResult
    func addFavorite(
        _ boardID: SavedWorkspace.ID,
        at index: Int? = nil
    ) -> BoardTreeMutationResult {
        guard availableBoardIDs.contains(boardID), contains(boardID) else { return .missingBoard }
        guard !data.favoriteBoardIDs.contains(boardID) else { return .duplicate }
        guard let insertionIndex = insertionIndex(index, count: data.favoriteBoardIDs.count) else {
            return .invalidIndex
        }
        data.favoriteBoardIDs.insert(boardID, at: insertionIndex)
        persist()
        return .inserted
    }

    @discardableResult
    func removeFavorite(_ boardID: SavedWorkspace.ID) -> BoardTreeMutationResult {
        guard let index = data.favoriteBoardIDs.firstIndex(of: boardID) else { return .missingBoard }
        data.favoriteBoardIDs.remove(at: index)
        persist()
        return .removed
    }

    @discardableResult
    func moveFavorite(
        _ boardID: SavedWorkspace.ID,
        to index: Int
    ) -> BoardTreeMutationResult {
        guard let oldIndex = data.favoriteBoardIDs.firstIndex(of: boardID) else { return .missingBoard }
        var favorites = data.favoriteBoardIDs
        favorites.remove(at: oldIndex)
        guard let insertionIndex = insertionIndex(index, count: favorites.count) else { return .invalidIndex }
        favorites.insert(boardID, at: insertionIndex)
        guard favorites != data.favoriteBoardIDs else { return .duplicate }
        data.favoriteBoardIDs = favorites
        persist()
        return .reordered
    }

    func reconcile(availableBoardIDs: Set<SavedWorkspace.ID>) {
        self.availableBoardIDs = availableBoardIDs.union([data.rootBoardID])
        normalize()
        persist()
    }

    private func normalize() {
        let sourceChildren = data.childBoardIDsByParentID
        var normalizedChildren: [SavedWorkspace.ID: [SavedWorkspace.ID]] = [:]
        var assignedBoardIDs: Set<SavedWorkspace.ID> = [data.rootBoardID]

        func visit(_ parentID: SavedWorkspace.ID, ancestors: Set<SavedWorkspace.ID>) {
            var acceptedChildren: [SavedWorkspace.ID] = []
            var seenChildren: Set<SavedWorkspace.ID> = []

            for childID in sourceChildren[parentID] ?? [] {
                guard availableBoardIDs.contains(childID),
                      childID != data.rootBoardID,
                      childID != parentID,
                      !ancestors.contains(childID),
                      seenChildren.insert(childID).inserted,
                      assignedBoardIDs.insert(childID).inserted else {
                    continue
                }
                acceptedChildren.append(childID)
                visit(childID, ancestors: ancestors.union([childID]))
            }

            if !acceptedChildren.isEmpty {
                normalizedChildren[parentID] = acceptedChildren
            }
        }

        visit(data.rootBoardID, ancestors: [data.rootBoardID])
        data.version = BoardTreeData.currentVersion
        data.childBoardIDsByParentID = normalizedChildren
        data.favoriteBoardIDs = Self.unique(
            data.favoriteBoardIDs.filter { availableBoardIDs.contains($0) && assignedBoardIDs.contains($0) }
        )
    }

    private func orderedBoardIDs() -> [SavedWorkspace.ID] {
        var result: [SavedWorkspace.ID] = []
        var pending = [data.rootBoardID]

        while !pending.isEmpty {
            let current = pending.removeFirst()
            result.append(current)
            pending.append(contentsOf: childIDs(of: current))
        }
        return result
    }

    private func insertionIndex(_ requestedIndex: Int?, count: Int) -> Int? {
        guard let requestedIndex else { return count }
        guard (0...count).contains(requestedIndex) else { return nil }
        return requestedIndex
    }

    private func setChildren(_ children: [SavedWorkspace.ID], for parentID: SavedWorkspace.ID) {
        data.childBoardIDsByParentID[parentID] = children.isEmpty ? nil : children
    }

    private func persist() {
        guard let encoded = try? JSONEncoder().encode(data) else { return }
        defaults.set(encoded, forKey: storageKey)
    }

    private static func unique(_ ids: [SavedWorkspace.ID]) -> [SavedWorkspace.ID] {
        var seen: Set<SavedWorkspace.ID> = []
        return ids.filter { seen.insert($0).inserted }
    }
}
