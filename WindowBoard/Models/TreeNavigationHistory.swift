import Foundation

struct TreeNavigationHistory: Equatable {
    private(set) var backBoardIDs: [SavedWorkspace.ID] = []
    private(set) var currentBoardID: SavedWorkspace.ID
    private(set) var forwardBoardIDs: [SavedWorkspace.ID] = []

    init(currentBoardID: SavedWorkspace.ID) {
        self.currentBoardID = currentBoardID
    }

    var canGoBack: Bool { !backBoardIDs.isEmpty }
    var canGoForward: Bool { !forwardBoardIDs.isEmpty }

    mutating func visit(_ boardID: SavedWorkspace.ID) {
        guard boardID != currentBoardID else { return }
        backBoardIDs.append(currentBoardID)
        currentBoardID = boardID
        forwardBoardIDs.removeAll()
    }

    mutating func goBack() -> SavedWorkspace.ID? {
        guard let boardID = backBoardIDs.popLast() else { return nil }
        forwardBoardIDs.append(currentBoardID)
        currentBoardID = boardID
        return boardID
    }

    mutating func goForward() -> SavedWorkspace.ID? {
        guard let boardID = forwardBoardIDs.popLast() else { return nil }
        backBoardIDs.append(currentBoardID)
        currentBoardID = boardID
        return boardID
    }

    mutating func reconcile(
        validBoardIDs: Set<SavedWorkspace.ID>,
        currentBoardID resolvedCurrentBoardID: SavedWorkspace.ID
    ) {
        backBoardIDs = backBoardIDs.filter(validBoardIDs.contains)
        forwardBoardIDs = forwardBoardIDs.filter(validBoardIDs.contains)

        guard currentBoardID != resolvedCurrentBoardID else { return }
        if validBoardIDs.contains(currentBoardID) {
            backBoardIDs.append(currentBoardID)
        }
        currentBoardID = resolvedCurrentBoardID
        forwardBoardIDs.removeAll()

        while backBoardIDs.last == currentBoardID {
            backBoardIDs.removeLast()
        }
    }
}
