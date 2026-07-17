import AppKit
import SwiftUI
import UniformTypeIdentifiers

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

    @ViewBuilder
    func windowDraggable(
        id: AttachedWindow.ID,
        enabled: Bool
    ) -> some View {
        if enabled {
            onDrag { WindowBoardDragPayload.windowProvider(id: id) }
        } else {
            self
        }
    }

    @ViewBuilder
    func boardDraggable(
        id: SavedWorkspace.ID,
        sourcePrimaryBoardID: SavedWorkspace.ID? = nil
    ) -> some View {
        onDrag {
            NSItemProvider(
                object: DragPayload.board(id, sourcePrimaryBoardID: sourcePrimaryBoardID) as NSString
            )
        }
    }
}

enum WindowBoardDragKind: Hashable {
    case board
    case window

    var type: UTType {
        switch self {
        case .board:
            .text
        case .window:
            WindowBoardDragType.window
        }
    }
}

private enum WindowBoardDragType {
    static let window = UTType(
        exportedAs: "com.local.windowboard.window-card",
        conformingTo: .data
    )
}

enum DragPayload {
    private static let boardPrefix = "windowboard-board:"
    private static let sourcePrimaryPrefix = ";source-primary:"

    static func board(
        _ id: SavedWorkspace.ID,
        sourcePrimaryBoardID: SavedWorkspace.ID? = nil
    ) -> String {
        var payload = "\(boardPrefix)\(id.uuidString)"
        if let sourcePrimaryBoardID {
            payload += "\(sourcePrimaryPrefix)\(sourcePrimaryBoardID.uuidString)"
        }
        return payload
    }

    static func boardID(from payload: String) -> SavedWorkspace.ID? {
        boardPayload(from: payload)?.boardID
    }

    static func boardPayload(from payload: String) -> SidebarBoardDragPayload? {
        guard payload.hasPrefix(boardPrefix) else { return nil }
        let value = String(payload.dropFirst(boardPrefix.count))
        let parts = value.components(separatedBy: sourcePrimaryPrefix)
        guard let boardID = UUID(uuidString: parts[0]) else { return nil }
        let sourcePrimaryBoardID = parts.count == 2
            ? UUID(uuidString: parts[1])
            : nil
        guard parts.count <= 2 else { return nil }
        return SidebarBoardDragPayload(
            boardID: boardID,
            sourcePrimaryBoardID: sourcePrimaryBoardID
        )
    }
}

struct SidebarBoardDragPayload: Equatable {
    let boardID: SavedWorkspace.ID
    let sourcePrimaryBoardID: SavedWorkspace.ID?

    var canRemoveFromCurrentBoard: Bool {
        guard let sourcePrimaryBoardID else { return false }
        return sourcePrimaryBoardID != boardID
    }
}

enum WindowBoardDragPayload: Equatable {
    case board(SavedWorkspace.ID)
    case window(AttachedWindow.ID)

    var kind: WindowBoardDragKind {
        switch self {
        case .board:
            .board
        case .window:
            .window
        }
    }

    static func windowProvider(id: AttachedWindow.ID) -> NSItemProvider {
        itemProvider(kind: .window, id: id)
    }

    static func id(from data: Data) -> UUID? {
        UUID(uuidString: String(decoding: data, as: UTF8.self))
    }

    private static func itemProvider(kind: WindowBoardDragKind, id: UUID) -> NSItemProvider {
        // The drag system can start the preview immediately because the payload is
        // already available; registration closures defer that first request.
        NSItemProvider(
            item: Data(id.uuidString.utf8) as NSData,
            typeIdentifier: kind.type.identifier
        )
    }
}

struct WindowBoardDropDelegate: DropDelegate {
    let acceptedKinds: Set<WindowBoardDragKind>
    let setTargeted: (Bool) -> Void
    let perform: (WindowBoardDragPayload, CGPoint) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        provider(in: info) != nil
    }

    func dropEntered(info: DropInfo) {
        setTargeted(provider(in: info) != nil)
    }

    func dropExited(info: DropInfo) {
        setTargeted(false)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard provider(in: info) != nil else { return nil }
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        defer { setTargeted(false) }
        guard let (kind, provider) = provider(in: info) else { return false }
        let location = info.location
        let action = perform
        switch kind {
        case .board:
            provider.loadObject(ofClass: NSString.self) { object, _ in
                guard let payload = object as? String,
                      let id = DragPayload.boardID(from: payload) else {
                    return
                }
                DispatchQueue.main.async {
                    action(.board(id), location)
                }
            }
        case .window:
            provider.loadDataRepresentation(forTypeIdentifier: kind.type.identifier) { data, _ in
                guard let data, let id = WindowBoardDragPayload.id(from: data) else { return }
                DispatchQueue.main.async {
                    action(.window(id), location)
                }
            }
        }
        return true
    }

    private func provider(in info: DropInfo) -> (WindowBoardDragKind, NSItemProvider)? {
        for kind in acceptedKinds {
            if let provider = info.itemProviders(for: [kind.type]).first {
                return (kind, provider)
            }
        }
        return nil
    }
}

struct SidebarBoardPayloadDropDelegate: DropDelegate {
    let setTargeted: (Bool) -> Void
    let perform: (SidebarBoardDragPayload) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        provider(in: info) != nil
    }

    func dropEntered(info: DropInfo) {
        setTargeted(provider(in: info) != nil)
    }

    func dropExited(info: DropInfo) {
        setTargeted(false)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard provider(in: info) != nil else { return nil }
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        defer { setTargeted(false) }
        guard let provider = provider(in: info) else { return false }
        let action = perform
        provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let value = object as? String,
                  let payload = DragPayload.boardPayload(from: value) else {
                return
            }
            DispatchQueue.main.async {
                action(payload)
            }
        }
        return true
    }

    private func provider(in info: DropInfo) -> NSItemProvider? {
        info.itemProviders(for: [.text]).first
    }
}
