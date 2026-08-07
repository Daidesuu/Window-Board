import Combine
import Foundation

@MainActor
final class QuickLauncherViewModel: ObservableObject {
    @Published private(set) var query = ""
    @Published private(set) var results: [QuickLauncherItem] = []
    @Published var selectedItemID: QuickLauncherItem.ID?
    @Published private(set) var isVisible = false
    @Published private(set) var isExecuting = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var focusRequestRevision = 0
    @Published private(set) var keyboardSelectionScrollRevision = 0

    var currentBoardTitle: String? {
        sourceItems.first { $0.kind == .board && $0.isSelectedBoardRelated }?.title
    }

    private let searchService: QuickLauncherSearchService
    private let usageStore: QuickLauncherUsageStore
    private let executeTarget: (QuickLauncherTarget) throws -> Void
    private let onDismiss: () -> Void
    private var sourceItems: [QuickLauncherItem] = []

    init(
        searchService: QuickLauncherSearchService = QuickLauncherSearchService(),
        usageStore: QuickLauncherUsageStore = QuickLauncherUsageStore(),
        executeTarget: @escaping (QuickLauncherTarget) throws -> Void,
        onDismiss: @escaping () -> Void = {}
    ) {
        self.searchService = searchService
        self.usageStore = usageStore
        self.executeTarget = executeTarget
        self.onDismiss = onDismiss
    }

    func present(items: [QuickLauncherItem]) {
        sourceItems = items
        query = ""
        errorMessage = nil
        isVisible = true
        requestSearchFocus()
        refreshResults()
    }

    func requestSearchFocus() {
        focusRequestRevision &+= 1
    }

    func updateItems(_ items: [QuickLauncherItem]) {
        sourceItems = items
        refreshResults(preserveSelection: true)
    }

    func updateQuery(_ query: String) {
        guard self.query != query else { return }
        self.query = query
        refreshResults(preserveSelection: false)
    }

    func clearQuery() {
        updateQuery("")
    }

    func dismiss() {
        isVisible = false
        isExecuting = false
        onDismiss()
    }

    func moveSelection(by offset: Int) {
        guard !results.isEmpty else {
            selectedItemID = nil
            return
        }
        let enabledIndices = results.indices.filter { results[$0].isEnabled }
        guard !enabledIndices.isEmpty else {
            selectedItemID = nil
            return
        }
        guard let selectedItemID,
              let currentIndex = results.firstIndex(where: { $0.id == selectedItemID }),
              let position = enabledIndices.firstIndex(of: currentIndex) else {
            self.selectedItemID = results[enabledIndices[0]].id
            return
        }
        let targetPosition = min(max(position + offset, 0), enabledIndices.count - 1)
        self.selectedItemID = results[enabledIndices[targetPosition]].id
        keyboardSelectionScrollRevision &+= 1
    }

    func select(_ id: QuickLauncherItem.ID) {
        guard results.contains(where: { $0.id == id && $0.isEnabled }) else { return }
        selectedItemID = id
    }

    func executeSelected() {
        guard isVisible,
              !isExecuting,
              let selectedItemID,
              let item = results.first(where: { $0.id == selectedItemID }),
              item.isEnabled else { return }

        execute(item, target: item.target)
    }

    func execute(_ item: QuickLauncherItem, target: QuickLauncherTarget) {
        guard isVisible, !isExecuting, item.isEnabled else { return }

        isExecuting = true
        errorMessage = nil
        do {
            try executeTarget(target)
            usageStore.recordUse(of: item.id)
            isVisible = false
            isExecuting = false
            onDismiss()
        } catch {
            isExecuting = false
            errorMessage = error.localizedDescription
        }
    }

    private func refreshResults(preserveSelection: Bool = true) {
        let previousSelection = selectedItemID
        results = searchService.search(items: sourceItems, query: query, usage: usageStore)
        if preserveSelection,
           let previousSelection,
           results.contains(where: { $0.id == previousSelection && $0.isEnabled }) {
            selectedItemID = previousSelection
        } else {
            selectedItemID = results.first(where: \.isEnabled)?.id
        }
    }
}
