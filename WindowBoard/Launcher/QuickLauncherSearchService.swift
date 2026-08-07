import CoreFoundation
import Foundation

struct QuickLauncherCategoryLimits: Equatable {
    var boards = 5
    var windows = 5
    var actions = 5

    func limit(for kind: QuickLauncherItemKind) -> Int {
        switch kind {
        case .board: boards
        case .window: windows
        case .action: actions
        }
    }
}

struct QuickLauncherSearchService {
    private static let japaneseLocale = CFLocaleCreate(
        kCFAllocatorDefault,
        CFLocaleIdentifier("ja_JP" as CFString)
    )
    enum Scope: Equatable {
        case all
        case boards
        case windows
        case actions
    }

    struct ParsedQuery: Equatable {
        let text: String
        let scope: Scope
    }

    private struct RankedItem {
        let item: QuickLauncherItem
        let matchTier: Int
        let matchScore: Int
        let usage: QuickLauncherUsage?
    }

    func search(
        items: [QuickLauncherItem],
        query: String,
        usage: QuickLauncherUsageProviding = EmptyQuickLauncherUsage(),
        limits: QuickLauncherCategoryLimits = QuickLauncherCategoryLimits()
    ) -> [QuickLauncherItem] {
        let parsedQuery = parse(query)
        let normalizedQuery = normalize(parsedQuery.text).trimmingCharacters(in: .whitespacesAndNewlines)
        let queryTokens = normalizedQuery.split(whereSeparator: \.isWhitespace).map(String.init)

        let ranked = items.compactMap { item -> RankedItem? in
            guard includes(item, in: parsedQuery.scope) else { return nil }
            let match = match(tokens: queryTokens, fields: searchFields(for: item))
            guard queryTokens.isEmpty || match != nil else { return nil }
            return RankedItem(
                item: item,
                matchTier: match?.tier ?? 0,
                matchScore: match?.score ?? 0,
                usage: usage.usage(for: item.id)
            )
        }
        .sorted { lhs, rhs in
            compare(lhs, rhs, hasQuery: !queryTokens.isEmpty)
        }

        return QuickLauncherItemKind.allCases.flatMap { kind in
            ranked.lazy
                .filter { $0.item.kind == kind }
                .prefix(limits.limit(for: kind))
                .map(\.item)
        }
    }

    func parse(_ query: String) -> ParsedQuery {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return ParsedQuery(text: "", scope: .all) }
        let text = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
        return switch first {
        case ">": ParsedQuery(text: text, scope: .actions)
        case "@": ParsedQuery(text: text, scope: .windows)
        case "#": ParsedQuery(text: text, scope: .boards)
        default: ParsedQuery(text: trimmed, scope: .all)
        }
    }

    private func includes(_ item: QuickLauncherItem, in scope: Scope) -> Bool {
        switch scope {
        case .all: true
        case .boards: item.kind == .board
        case .windows: item.kind == .window
        case .actions: item.kind == .action
        }
    }

    private func searchFields(for item: QuickLauncherItem) -> [String] {
        let fields = item.searchableText
        return fields + fields.flatMap(japaneseReadingVariants)
    }

    private func compare(_ lhs: RankedItem, _ rhs: RankedItem, hasQuery: Bool) -> Bool {
        if hasQuery, lhs.matchTier != rhs.matchTier { return lhs.matchTier > rhs.matchTier }
        if hasQuery, lhs.matchScore != rhs.matchScore { return lhs.matchScore > rhs.matchScore }

        let lhsDate = lhs.usage?.lastUsedAt ?? .distantPast
        let rhsDate = rhs.usage?.lastUsedAt ?? .distantPast
        if lhsDate != rhsDate { return lhsDate > rhsDate }

        let lhsCount = lhs.usage?.useCount ?? 0
        let rhsCount = rhs.usage?.useCount ?? 0
        if lhsCount != rhsCount { return lhsCount > rhsCount }
        if lhs.item.isCurrentBoardRelated != rhs.item.isCurrentBoardRelated {
            return lhs.item.isCurrentBoardRelated
        }
        if lhs.item.isSelectedBoardRelated != rhs.item.isSelectedBoardRelated {
            return lhs.item.isSelectedBoardRelated
        }
        if lhs.item.fallbackOrder != rhs.item.fallbackOrder {
            return lhs.item.fallbackOrder < rhs.item.fallbackOrder
        }
        if lhs.item.kind != rhs.item.kind {
            return kindOrder(lhs.item.kind) < kindOrder(rhs.item.kind)
        }
        let lhsTitle = normalize(lhs.item.title)
        let rhsTitle = normalize(rhs.item.title)
        if lhsTitle != rhsTitle { return lhsTitle < rhsTitle }
        return lhs.item.id < rhs.item.id
    }

    private func kindOrder(_ kind: QuickLauncherItemKind) -> Int {
        switch kind {
        case .board: 0
        case .window: 1
        case .action: 2
        }
    }

    private func match(tokens: [String], fields: [String]) -> (tier: Int, score: Int)? {
        guard !tokens.isEmpty else { return (0, 0) }
        let normalizedFields = fields.flatMap(normalizedVariants)
        var weakestTier = Int.max
        var totalScore = 0

        for token in tokens {
            let tokenVariants = normalizedVariants(token)
            var matches: [(tier: Int, score: Int)] = []
            for field in normalizedFields {
                for tokenVariant in tokenVariants {
                    if let match = match(token: tokenVariant, field: field) {
                        matches.append(match)
                    }
                }
            }
            guard let best = matches.max(by: { lhs, rhs in
                lhs.tier == rhs.tier ? lhs.score < rhs.score : lhs.tier < rhs.tier
            }) else {
                return nil
            }
            weakestTier = min(weakestTier, best.tier)
            totalScore += best.score
        }
        return (weakestTier, totalScore)
    }

    private func match(token: String, field: String) -> (tier: Int, score: Int)? {
        guard !token.isEmpty else { return nil }
        if field == token { return (4, 4_000) }
        if field.hasPrefix(token) { return (3, 3_000 - max(0, field.count - token.count)) }
        if let range = field.range(of: token) {
            return (2, 2_000 - field.distance(from: field.startIndex, to: range.lowerBound))
        }

        if token.count >= 4,
           let closestDistance = field
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .map({ editDistance(token, $0) })
            .min(),
           closestDistance <= (token.count >= 7 ? 2 : 1) {
            return (1, 850 - closestDistance * 100)
        }

        var searchIndex = field.startIndex
        var firstOffset: Int?
        var lastOffset = 0
        for character in token {
            guard let found = field[searchIndex...].firstIndex(of: character) else { return nil }
            let offset = field.distance(from: field.startIndex, to: found)
            firstOffset = firstOffset ?? offset
            lastOffset = offset
            searchIndex = field.index(after: found)
        }
        let spread = lastOffset - (firstOffset ?? 0)
        return (1, 1_000 - spread - (firstOffset ?? 0))
    }

    private func normalize(_ value: String) -> String {
        let folded = value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
        return folded.applyingTransform(.hiraganaToKatakana, reverse: false) ?? folded
    }

    private func normalizedVariants(_ value: String) -> [String] {
        let normalized = normalize(value)
        let latin = normalized
            .applyingTransform(.toLatin, reverse: false)
            .map(normalize)
        return Array(Set([normalized, latin].compactMap { $0 }))
    }

    private func japaneseReadingVariants(_ value: String) -> [String] {
        guard value.unicodeScalars.contains(where: { (0x4E00...0x9FFF).contains($0.value) }),
              let locale = Self.japaneseLocale else {
            return []
        }
        let tokenizer = CFStringTokenizerCreate(
            kCFAllocatorDefault,
            value as CFString,
            CFRangeMake(0, value.utf16.count),
            kCFStringTokenizerUnitWord,
            locale
        )
        guard let tokenizer else { return [] }

        var readings: [String] = []
        while CFStringTokenizerAdvanceToNextToken(tokenizer).rawValue != 0 {
            guard let reading = CFStringTokenizerCopyCurrentTokenAttribute(
                tokenizer,
                kCFStringTokenizerAttributeLatinTranscription
            ) as? String,
            !reading.isEmpty else {
                continue
            }
            readings.append(reading)
        }
        let combined = readings.joined()
        return combined.isEmpty ? [] : [combined]
    }

    private func editDistance(_ lhs: String, _ rhs: String) -> Int {
        let left = Array(lhs)
        let right = Array(rhs)
        guard !left.isEmpty else { return right.count }
        guard !right.isEmpty else { return left.count }
        var previous = Array(0...right.count)
        for (leftIndex, leftCharacter) in left.enumerated() {
            var current = [leftIndex + 1]
            for (rightIndex, rightCharacter) in right.enumerated() {
                current.append(min(
                    previous[rightIndex + 1] + 1,
                    current[rightIndex] + 1,
                    previous[rightIndex] + (leftCharacter == rightCharacter ? 0 : 1)
                ))
            }
            previous = current
        }
        return previous[right.count]
    }
}
