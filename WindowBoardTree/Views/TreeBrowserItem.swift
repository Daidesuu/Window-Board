import Foundation

enum TreeBrowserItem: Identifiable {
    enum ID: Hashable {
        case board(SavedWorkspace.ID)
        case window(SavedWindowReference.ID)
    }

    case board(SavedWorkspace, childCount: Int)
    case window(TreeBoardWindowRow)

    var id: ID {
        switch self {
        case let .board(board, _): .board(board.id)
        case let .window(row): .window(row.id)
        }
    }

    var name: String {
        switch self {
        case let .board(board, _):
            board.name
        case let .window(row):
            row.reference.title.isEmpty ? row.reference.displayName : row.reference.title
        }
    }

    var kind: String {
        switch self {
        case .board:
            "Board"
        case let .window(row):
            row.reference.appName
        }
    }

    var status: String {
        switch self {
        case let .board(_, childCount):
            guard childCount > 0 else { return "No child Boards" }
            return "\(childCount) child \(childCount == 1 ? "Board" : "Boards")"
        case let .window(row):
            return row.state.label
        }
    }

    var windowCount: String {
        switch self {
        case let .board(board, _):
            String(board.windows.count)
        case .window:
            "-"
        }
    }
}
