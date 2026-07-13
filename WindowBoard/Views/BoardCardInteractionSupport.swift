import SwiftUI

struct BoardCardSource: Equatable {
    let name: String
    let isPermanent: Bool
}

extension View {
    func interactiveCardMotion(
        cornerRadius: CGFloat = 16,
        isEnabled: Bool = true,
        highlightOpacity: Double = 0.12
    ) -> some View {
        modifier(InteractiveCardMotion(cornerRadius: cornerRadius, isEnabled: isEnabled, highlightOpacity: highlightOpacity))
    }

    func cardPinIn(isActive: Bool, onComplete: @escaping () -> Void) -> some View {
        modifier(CardPinInModifier(isActive: isActive, onComplete: onComplete))
    }

    func workspaceCardEntrance(token: UUID?, index: Int, isEnabled: Bool = true) -> some View {
        modifier(WorkspaceCardEntranceModifier(token: token, index: index, isEnabled: isEnabled))
    }

    func cardDetachExit(isActive: Bool) -> some View {
        modifier(CardDetachExitModifier(isActive: isActive))
    }
}

enum DragPayload {
    private static let boardPrefix = "board:"

    static func board(_ id: SavedWorkspace.ID) -> String { "\(boardPrefix)\(id.uuidString)" }

    static func boardID(from payload: String) -> SavedWorkspace.ID? {
        guard payload.hasPrefix(boardPrefix) else { return nil }
        return UUID(uuidString: String(payload.dropFirst(boardPrefix.count)))
    }
}
