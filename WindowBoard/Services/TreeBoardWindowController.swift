import Combine
import CoreGraphics
import Foundation

protocol TreeWindowOperating: AnyObject, Sendable {
    func isTrusted() -> Bool
    func requestAccessPrompt()
    func openAccessibilitySettings()
    func listWindows() -> [WindowInfo]
    func position(of window: WindowInfo) throws -> CGPoint
    func size(of window: WindowInfo) throws -> CGSize
    func isMinimized(_ window: WindowInfo) -> Bool
    func setMinimized(_ minimized: Bool, for window: WindowInfo) throws
    func raise(_ window: WindowInfo)
    func frontmostVisibleExternalWindow(excludingProcessID excludedPID: pid_t) -> WindowInfo?
}

extension AccessibilityWindowService: TreeWindowOperating {}

enum TreeBoardWindowState: Equatable {
    case available
    case minimized
    case unavailable

    var label: String {
        switch self {
        case .available: "Available"
        case .minimized: "Minimized"
        case .unavailable: "Unavailable"
        }
    }

    var systemImage: String {
        switch self {
        case .available: "checkmark.circle"
        case .minimized: "minus.circle"
        case .unavailable: "exclamationmark.triangle"
        }
    }
}

struct TreeBoardWindowRow: Identifiable {
    let reference: SavedWindowReference
    let liveWindow: WindowInfo?
    let state: TreeBoardWindowState

    var id: SavedWindowReference.ID { reference.id }
}

enum TreeWindowMoveResult: Equatable {
    case moved
    case sameBoard
    case sourceBoardMissing
    case destinationBoardMissing
    case referenceMissing
    case duplicate
}

enum TreeSavedWindowIdentity {
    static func matches(
        _ lhs: SavedWindowReference,
        _ rhs: SavedWindowReference
    ) -> Bool {
        if lhs.id == rhs.id {
            return true
        }

        let sameApplication: Bool
        if let lhsBundleIdentifier = lhs.bundleIdentifier,
           let rhsBundleIdentifier = rhs.bundleIdentifier {
            sameApplication = lhsBundleIdentifier == rhsBundleIdentifier
        } else {
            sameApplication = WindowMatching.appNamesMatch(lhs.appName, rhs.appName)
        }
        guard sameApplication else { return false }

        if let lhsDocumentURL = lhs.documentURL,
           let rhsDocumentURL = rhs.documentURL {
            return lhsDocumentURL == rhsDocumentURL
        }

        let lhsTitle = lhs.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let rhsTitle = rhs.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !lhsTitle.isEmpty, !rhsTitle.isEmpty {
            return lhsTitle == rhsTitle
        }

        return lhs.displayName == rhs.displayName
    }
}

enum TreeBoardWindowResolver {
    static func resolve(
        references: [SavedWindowReference],
        candidates: [WindowInfo],
        minimizedWindowIDs: Set<WindowInfo.ID> = []
    ) -> [TreeBoardWindowRow] {
        var usedWindowIDs: Set<WindowInfo.ID> = []

        return references.map { reference in
            let liveWindow = WindowMatching.bestSavedWindow(
                for: reference,
                in: candidates,
                excluding: usedWindowIDs
            )
            if let liveWindow {
                usedWindowIDs.insert(liveWindow.id)
            }

            let state: TreeBoardWindowState
            if let liveWindow, minimizedWindowIDs.contains(liveWindow.id) {
                state = .minimized
            } else if liveWindow != nil {
                state = .available
            } else {
                state = .unavailable
            }

            return TreeBoardWindowRow(
                reference: reference,
                liveWindow: liveWindow,
                state: state
            )
        }
    }

    static func contains(
        _ window: WindowInfo,
        in references: [SavedWindowReference]
    ) -> Bool {
        references.contains { reference in
            let sameApplication: Bool
            if let referenceBundleIdentifier = reference.bundleIdentifier,
               let windowBundleIdentifier = window.bundleIdentifier {
                sameApplication = referenceBundleIdentifier == windowBundleIdentifier
            } else {
                sameApplication = WindowMatching.appNamesMatch(reference.appName, window.appName)
            }

            guard sameApplication else { return false }

            if let referenceDocumentURL = reference.documentURL,
               let windowDocumentURL = window.documentURL {
                return referenceDocumentURL == windowDocumentURL
            }

            let referenceTitle = reference.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let windowTitle = window.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !referenceTitle.isEmpty, !windowTitle.isEmpty {
                return referenceTitle == windowTitle
            }

            return reference.displayName == window.displayName
        }
    }
}

@MainActor
final class TreeBoardWindowController: ObservableObject {
    @Published private(set) var boardID: SavedWorkspace.ID?
    @Published private(set) var rows: [TreeBoardWindowRow] = []
    @Published private(set) var candidates: [WindowInfo] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var isAccessibilityTrusted = false
    @Published var statusMessage: String?

    private let workspaceStore: WorkspaceStore
    private let serviceFactory: @Sendable () -> any TreeWindowOperating
    private var revision = 0

    init(
        workspaceStore: WorkspaceStore,
        serviceFactory: @escaping @Sendable () -> any TreeWindowOperating = {
            AccessibilityWindowService()
        }
    ) {
        self.workspaceStore = workspaceStore
        self.serviceFactory = serviceFactory
        isAccessibilityTrusted = serviceFactory().isTrusted()
    }

    func loadBoard(_ boardID: SavedWorkspace.ID) async {
        revision += 1
        let expectedRevision = revision
        self.boardID = boardID
        rows = TreeBoardWindowResolver.resolve(
            references: references(for: boardID),
            candidates: []
        )
        await refresh(expectedBoardID: boardID, expectedRevision: expectedRevision)
    }

    func refresh() async {
        guard let boardID else { return }
        await refresh(expectedBoardID: boardID, expectedRevision: revision)
    }

    func requestAccessibilityAccess() {
        serviceFactory().requestAccessPrompt()
        isAccessibilityTrusted = serviceFactory().isTrusted()
    }

    func openAccessibilitySettings() {
        serviceFactory().openAccessibilitySettings()
    }

    func attachWindow(id windowID: WindowInfo.ID) async {
        guard let window = candidates.first(where: { $0.id == windowID }) else {
            statusMessage = "Window is no longer available. Refresh and try again."
            return
        }
        await attach(window)
    }

    func attachFrontmostWindow() async {
        let serviceFactory = serviceFactory
        let excludedPID = ProcessInfo.processInfo.processIdentifier
        let window = await Task.detached(priority: .userInitiated) {
            serviceFactory().frontmostVisibleExternalWindow(excludingProcessID: excludedPID)
        }.value

        guard let window else {
            statusMessage = "No external front window was found."
            return
        }
        await attach(window)
    }

    func detach(referenceID: SavedWindowReference.ID) {
        guard let boardID,
              let board = workspaceStore.workspaces.first(where: { $0.id == boardID }) else {
            return
        }

        let updatedReferences = board.windows.filter { $0.id != referenceID }
        guard updatedReferences.count != board.windows.count else { return }
        _ = workspaceStore.updateWorkspace(id: boardID, windows: updatedReferences)
        rows.removeAll { $0.id == referenceID }
        statusMessage = "Removed window from Board."
    }

    @discardableResult
    func moveWindow(
        referenceID: SavedWindowReference.ID,
        from sourceBoardID: SavedWorkspace.ID,
        to destinationBoardID: SavedWorkspace.ID
    ) -> TreeWindowMoveResult {
        guard sourceBoardID != destinationBoardID else {
            statusMessage = "Window is already on this Board."
            return .sameBoard
        }
        guard let sourceBoard = workspaceStore.workspaces.first(where: { $0.id == sourceBoardID }) else {
            statusMessage = "Source Board is no longer available."
            return .sourceBoardMissing
        }
        guard let destinationBoard = workspaceStore.workspaces.first(where: { $0.id == destinationBoardID }) else {
            statusMessage = "Destination Board is no longer available."
            return .destinationBoardMissing
        }
        guard let reference = sourceBoard.windows.first(where: { $0.id == referenceID }) else {
            statusMessage = "Window is no longer on the source Board."
            return .referenceMissing
        }
        guard !destinationBoard.windows.contains(where: {
            TreeSavedWindowIdentity.matches($0, reference)
        }) else {
            statusMessage = "Window is already on that Board."
            return .duplicate
        }

        var destinationWindows = destinationBoard.windows
        destinationWindows.append(reference)
        guard workspaceStore.updateWorkspace(
            id: destinationBoardID,
            windows: destinationWindows
        ) != nil else {
            statusMessage = "Window could not be moved."
            return .destinationBoardMissing
        }

        let sourceWindows = sourceBoard.windows.filter { $0.id != referenceID }
        guard workspaceStore.updateWorkspace(id: sourceBoardID, windows: sourceWindows) != nil else {
            _ = workspaceStore.updateWorkspace(
                id: destinationBoardID,
                windows: destinationBoard.windows
            )
            statusMessage = "Window could not be moved."
            return .sourceBoardMissing
        }

        updateRowsAfterMove(
            reference: reference,
            sourceBoardID: sourceBoardID,
            destinationBoardID: destinationBoardID
        )
        statusMessage = "Moved window to \(destinationBoard.name)."
        return .moved
    }

    func showWindow(referenceID: SavedWindowReference.ID) async {
        guard let row = rows.first(where: { $0.id == referenceID }),
              let window = row.liveWindow else {
            statusMessage = "Window is unavailable."
            return
        }

        let serviceFactory = serviceFactory
        let wasMinimized = row.state == .minimized
        let didRestore = await Task.detached(priority: .userInitiated) {
            let service = serviceFactory()
            if wasMinimized {
                do {
                    try service.setMinimized(false, for: window)
                } catch {
                    return false
                }
            }
            service.raise(window)
            return true
        }.value

        guard didRestore else {
            statusMessage = "Window could not be restored."
            return
        }

        if let index = rows.firstIndex(where: { $0.id == referenceID }) {
            rows[index] = TreeBoardWindowRow(
                reference: rows[index].reference,
                liveWindow: window,
                state: .available
            )
        }
    }

    func canAttach(_ window: WindowInfo) -> Bool {
        guard let boardID else { return false }
        return !TreeBoardWindowResolver.contains(window, in: references(for: boardID))
    }

    func clearStatusMessage() {
        statusMessage = nil
    }

    private func refresh(
        expectedBoardID: SavedWorkspace.ID,
        expectedRevision: Int
    ) async {
        isRefreshing = true
        let serviceFactory = serviceFactory
        let result = await Task.detached(priority: .utility) {
            let service = serviceFactory()
            let trusted = service.isTrusted()
            guard trusted else {
                return (trusted, [WindowInfo](), Set<WindowInfo.ID>())
            }
            let windows = service.listWindows()
            let minimizedIDs = Set(windows.filter { service.isMinimized($0) }.map(\.id))
            return (trusted, windows, minimizedIDs)
        }.value

        guard boardID == expectedBoardID, revision == expectedRevision else { return }
        isAccessibilityTrusted = result.0
        candidates = result.1
        rows = TreeBoardWindowResolver.resolve(
            references: references(for: expectedBoardID),
            candidates: result.1,
            minimizedWindowIDs: result.2
        )
        isRefreshing = false
    }

    private func attach(_ window: WindowInfo) async {
        guard let boardID,
              let board = workspaceStore.workspaces.first(where: { $0.id == boardID }) else {
            return
        }
        guard !TreeBoardWindowResolver.contains(window, in: board.windows) else {
            statusMessage = "Window is already on this Board."
            return
        }

        let serviceFactory = serviceFactory
        let reference = await Task.detached(priority: .userInitiated) {
            let service = serviceFactory()
            let origin = (try? service.position(of: window)) ?? window.position
            let size = try? service.size(of: window)
            return SavedWindowReference(
                id: UUID(),
                displayName: window.displayName,
                appName: window.appName,
                title: window.title,
                bundleIdentifier: window.bundleIdentifier,
                bundleURLString: window.bundleURL?.absoluteString,
                documentURLString: window.documentURL?.absoluteString,
                workspaceURLString: nil,
                offsetX: 0,
                offsetY: 0,
                originX: origin?.x,
                originY: origin?.y,
                width: size?.width,
                height: size?.height
            )
        }.value

        guard self.boardID == boardID,
              let currentBoard = workspaceStore.workspaces.first(where: { $0.id == boardID }),
              !TreeBoardWindowResolver.contains(window, in: currentBoard.windows) else {
            return
        }

        var updatedReferences = currentBoard.windows
        updatedReferences.append(reference)
        _ = workspaceStore.updateWorkspace(id: boardID, windows: updatedReferences)
        rows.append(
            TreeBoardWindowRow(
                reference: reference,
                liveWindow: window,
                state: .available
            )
        )
        if !candidates.contains(where: { $0.id == window.id }) {
            candidates.append(window)
            candidates.sort {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
        }
        statusMessage = "Added window to Board."
    }

    private func updateRowsAfterMove(
        reference: SavedWindowReference,
        sourceBoardID: SavedWorkspace.ID,
        destinationBoardID: SavedWorkspace.ID
    ) {
        if boardID == sourceBoardID {
            rows.removeAll { $0.id == reference.id }
            return
        }

        guard boardID == destinationBoardID else { return }
        let minimizedIDs = Set(
            rows.compactMap { row in
                row.state == .minimized ? row.liveWindow?.id : nil
            }
        )
        rows = TreeBoardWindowResolver.resolve(
            references: references(for: destinationBoardID),
            candidates: candidates,
            minimizedWindowIDs: minimizedIDs
        )
    }

    private func references(for boardID: SavedWorkspace.ID) -> [SavedWindowReference] {
        workspaceStore.workspaces.first(where: { $0.id == boardID })?.windows ?? []
    }
}
