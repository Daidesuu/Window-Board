import XCTest
@testable import WindowBoard

@MainActor
final class QuickLauncherTests: XCTestCase {
    func testSearchRanksExactPrefixSubstringAndFuzzyMatches() {
        let items = [
            item(id: "fuzzy", title: "My Board", keywords: ["weekend organizer report kit"]),
            item(id: "substring", title: "Workbench Board"),
            item(id: "prefix", title: "Work Notes"),
            item(id: "exact", title: "Work")
        ]

        let results = QuickLauncherSearchService().search(items: items, query: "work")

        XCTAssertEqual(results.map(\.id), ["exact", "prefix", "substring", "fuzzy"])
    }

    func testSearchIgnoresCaseWidthAndDiacritics() {
        let items = [item(id: "cafe", title: "Ｃafé Board")]

        XCTAssertEqual(
            QuickLauncherSearchService().search(items: items, query: "cafe").map(\.id),
            ["cafe"]
        )
    }

    func testSearchMatchesJapaneseBoardNamePrefix() {
        let results = QuickLauncherSearchService().search(
            items: [item(id: "vibe", title: "バイブコーディング")],
            query: "バイブ"
        )

        XCTAssertEqual(results.map(\.id), ["vibe"])
    }

    func testSearchTreatsHiraganaAndKatakanaAsEquivalent() {
        let results = QuickLauncherSearchService().search(
            items: [item(id: "vibe", title: "バイブコーディング")],
            query: "ばいぶ"
        )

        XCTAssertEqual(results.map(\.id), ["vibe"])
    }

    func testSearchFindsJapaneseKanjiByItsReadingPrefix() {
        let results = QuickLauncherSearchService().search(
            items: [item(id: "class", title: "授業")],
            query: "じゅ"
        )

        XCTAssertEqual(results.map(\.id), ["class"])
    }

    func testSearchUsesBoardAliasesAndScopes() {
        let board = item(id: "board", title: "バイブコーディング", keywords: ["vibe", "ai development"])
        let window = item(id: "window", title: "vibe-notes.md", kind: .window)
        let action = item(id: "action", title: "Restore Layout", kind: .action)
        let service = QuickLauncherSearchService()

        XCTAssertEqual(service.search(items: [board], query: "vibe").map(\.id), ["board"])
        XCTAssertEqual(service.search(items: [board, window, action], query: "@ vibe").map(\.id), ["window"])
        XCTAssertEqual(service.search(items: [board, window, action], query: "> restore").map(\.id), ["action"])
        XCTAssertEqual(service.search(items: [board, window, action], query: "# ai").map(\.id), ["board"])
    }

    func testSearchAcceptsOneCharacterTypoInLongWord() {
        let results = QuickLauncherSearchService().search(
            items: [item(id: "spotlight", title: "Spotlight Search")],
            query: "spotlght"
        )

        XCTAssertEqual(results.map(\.id), ["spotlight"])
    }

    func testUpdatingQueryImmediatelyFiltersResults() {
        let model = makeViewModel()
        model.present(items: [
            item(id: "vibe", title: "バイブコーディング"),
            item(id: "other", title: "別のBoard")
        ])

        model.updateQuery("バイブ")

        XCTAssertEqual(model.results.map(\.id), ["vibe"])
    }

    func testCurrentBoardTitleIsIndependentFromKeyboardSelection() {
        let model = makeViewModel()
        let currentBoard = QuickLauncherItem(
            id: "current",
            kind: .board,
            title: "Current Board",
            icon: .system("square"),
            target: .action(.showWindow),
            isSelectedBoardRelated: true
        )
        let otherBoard = item(id: "other", title: "Other Board")

        model.present(items: [currentBoard, otherBoard])
        model.select(otherBoard.id)

        XCTAssertEqual(model.currentBoardTitle, "Current Board")
    }

    func testUpdatingQuerySelectsTheTopRankedResult() {
        let model = makeViewModel()
        let first = item(id: "first", title: "バイブ")
        let second = item(id: "second", title: "バイブコーディング")
        model.present(items: [second, first])
        model.select(second.id)

        model.updateQuery("ばいぶ")

        XCTAssertEqual(model.results.first?.id, first.id)
        XCTAssertEqual(model.selectedItemID, first.id)
    }

    func testSearchUsesAppWindowAndOwningBoardKeywords() {
        let item = item(
            id: "window",
            title: "Draft.md",
            subtitle: "Visual Studio Code · Research Board",
            keywords: ["VS Code", "Research Board"]
        )

        XCTAssertEqual(QuickLauncherSearchService().search(items: [item], query: "research").count, 1)
        XCTAssertEqual(QuickLauncherSearchService().search(items: [item], query: "code").count, 1)
    }

    func testSearchAppliesPerCategoryLimits() {
        let boards = (0..<7).map { item(id: "board-\($0)", title: "Board \($0)", kind: .board) }
        let actions = (0..<7).map { item(id: "action-\($0)", title: "Action \($0)", kind: .action) }

        let results = QuickLauncherSearchService().search(
            items: boards + actions,
            query: "",
            limits: QuickLauncherCategoryLimits(boards: 2, windows: 2, actions: 3)
        )

        XCTAssertEqual(results.filter { $0.kind == .board }.count, 2)
        XCTAssertEqual(results.filter { $0.kind == .action }.count, 3)
    }

    func testSelectionStartsAtFirstEnabledItemAndStopsAtBoundaries() {
        let model = makeViewModel()
        model.present(items: [
            item(id: "disabled", title: "Disabled", isEnabled: false),
            item(id: "first", title: "First"),
            item(id: "second", title: "Second")
        ])

        XCTAssertEqual(model.selectedItemID, "first")
        model.moveSelection(by: -1)
        XCTAssertEqual(model.selectedItemID, "first")
        model.moveSelection(by: 1)
        XCTAssertEqual(model.selectedItemID, "second")
        model.moveSelection(by: 1)
        XCTAssertEqual(model.selectedItemID, "second")
    }

    func testOnlyKeyboardSelectionRequestsAutomaticScrolling() {
        let model = makeViewModel()
        let first = item(id: "first", title: "First")
        let second = item(id: "second", title: "Second")
        model.present(items: [first, second])
        let initialRevision = model.keyboardSelectionScrollRevision

        model.select(second.id)
        XCTAssertEqual(model.keyboardSelectionScrollRevision, initialRevision)

        model.moveSelection(by: -1)
        XCTAssertGreaterThan(model.keyboardSelectionScrollRevision, initialRevision)
    }

    func testPresentRequestsSearchFocusEveryTime() {
        let model = makeViewModel()
        let initialRevision = model.focusRequestRevision

        model.present(items: [item(id: "first", title: "First")])
        let firstRevision = model.focusRequestRevision
        model.dismiss()
        model.present(items: [item(id: "second", title: "Second")])

        XCTAssertGreaterThan(firstRevision, initialRevision)
        XCTAssertGreaterThan(model.focusRequestRevision, firstRevision)
    }

    func testResultRefreshPreservesSelectionAndRepairsRemovedSelection() {
        let model = makeViewModel()
        let first = item(id: "first", title: "First")
        let second = item(id: "second", title: "Second")
        model.present(items: [first, second])
        model.select(second.id)

        model.updateItems([second, first])
        XCTAssertEqual(model.selectedItemID, second.id)

        model.updateItems([first])
        XCTAssertEqual(model.selectedItemID, first.id)
    }

    func testExecuteDoesNothingWithoutEnabledSelectionAndExecutesOnceOtherwise() {
        var executions: [QuickLauncherTarget] = []
        let model = makeViewModel { executions.append($0) }
        model.present(items: [item(id: "disabled", title: "Disabled", isEnabled: false)])
        model.executeSelected()
        XCTAssertTrue(executions.isEmpty)

        let enabled = item(id: "enabled", title: "Enabled")
        model.updateItems([enabled])
        model.executeSelected()
        model.executeSelected()
        XCTAssertEqual(executions, [enabled.target])
        XCTAssertFalse(model.isVisible)
    }

    func testSecondaryActionExecutesItsOwnTarget() {
        var executions: [QuickLauncherTarget] = []
        let model = makeViewModel { executions.append($0) }
        let windowID = UUID()
        let detachTarget = QuickLauncherTarget.window(
            windowReferenceID: windowID,
            ownerBoardID: UUID(),
            action: .detachFromBoard
        )
        let window = QuickLauncherItem(
            id: "window",
            kind: .window,
            title: "Draft",
            icon: .system("square"),
            target: .window(windowReferenceID: windowID, ownerBoardID: UUID(), action: .bringForward),
            secondaryAction: QuickLauncherSecondaryAction(
                title: "Detach",
                systemImage: "rectangle.portrait.and.arrow.right",
                target: detachTarget
            )
        )

        model.present(items: [window])
        model.execute(window, target: detachTarget)

        XCTAssertEqual(executions, [detachTarget])
        XCTAssertFalse(model.isVisible)
    }

    private func makeViewModel(
        execute: @escaping (QuickLauncherTarget) throws -> Void = { _ in }
    ) -> QuickLauncherViewModel {
        let suiteName = "WindowBoardTests.QuickLauncher.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        return QuickLauncherViewModel(
            usageStore: QuickLauncherUsageStore(defaults: defaults),
            executeTarget: execute
        )
    }

    private func item(
        id: String,
        title: String,
        subtitle: String? = nil,
        keywords: [String] = [],
        kind: QuickLauncherItemKind = .board,
        isEnabled: Bool = true
    ) -> QuickLauncherItem {
        QuickLauncherItem(
            id: id,
            kind: kind,
            title: title,
            subtitle: subtitle,
            keywords: keywords,
            icon: .system("square"),
            target: .action(.showWindow),
            isEnabled: isEnabled
        )
    }
}
