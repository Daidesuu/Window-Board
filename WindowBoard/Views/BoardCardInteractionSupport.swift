import SwiftUI

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
    private static let mainPrefix = "main:"
    private static let permanentPrefix = "permanent:"

    static func mainBoardWindow(_ id: AttachedWindow.ID) -> String { "\(mainPrefix)\(id.uuidString)" }
    static func permanentBoardWindow(_ id: NeverMinimizeWindow.ID) -> String { "\(permanentPrefix)\(id)" }

    static func mainBoardWindowID(from payload: String) -> AttachedWindow.ID? {
        guard payload.hasPrefix(mainPrefix) else { return nil }
        return UUID(uuidString: String(payload.dropFirst(mainPrefix.count)))
    }

    static func permanentBoardWindowID(from payload: String) -> NeverMinimizeWindow.ID? {
        guard payload.hasPrefix(permanentPrefix) else { return nil }
        return String(payload.dropFirst(permanentPrefix.count))
    }
}

struct CardDragHandle: View {
    let payload: String?

    var body: some View {
        if let payload {
            Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
                .draggable(payload)
                .help("Drag to move between boards")
                .accessibilityLabel("Drag to move between boards")
        }
    }
}
