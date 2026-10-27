import Foundation

struct PrototypeBoard: Identifiable, Equatable {
    let id: String
    var name: String
    let symbol: String
    var cards: [PrototypeCard]
    var isProcessing = false
}

struct PrototypeCard: Identifiable, Equatable {
    let id: String
    let application: String
    let title: String
    let symbol: String
    let tint: String
    var status: String
    var shared = false
    var saved = false
    var physicalWindowID: String? = nil
    var isProcessing = false
    var layout = PrototypeSavedLayout()

    var bundleIdentifier: String? {
        switch application {
        case "Safari": "com.apple.Safari"
        case "Xcode": "com.apple.dt.Xcode"
        case "Terminal": "com.apple.Terminal"
        case "Notes": "com.apple.Notes"
        case "Preview": "com.apple.Preview"
        case "TextEdit": "com.apple.TextEdit"
        case "Mail": "com.apple.mail"
        default: nil
        }
    }
}

struct PrototypeSavedLayout: Equatable {
    var x: Double = 120
    var y: Double = 160
    var width: Double? = 800
    var height: Double? = 600
    var offsetX: Double = 20
    var offsetY: Double = 40
}

struct PrototypeSplitGroup: Identifiable, Equatable {
    let id: String
    var memberIDs: [String]
}

enum PrototypeDisplayTarget: Equatable {
    case standalone(String)
    case group(String)
}

enum PrototypeDragKind: Equatable, Codable {
    case board(String)
    case card(ownerID: String, referenceID: String)
}

struct PrototypeDragPayload: Equatable, Codable {
    let version: Int
    let modelToken: UUID
    let sessionToken: UUID
    let revision: Int
    let kind: PrototypeDragKind
}

enum PrototypeDropTarget: Equatable {
    case board(String)
    case group(String)
    case card(boardID: String, anchorID: String, before: Bool)
    case append(String)
    case detach
}

enum PrototypeDragResult: Equatable {
    case applied
    case noChange
    case rejected(String)

    var message: String {
        switch self {
        case .applied: "変更しました（仮データのみ）。"
        case .noChange: "変更はありません。"
        case let .rejected(reason): reason
        }
    }
}

/// Pure fixture state. No AX service, UserDefaults or production session is constructed.
struct PrototypeBoardDragModel {
    private(set) var boards: [PrototypeBoard]
    private(set) var groups: [PrototypeSplitGroup]
    private(set) var selectedTarget: PrototypeDisplayTarget
    private(set) var revision = 0
    private(set) var saveCount = 0
    var failNextSave = false
    private let modelToken = UUID()
    private var activePayloads: [UUID: PrototypeDragPayload] = [:]
    private var boardMutationRevisions: [String: Int] = [:]

    init(boards: [PrototypeBoard] = PrototypeBoard.samples,
         groups: [PrototypeSplitGroup] = [.init(id: "work-reference", memberIDs: ["work", "reference"])],
         selectedTarget: PrototypeDisplayTarget = .group("work-reference")) {
        self.boards = boards
        self.groups = groups
        self.selectedTarget = selectedTarget
    }

    var displayedBoards: [PrototypeBoard] {
        switch selectedTarget {
        case let .standalone(id): boards.filter { $0.id == id }
        case let .group(id): groups.first { $0.id == id }?.memberIDs.compactMap { member in boards.first { $0.id == member } } ?? []
        }
    }
    var displayTitle: String { displayedBoards.map(\.name).joined(separator: " + ") }
    func group(containing boardID: String) -> PrototypeSplitGroup? { groups.first { $0.memberIDs.contains(boardID) } }

    mutating func select(boardID: String) {
        guard boards.contains(where: { $0.id == boardID }) else { return }
        selectedTarget = group(containing: boardID).map { .group($0.id) } ?? .standalone(boardID)
    }

    mutating func beginDrag(kind: PrototypeDragKind) -> PrototypeDragPayload? {
        guard sourceError(kind) == nil else { return nil }
        let payload = PrototypeDragPayload(version: 1, modelToken: modelToken, sessionToken: UUID(), revision: revision, kind: kind)
        activePayloads[payload.sessionToken] = payload
        return payload
    }

    mutating func endDrag() { activePayloads.removeAll() }

    mutating func cancelDrag(_ payload: PrototypeDragPayload) { activePayloads.removeValue(forKey: payload.sessionToken) }

    func validate(_ payload: PrototypeDragPayload, to target: PrototypeDropTarget) -> PrototypeDragResult {
        var candidate = self
        return candidate.apply(payload, to: target, save: false)
    }

    mutating func commit(_ payload: PrototypeDragPayload, to target: PrototypeDropTarget) -> PrototypeDragResult {
        apply(payload, to: target, save: true)
    }

    private mutating func apply(_ payload: PrototypeDragPayload, to target: PrototypeDropTarget, save: Bool) -> PrototypeDragResult {
        guard payload.version == 1, payload.modelToken == modelToken,
              activePayloads[payload.sessionToken] == payload else { return .rejected("無効または終了済みのドラッグです。") }
        guard payload.revision <= revision,
              involvedBoardIDs(payload.kind, target: target).allSatisfy({ (boardMutationRevisions[$0] ?? 0) <= payload.revision }) else { return .rejected("ドラッグ中に関連データが更新されました。") }
        if let error = sourceError(payload.kind) { return .rejected(error) }
        var candidate = self
        let result: PrototypeDragResult
        switch payload.kind {
        case let .board(id): result = candidate.moveBoard(id, to: target)
        case let .card(owner, reference): result = candidate.moveCard(reference, ownerID: owner, to: target)
        }
        guard result == .applied else {
            if save { activePayloads.removeValue(forKey: payload.sessionToken) }
            return result
        }
        guard candidate.invariantsHold else { return .rejected("構成を検証できませんでした。") }
        guard save else { return .applied }
        activePayloads.removeValue(forKey: payload.sessionToken)
        if failNextSave { failNextSave = false; return .rejected("仮保存に失敗しました。変更は行いません。") }
        candidate.activePayloads = activePayloads
        candidate.recordMutation(comparedTo: self)
        candidate.saveCount += 1
        self = candidate
        return .applied
    }

    private func sourceError(_ kind: PrototypeDragKind) -> String? {
        let ownerID: String
        switch kind {
        case let .board(id): ownerID = id
        case let .card(owner, _): ownerID = owner
        }
        guard let board = boards.first(where: { $0.id == ownerID }) else { return "元Boardが存在しません。" }
        guard !board.isProcessing else { return "Boardを処理中です。" }
        if case let .card(_, reference) = kind {
            guard let card = board.cards.first(where: { $0.id == reference }) else { return "元カードが存在しません。" }
            if card.isProcessing || ["Resolving", "Reconnecting", "Removing"].contains(card.status) { return "カードを処理中です。" }
            if let physicalID = card.physicalWindowID,
               boards.flatMap(\.cards).contains(where: { $0.physicalWindowID == physicalID && ($0.isProcessing || ["Resolving", "Reconnecting", "Removing"].contains($0.status)) }) {
                return "共有ウィンドウを処理中です。"
            }
        }
        return nil
    }

    private mutating func moveBoard(_ id: String, to target: PrototypeDropTarget) -> PrototypeDragResult {
        let destinationID: String
        switch target {
        case let .board(boardID): destinationID = boardID
        case let .group(groupID):
            guard let first = groups.first(where: { $0.id == groupID })?.memberIDs.first else { return .rejected("追加先が存在しません。") }
            destinationID = first
        default: return .rejected("Boardはサイドバーへドロップしてください。")
        }
        guard let destination = boards.first(where: { $0.id == destinationID }) else { return .rejected("追加先Boardが存在しません。") }
        guard !destination.isProcessing else { return .rejected("追加先Boardを処理中です。") }
        let sourceGroup = group(containing: id)
        let destinationGroup = group(containing: destinationID)
        if id == destinationID || (sourceGroup != nil && sourceGroup?.id == destinationGroup?.id) { return .noChange }
        let destinationMembers = destinationGroup?.memberIDs ?? [destinationID]
        guard destinationMembers.count < 4 else { return .rejected("並列グループは最大4Boardです。") }
        let involved = Set((sourceGroup?.memberIDs ?? [id]) + destinationMembers)
        guard !boards.contains(where: { involved.contains($0.id) && $0.isProcessing }) else { return .rejected("関連Boardを処理中です。") }
        if let sourceGroup, let index = groups.firstIndex(where: { $0.id == sourceGroup.id }) {
            groups[index].memberIDs.removeAll { $0 == id }
            if groups[index].memberIDs.count < 2 { groups.remove(at: index) }
        }
        let newGroupID: String
        if let destinationGroup, let index = groups.firstIndex(where: { $0.id == destinationGroup.id }) {
            groups[index].memberIDs.append(id)
            newGroupID = destinationGroup.id
        } else {
            newGroupID = UUID().uuidString
            groups.append(.init(id: newGroupID, memberIDs: [destinationID, id]))
        }
        if selectedTarget == .standalone(id) || selectedTarget == .standalone(destinationID) {
            selectedTarget = .group(newGroupID)
        } else if let sourceGroup, selectedTarget == .group(sourceGroup.id), group(containing: id)?.id != sourceGroup.id {
            if !groups.contains(where: { $0.id == sourceGroup.id }), let survivor = sourceGroup.memberIDs.first(where: { $0 != id }) {
                selectedTarget = .standalone(survivor)
            }
        }
        return .applied
    }

    private mutating func moveCard(_ reference: String, ownerID: String, to target: PrototypeDropTarget) -> PrototypeDragResult {
        guard let sourceIndex = boards.firstIndex(where: { $0.id == ownerID }),
              let cardIndex = boards[sourceIndex].cards.firstIndex(where: { $0.id == reference }) else { return .rejected("元カードが存在しません。") }
        if target == .detach { boards[sourceIndex].cards.remove(at: cardIndex); return .applied }
        let destinationID: String
        var anchor: (String, Bool)?
        switch target {
        case let .board(id), let .append(id): destinationID = id
        case let .card(boardID, anchorID, before): destinationID = boardID; anchor = (anchorID, before)
        default: return .rejected("カードの追加先Boardを指定してください。")
        }
        guard let destinationIndex = boards.firstIndex(where: { $0.id == destinationID }) else { return .rejected("追加先Boardが存在しません。") }
        guard !boards[destinationIndex].isProcessing else { return .rejected("追加先Boardを処理中です。") }
        if sourceIndex == destinationIndex {
            if case .board = target { return .noChange }
            if anchor?.0 == reference { return .noChange }
        }
        let card = boards[sourceIndex].cards[cardIndex]
        if sourceIndex != destinationIndex, boards[destinationIndex].cards.contains(where: { $0.id == card.id || (card.physicalWindowID != nil && $0.physicalWindowID == card.physicalWindowID) }) {
            return .rejected("追加先に同じウィンドウがあります。")
        }
        let oldCards = boards[sourceIndex].cards
        boards[sourceIndex].cards.remove(at: cardIndex)
        let insertionIndex: Int
        if let anchor {
            guard let index = boards[destinationIndex].cards.firstIndex(where: { $0.id == anchor.0 }) else { return .rejected("挿入先カードが更新されました。") }
            guard !boards[destinationIndex].cards[index].isProcessing,
                  !["Resolving", "Reconnecting", "Removing"].contains(boards[destinationIndex].cards[index].status) else { return .rejected("挿入先カードを処理中です。") }
            insertionIndex = index + (anchor.1 ? 0 : 1)
        } else { insertionIndex = boards[destinationIndex].cards.count }
        boards[destinationIndex].cards.insert(card, at: insertionIndex)
        return sourceIndex == destinationIndex && oldCards == boards[sourceIndex].cards ? .noChange : .applied
    }

    mutating func separate(boardID: String) -> PrototypeDragResult {
        guard let oldGroup = group(containing: boardID), let index = groups.firstIndex(where: { $0.id == oldGroup.id }) else { return .noChange }
        guard !boards.contains(where: { oldGroup.memberIDs.contains($0.id) && $0.isProcessing }) else { return .rejected("関連Boardを処理中です。") }
        var candidate = self
        candidate.groups[index].memberIDs.removeAll { $0 == boardID }
        let survivors = candidate.groups[index].memberIDs
        if survivors.count < 2 { candidate.groups.remove(at: index) }
        if selectedTarget == .group(oldGroup.id), survivors.count == 1 { candidate.selectedTarget = .standalone(survivors[0]) }
        return publish(candidate)
    }

    @discardableResult
    mutating func createBoard(name: String) -> PrototypeDragResult {
        var candidate = self
        let id = UUID().uuidString
        candidate.boards.append(.init(id: id, name: name, symbol: "rectangle", cards: []))
        candidate.selectedTarget = .standalone(id)
        return publish(candidate)
    }

    mutating func addCard(to boardID: String) -> PrototypeDragResult {
        guard let index = boards.firstIndex(where: { $0.id == boardID }), !boards[index].isProcessing else { return .rejected("追加先Boardを確認できません。") }
        var candidate = self
        candidate.boards[index].cards.append(.init(id: UUID().uuidString, application: "Demo App", title: "追加した仮ウィンドウ", symbol: "macwindow", tint: "indigo", status: "Available"))
        return publish(candidate)
    }

    mutating func saveLayout(boardID: String, referenceID: String? = nil) -> PrototypeDragResult {
        guard let index = boards.firstIndex(where: { $0.id == boardID }) else { return .rejected("Boardが存在しません。") }
        guard !boards[index].isProcessing else { return .rejected("Boardを処理中です。") }
        let affectedCards = boards[index].cards.filter { referenceID == nil || $0.id == referenceID }
        guard !affectedCards.contains(where: { $0.isProcessing || ["Resolving", "Reconnecting", "Removing"].contains($0.status) }) else { return .rejected("カードを処理中です。") }
        var candidate = self
        if let referenceID {
            guard let cardIndex = candidate.boards[index].cards.firstIndex(where: { $0.id == referenceID }) else { return .rejected("カードが存在しません。") }
            candidate.boards[index].cards[cardIndex].saved = true
        } else {
            for cardIndex in candidate.boards[index].cards.indices { candidate.boards[index].cards[cardIndex].saved = true }
        }
        return publish(candidate)
    }

    mutating func removeAll(boardID: String) -> PrototypeDragResult { removeAllCards(from: boardID) }

    mutating func removeAllCards(from boardID: String) -> PrototypeDragResult {
        guard let index = boards.firstIndex(where: { $0.id == boardID }) else { return .rejected("Boardが存在しません。") }
        guard !boards[index].isProcessing,
              !boards[index].cards.contains(where: { $0.isProcessing || ["Resolving", "Reconnecting", "Removing"].contains($0.status) }) else { return .rejected("Boardまたはカードを処理中です。") }
        guard !boards[index].cards.isEmpty else { return .noChange }
        var candidate = self
        candidate.boards[index].cards.removeAll()
        return publish(candidate)
    }

    private mutating func publish(_ candidate: Self) -> PrototypeDragResult {
        guard candidate.invariantsHold else { return .rejected("構成を検証できませんでした。") }
        if failNextSave { failNextSave = false; return .rejected("仮保存に失敗しました。") }
        var next = candidate
        next.recordMutation(comparedTo: self)
        next.saveCount += 1
        self = next
        return .applied
    }

    private func involvedBoardIDs(_ kind: PrototypeDragKind, target: PrototypeDropTarget) -> Set<String> {
        var ids = Set<String>()
        let sourceID: String
        switch kind {
        case let .board(id):
            sourceID = id
            ids.formUnion(group(containing: id)?.memberIDs ?? [id])
        case let .card(ownerID, _): sourceID = ownerID; ids.insert(ownerID)
        }
        ids.insert(sourceID)
        let destinationID: String?
        switch target {
        case let .board(id), let .append(id), let .card(id, _, _): destinationID = id
        case let .group(id):
            ids.formUnion(groups.first(where: { $0.id == id })?.memberIDs ?? [])
            destinationID = nil
        case .detach: destinationID = nil
        }
        if let destinationID {
            ids.insert(destinationID)
            if case .board = kind { ids.formUnion(group(containing: destinationID)?.memberIDs ?? []) }
        }
        return ids
    }

    private mutating func recordMutation(comparedTo old: Self) {
        revision = old.revision + 1
        let allIDs = Set(boards.map(\.id) + old.boards.map(\.id))
        for id in allIDs {
            let oldBoard = old.boards.first { $0.id == id }
            let newBoard = boards.first { $0.id == id }
            if oldBoard != newBoard || old.group(containing: id) != group(containing: id) {
                boardMutationRevisions[id] = revision
            }
        }
    }

    private var invariantsHold: Bool {
        let boardIDs = Set(boards.map(\.id))
        guard boardIDs.count == boards.count, Set(groups.map(\.id)).count == groups.count else { return false }
        var assigned = Set<String>()
        for group in groups {
            guard (2...4).contains(group.memberIDs.count), Set(group.memberIDs).count == group.memberIDs.count else { return false }
            for id in group.memberIDs { guard boardIDs.contains(id), assigned.insert(id).inserted else { return false } }
        }
        for board in boards { guard Set(board.cards.map(\.id)).count == board.cards.count else { return false } }
        switch selectedTarget {
        case let .standalone(id): return boardIDs.contains(id) && !assigned.contains(id)
        case let .group(id): return groups.contains { $0.id == id }
        }
    }
}

extension PrototypeBoard {
    static var samples: [PrototypeBoard] {
        [PrototypeBoard(id: "work", name: "作業", symbol: "hammer", cards: [
            PrototypeCard(id: "editor", application: "Xcode", title: "WindowBoard — ContentView.swift", symbol: "hammer.fill", tint: "blue", status: "Available"),
            PrototypeCard(id: "shared-work", application: "Safari", title: "SwiftUI Documentation", symbol: "safari", tint: "cyan", status: "Available", shared: true, physicalWindowID: "safari-docs"),
            PrototypeCard(id: "terminal", application: "Terminal", title: "Build output", symbol: "terminal", tint: "gray", status: "Minimized"),
            PrototypeCard(id: "notes", application: "Notes", title: "UI review checklist", symbol: "note.text", tint: "orange", status: "Available"),
            PrototypeCard(id: "design", application: "Preview", title: "Layout sketch.pdf", symbol: "doc.richtext", tint: "purple", status: "Unavailable")
        ]), PrototypeBoard(id: "reference", name: "資料", symbol: "books.vertical", cards: [
            PrototypeCard(id: "shared-reference", application: "Safari", title: "SwiftUI Documentation", symbol: "safari", tint: "cyan", status: "Available", shared: true, physicalWindowID: "safari-docs"),
            PrototypeCard(id: "requirements", application: "TextEdit", title: "APP_REQUIREMENTS.md", symbol: "doc.text", tint: "purple", status: "Available"),
            PrototypeCard(id: "reference-pdf", application: "Preview", title: "macOS UI Guidelines.pdf", symbol: "doc.richtext", tint: "orange", status: "Available"),
            PrototypeCard(id: "mail", application: "Mail", title: "Review feedback", symbol: "envelope", tint: "blue", status: "Minimized")
        ]), PrototypeBoard(id: "personal", name: "個人", symbol: "person", cards: [
            PrototypeCard(id: "personal-notes", application: "Notes", title: "週末のメモ", symbol: "note.text", tint: "orange", status: "Available"),
            PrototypeCard(id: "personal-browser", application: "Safari", title: "読みたい記事", symbol: "safari", tint: "cyan", status: "Available")
        ])]
    }
}
