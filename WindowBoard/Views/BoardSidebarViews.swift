import AppKit
import SwiftUI

enum AttachedWindowDisplayState: Equatable {
    case available
    case resolving
    case minimized
    case unavailable
    case reconnecting

    var title: String {
        switch self {
        case .available:
            "Available"
        case .resolving:
            "Resolving"
        case .minimized:
            "Minimized"
        case .unavailable:
            "Unavailable"
        case .reconnecting:
            "Reconnecting"
        }
    }

    var systemImage: String {
        switch self {
        case .available:
            "checkmark.circle"
        case .resolving:
            "arrow.triangle.2.circlepath"
        case .minimized:
            "minus.square"
        case .unavailable:
            "exclamationmark.triangle"
        case .reconnecting:
            "arrow.triangle.2.circlepath"
        }
    }

    var needsAttention: Bool {
        switch self {
        case .available, .resolving:
            false
        case .minimized, .unavailable, .reconnecting:
            true
        }
    }

    var recoveryActionTitle: String? {
        switch self {
        case .available, .resolving:
            nil
        case .minimized:
            "Restore Window"
        case .unavailable:
            "Find or Reopen"
        case .reconnecting:
            "Finding..."
        }
    }
}

enum SidebarBoardDropPosition {
    case before
    case child
    case after
}

struct WorkspaceSidebarView: View {
    private let titlebarInsetHeight: CGFloat = 4

    let workspaces: [SavedWorkspace]
    let activeWorkspaceID: SavedWorkspace.ID?
    let selection: SidebarSelection?
    let currentBoardIDs: [SavedWorkspace.ID]
    let projection: SidebarBoardProjection
    let selectBoard: (SidebarBoardSelection) -> Void
    let includeBoard: (SavedWorkspace.ID) -> Void
    let excludeBoard: (SavedWorkspace.ID) -> Void
    let showBoardSettings: (SavedWorkspace) -> Void
    let restoreBoardLayout: (SidebarBoardSelection) -> Void
    let removeBoardWindows: (SavedWorkspace) -> Void
    let deleteBoard: (SavedWorkspace) -> Void
    let separateBoard: (SidebarBoardDragPayload) -> Bool
    let dropBoard: (SavedWorkspace.ID, SavedWorkspace.ID, SidebarBoardDropPosition) -> BoardCompositionMutationResult
    let moveWindow: (AttachedWindow.ID, SavedWorkspace.ID) -> BoardWindowMutationResult
    @State private var pendingBoardDeletion: SavedWorkspace?

    private var currentBoardIDSet: Set<SavedWorkspace.ID> {
        Set(currentBoardIDs)
    }

    private enum SidebarItem: Identifiable {
        case group(SidebarBoardGroup)
        case board(SavedWorkspace)

        var id: String {
            switch self {
            case let .group(group): "group-\(group.primaryBoardID.uuidString)"
            case let .board(board): "board-\(board.id.uuidString)"
            }
        }
    }

    private var sidebarItems: [SidebarItem] {
        let groupByPrimaryID = Dictionary(uniqueKeysWithValues: projection.groups.map { ($0.primaryBoardID, $0) })
        let standaloneIDs = Set(projection.standaloneBoards.map(\.id))
        return workspaces.compactMap { workspace in
            if let group = groupByPrimaryID[workspace.id] {
                return .group(group)
            }
            if standaloneIDs.contains(workspace.id) {
                return .board(workspace)
            }
            return nil
        }
    }

    var body: some View {
        List {
            Section("Boards") {
                if workspaces.isEmpty {
                    Text("No Saved Boards")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(sidebarItems) { item in
                        switch item {
                        case let .group(group):
                            SidebarBoardTabGroup(
                                group: group,
                                isSelected: selection == .currentBoardGroup(primaryID: group.primaryBoardID),
                                isComposite: true,
                                selectBoard: selectBoard,
                                contextMenu: { workspace in
                                    boardContextMenu(
                                        for: workspace,
                                        selection: SidebarBoardSelection(
                                            memberBoardID: workspace.id,
                                            groupPrimaryID: group.primaryBoardID
                                        )
                                    )
                                },
                                dropBoard: performBoardDrop,
                                moveWindow: moveWindow,
                                separateBoard: separateBoard
                            )
                            .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 6, trailing: 8))
                            .listRowBackground(Color.clear)
                        case let .board(workspace):
                            SidebarBoardTabGroup(
                                group: SidebarBoardGroup(
                                    primaryBoardID: workspace.id,
                                    boards: [workspace]
                                ),
                                isSelected: selection == .board(workspace.id),
                                isComposite: false,
                                selectBoard: selectBoard,
                                contextMenu: { board in
                                    boardContextMenu(
                                        for: board,
                                        selection: SidebarBoardSelection(
                                            memberBoardID: board.id,
                                            groupPrimaryID: board.id
                                        )
                                    )
                                },
                                dropBoard: performBoardDrop,
                                moveWindow: moveWindow,
                                separateBoard: separateBoard
                            )
                            .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 6, trailing: 8))
                            .listRowBackground(Color.clear)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top, spacing: 0) {
            Color.clear
                .frame(height: titlebarInsetHeight)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SidebarBoardDeletionDropZone(requestDelete: requestBoardDeletion)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .alert(
            deleteConfirmationTitle,
            isPresented: Binding(
                get: { pendingBoardDeletion != nil },
                set: { isPresented in
                    if !isPresented {
                        pendingBoardDeletion = nil
                    }
                }
            ),
            presenting: pendingBoardDeletion
        ) { workspace in
            Button("Delete Board", role: .destructive) {
                deleteBoard(workspace)
                pendingBoardDeletion = nil
            }
            Button("Cancel", role: .cancel) {
                pendingBoardDeletion = nil
            }
        } message: { workspace in
            Text("This removes the saved board and its \(workspace.windows.count) window references. External app windows will stay open.")
        }
    }

    @ViewBuilder
    private func boardContextMenu(
        for workspace: SavedWorkspace,
        selection: SidebarBoardSelection
    ) -> some View {
        if workspace.id == activeWorkspaceID {
            Button("Current Board") {}
                .disabled(true)
        } else if currentBoardIDSet.contains(workspace.id) {
            Button {
                excludeBoard(workspace.id)
            } label: {
                Label("Remove from Current Board", systemImage: "rectangle.badge.minus")
            }
        } else {
            Button {
                includeBoard(workspace.id)
            } label: {
                Label("Include in Current Board", systemImage: "rectangle.badge.plus")
            }
        }

        Divider()

        Button {
            showBoardSettings(workspace)
        } label: {
            Label("Board Settings", systemImage: "slider.horizontal.3")
        }

        Button {
            restoreBoardLayout(selection)
        } label: {
            Label("Restore Layout", systemImage: "arrow.counterclockwise")
        }

        Divider()

        Button(role: .destructive) {
            removeBoardWindows(workspace)
        } label: {
            Label("Remove All Windows", systemImage: "xmark.circle")
        }
        .disabled(workspace.windows.isEmpty)

        Button(role: .destructive) {
            deleteBoard(workspace)
        } label: {
            Label("Delete Board", systemImage: "trash")
        }
        .disabled(workspace.isDefault)
    }

    private func performBoardDrop(
        _ sourceBoardID: SavedWorkspace.ID,
        _ targetBoardID: SavedWorkspace.ID,
        location: CGPoint,
        height: CGFloat
    ) -> Bool {
        let edgeInset = min(12, height * 0.25)
        let position: SidebarBoardDropPosition
        if location.y < edgeInset {
            position = .before
        } else if location.y > height - edgeInset {
            position = .after
        } else {
            position = .child
        }
        _ = dropBoard(sourceBoardID, targetBoardID, position)
        return true
    }

    private func requestBoardDeletion(_ payload: SidebarBoardDragPayload) {
        guard let workspace = workspaces.first(where: { $0.id == payload.boardID }) else {
            return
        }
        if workspace.isDefault {
            deleteBoard(workspace)
            return
        }
        if workspace.windows.isEmpty {
            deleteBoard(workspace)
        } else {
            pendingBoardDeletion = workspace
        }
    }

    private var deleteConfirmationTitle: String {
        "Delete \(pendingBoardDeletion?.name ?? "Board")?"
    }
}

private struct SidebarBoardTabGroup<ContextMenu: View>: View {
    let group: SidebarBoardGroup
    let isSelected: Bool
    let isComposite: Bool
    let selectBoard: (SidebarBoardSelection) -> Void
    @ViewBuilder let contextMenu: (SavedWorkspace) -> ContextMenu
    let dropBoard: (SavedWorkspace.ID, SavedWorkspace.ID, CGPoint, CGFloat) -> Bool
    let moveWindow: (AttachedWindow.ID, SavedWorkspace.ID) -> BoardWindowMutationResult
    let separateBoard: (SidebarBoardDragPayload) -> Bool
    @State private var isHovering = false
    @State private var boardDropTargetID: SavedWorkspace.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if isComposite {
                ScrollView(.horizontal) {
                    HStack(spacing: 4) {
                        ForEach(group.boards) { workspace in
                            tab(for: workspace)
                        }
                    }
                    .padding(4)
                }
                .scrollIndicators(.hidden)
            } else {
                HStack(spacing: 4) {
                    ForEach(group.boards) { workspace in
                        tab(for: workspace)
                    }
                }
                .padding(4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 4) {
                if isComposite {
                    Text("\(group.boards.count) boards")
                    Text("·")
                }
                Text("\(totalWindowCount) \(totalWindowCount == 1 ? "window" : "windows")")
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)

            if isComposite {
                SidebarGroupSeparationDropZone(
                    primaryBoardID: group.primaryBoardID,
                    separateBoard: separateBoard
                )
            }
        }
        .padding(4)
        .background(
            isSelected
                ? Color.accentColor.opacity(0.22)
                : (isHovering ? Color.primary.opacity(0.055) : Color.clear),
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
        .overlay {
            if !isSelected {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07))
            }
        }
        .onHover { isHovering = $0 }
        .help(group.displayTitle)
    }

    private func tab(for workspace: SavedWorkspace) -> some View {
        HStack(spacing: 6) {
            workspaceGlyph(for: workspace)
                .frame(width: 16)
            Text(workspace.name)
                .font(.callout.weight(isSelected ? .semibold : .regular))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 9)
        .frame(
            minWidth: isComposite ? 96 : nil,
            maxWidth: isComposite ? 150 : .infinity,
            minHeight: 32,
            alignment: .leading
        )
        .background(
            Color.primary.opacity(isSelected ? 0.10 : 0.055),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .contentShape(Rectangle())
        .boardDraggable(
            id: workspace.id,
            sourcePrimaryBoardID: removableRootPrimaryID(for: workspace)
        )
        .simultaneousGesture(
            TapGesture().onEnded {
                selectBoard(
                    SidebarBoardSelection(
                        memberBoardID: group.primaryBoardID,
                        groupPrimaryID: group.primaryBoardID
                    )
                )
            }
        )
        .contextMenu { contextMenu(workspace) }
        .help(workspace.displayName)
        .onDrop(
            of: [
                WindowBoardDragKind.board.type.identifier,
                WindowBoardDragKind.window.type.identifier
            ],
            delegate: WindowBoardDropDelegate(
                acceptedKinds: [.board, .window],
                setTargeted: { isTargeted in
                    boardDropTargetID = isTargeted ? workspace.id : nil
                },
                perform: { payload, location in
                    switch payload {
                    case let .board(boardID):
                        _ = dropBoard(boardID, workspace.id, location, 32)
                    case let .window(windowID):
                        _ = moveWindow(windowID, workspace.id)
                    }
                }
            )
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(
                    isDropTargeted(workspace.id) ? Color.accentColor.opacity(0.75) : Color.clear,
                    lineWidth: 1.2
                )
        }
    }

    private var totalWindowCount: Int {
        group.boards.reduce(into: 0) { $0 += $1.windows.count }
    }

    private func isDropTargeted(_ boardID: SavedWorkspace.ID) -> Bool {
        boardDropTargetID == boardID
    }

    private func removableRootPrimaryID(for workspace: SavedWorkspace) -> SavedWorkspace.ID? {
        guard isComposite, workspace.id != group.primaryBoardID else {
            return nil
        }
        return group.primaryBoardID
    }

    @ViewBuilder
    private func workspaceGlyph(for workspace: SavedWorkspace) -> some View {
        if let title = WorkspaceStatusItemIcon.title(from: workspace.statusItemSymbolName) {
            Text(title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundStyle(.secondary)
        } else {
            Image(systemName: workspace.statusItemSymbolName ?? WorkspaceStatusItemIcon.defaultSymbolName)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct SidebarGroupSeparationDropZone: View {
    let primaryBoardID: SavedWorkspace.ID
    let separateBoard: (SidebarBoardDragPayload) -> Bool
    @State private var isTargeted = false

    var body: some View {
        Label("Remove from Current Board", systemImage: "rectangle.badge.minus")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: isTargeted ? 30 : 8)
            .background(
                Color.secondary.opacity(isTargeted ? 0.09 : 0.001),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(
                        Color.secondary.opacity(isTargeted ? 0.45 : 0.001),
                        style: StrokeStyle(lineWidth: 1, dash: [5, 4])
                    )
            }
            .opacity(isTargeted ? 1 : 0.001)
            .contentShape(Rectangle())
            .onDrop(
                of: [WindowBoardDragKind.board.type.identifier],
                delegate: SidebarBoardPayloadDropDelegate(
                    setTargeted: { isTargeted = $0 },
                    perform: { payload in
                        guard payload.sourcePrimaryBoardID == primaryBoardID else { return }
                        _ = separateBoard(payload)
                    }
                )
            )
    }
}

private struct SidebarBoardDeletionDropZone: View {
    let requestDelete: (SidebarBoardDragPayload) -> Void
    @State private var isTargeted = false

    var body: some View {
        Label("Delete Board", systemImage: "trash")
            .font(.caption.weight(.semibold))
            .foregroundStyle(Color.red)
            .frame(maxWidth: .infinity, minHeight: 38)
            .background(
                Color.red.opacity(isTargeted ? 0.14 : 0.001),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(
                        Color.red.opacity(isTargeted ? 0.65 : 0.001),
                        style: StrokeStyle(lineWidth: 1, dash: [5, 4])
                    )
            }
            .opacity(isTargeted ? 1 : 0.001)
            .contentShape(Rectangle())
            .onDrop(
                of: [WindowBoardDragKind.board.type.identifier],
                delegate: SidebarBoardPayloadDropDelegate(
                    setTargeted: { isTargeted = $0 },
                    perform: requestDelete
                )
            )
    }
}
