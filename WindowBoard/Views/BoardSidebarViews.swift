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
    let separateBoard: (SidebarBoardSelection) -> BoardCompositionMutationResult
    let dropBoard: (SavedWorkspace.ID, SavedWorkspace.ID) -> BoardCompositionMutationResult
    let includeChildBoard: (SavedWorkspace.ID, SavedWorkspace.ID) -> BoardCompositionMutationResult
    let invalidBoardDrop: () -> Void
    let moveWindow: (AttachedWindow.ID, SavedWorkspace.ID) -> BoardWindowMutationResult
    @State private var pendingBoardDeletion: SavedWorkspace?
    @State private var pendingChildBoard: SavedWorkspace?
    @State private var mutationMessage: String?
    @State private var messageRevision = UUID()

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
                    ForEach(Array(sidebarItems.enumerated()), id: \.element.id) { index, item in
                        switch item {
                        case let .group(group):
                            SidebarBoardTabGroup(
                                group: group,
                                isSelected: selection == .currentBoardGroup(primaryID: group.primaryBoardID),
                                isComposite: true,
                                showsSeparator: index > 0,
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
                                invalidBoardDrop: reportInvalidBoardDrop,
                                moveWindow: moveWindow
                            )
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                        case let .board(workspace):
                            SidebarBoardTabGroup(
                                group: SidebarBoardGroup(
                                    primaryBoardID: workspace.id,
                                    boards: [workspace]
                                ),
                                isSelected: selection == .board(workspace.id),
                                isComposite: false,
                                showsSeparator: index > 0,
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
                                invalidBoardDrop: reportInvalidBoardDrop,
                                moveWindow: moveWindow
                            )
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .listSectionSeparator(.hidden)
        .safeAreaInset(edge: .top, spacing: 0) {
            Color.clear
                .frame(height: titlebarInsetHeight)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SidebarBoardDeletionDropZone(requestDelete: requestBoardDeletion)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .sheet(item: $pendingChildBoard) { child in
            SidebarChildBoardPicker(
                child: child,
                parents: workspaces.filter { $0.id != child.id },
                add: { parentID in
                    let result = includeChildBoard(child.id, parentID)
                    if result == .inserted { showMutationMessage(result.userMessage) }
                    return result
                }
            )
        }
        .overlay(alignment: .bottom) {
            if let mutationMessage {
                Text(mutationMessage)
                    .font(.callout)
                    .padding(10)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .padding(8)
                    .allowsHitTesting(false)
                    .accessibilityLabel(mutationMessage)
            }
        }
        .task(id: messageRevision) {
            guard mutationMessage != nil else { return }
            do { try await Task.sleep(for: .seconds(4)) } catch { return }
            mutationMessage = nil
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
        } else if currentBoardIDSet.contains(workspace.id), selection.groupPrimaryID != activeWorkspaceID {
            Button {
                excludeBoard(workspace.id)
            } label: {
                Label("Remove from Current Board", systemImage: "rectangle.badge.minus")
            }
        } else if !currentBoardIDSet.contains(workspace.id) {
            Button {
                includeBoard(workspace.id)
            } label: {
                Label("Include in Current Board", systemImage: "rectangle.badge.plus")
            }
        }

        Divider()

        if selection.memberBoardID != selection.groupPrimaryID {
            Button {
                showMutationMessage(separateBoard(selection).userMessage)
            } label: {
                Label("この並列グループから外す", systemImage: "rectangle.badge.minus")
            }
        }

        Button {
            pendingChildBoard = workspace
        } label: {
            Label("子Boardとして追加…", systemImage: "arrow.turn.down.right")
        }

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

    private func performBoardDrop(_ sourceID: SavedWorkspace.ID, _ primaryID: SavedWorkspace.ID) -> BoardCompositionMutationResult {
        let result = dropBoard(sourceID, primaryID)
        showMutationMessage(result.userMessage)
        return result
    }

    private func reportInvalidBoardDrop() {
        invalidBoardDrop()
        showMutationMessage("Boardのドラッグデータを読み取れませんでした。")
    }

    private func showMutationMessage(_ message: String) {
        mutationMessage = message
        messageRevision = UUID()
    }

    private var deleteConfirmationTitle: String {
        "Delete \(pendingBoardDeletion?.name ?? "Board")?"
    }
}

private struct SidebarChildBoardPicker: View {
    let child: SavedWorkspace
    let parents: [SavedWorkspace]
    let add: (SavedWorkspace.ID) -> BoardCompositionMutationResult
    @Environment(\.dismiss) private var dismiss
    @State private var parentID: SavedWorkspace.ID?
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("子Boardとして追加")
                .font(.headline)
            Text("「\(child.name)」を追加する親Boardを選択してください。")
            Picker("親Board", selection: $parentID) {
                Text("選択してください").tag(Optional<SavedWorkspace.ID>.none)
                ForEach(parents) { parent in
                    Text(parent.name).tag(Optional(parent.id))
                }
            }
            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.callout)
            }
            HStack {
                Spacer()
                Button("キャンセル") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("追加") {
                    guard let parentID else { return }
                    let result = add(parentID)
                    if result == .inserted {
                        dismiss()
                    } else {
                        errorMessage = result.userMessage
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(parentID == nil)
            }
        }
        .padding(24)
        .frame(width: 380)
        .onChange(of: parentID) { _, _ in errorMessage = nil }
    }
}

private struct SidebarBoardTabGroup<ContextMenu: View>: View {
    let group: SidebarBoardGroup
    let isSelected: Bool
    let isComposite: Bool
    let showsSeparator: Bool
    let selectBoard: (SidebarBoardSelection) -> Void
    @ViewBuilder let contextMenu: (SavedWorkspace) -> ContextMenu
    let dropBoard: (SavedWorkspace.ID, SavedWorkspace.ID) -> BoardCompositionMutationResult
    let invalidBoardDrop: () -> Void
    let moveWindow: (AttachedWindow.ID, SavedWorkspace.ID) -> BoardWindowMutationResult
    @State private var isHovering = false
    @State private var boardDropTargetID: SavedWorkspace.ID?
    @State private var isBoardDropTargeted = false

    var body: some View {
        Group {
            if isComposite {
                compositeBoardGroup
            } else if let workspace = group.boards.first {
                standardBoardRow(for: workspace)
            }
        }
        .padding(EdgeInsets(top: 4, leading: 8, bottom: 6, trailing: 8))
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .overlay(alignment: .top) {
            if showsSeparator {
                Rectangle()
                    .fill(Color.primary.opacity(0.12))
                    .frame(height: 1)
                    .padding(.horizontal, 16)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .overlay(alignment: .topTrailing) {
            if isBoardDropTargeted {
                Text("並列Boardとして追加")
                    .font(.caption.weight(.semibold))
                    .padding(4)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
                    .allowsHitTesting(false)
            }
        }
        .onDrop(
            of: [WindowBoardDragKind.board.type.identifier],
            delegate: WindowBoardDropDelegate(
                acceptedKinds: [.board],
                setTargeted: { isBoardDropTargeted = $0 },
                perform: { payload, _ in
                    if case let .board(boardID) = payload {
                        _ = dropBoard(boardID, group.primaryBoardID)
                    }
                },
                onFailure: invalidBoardDrop
            )
        )
    }

    private var compositeBoardGroup: some View {
        VStack(alignment: .leading, spacing: 4) {
            SidebarBoardGridLayout {
                ForEach(Array(group.boards.enumerated()), id: \.element.id) { index, workspace in
                    tab(for: workspace)
                        .anchorPreference(key: SidebarBoardCellBoundsKey.self, value: .bounds) { [index: $0] }
                }
            }
            .overlayPreferenceValue(SidebarBoardCellBoundsKey.self) { anchors in
                GeometryReader { geometry in
                    let frames = anchors.keys.sorted().compactMap { anchors[$0].map { geometry[$0] } }
                    SidebarBoardSeparators(segments: SidebarBoardGridMetrics.separatorSegments(width: geometry.size.width, frames: frames))
                        .stroke(Color.primary.opacity(0.06), lineWidth: 1)
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            HStack(spacing: 6) {
                Text("\(totalWindowCount) windows")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                selectionIndicator
            }
            .padding(.horizontal, 8)
        }
        .help(group.displayTitle)
    }

    private func standardBoardRow(for workspace: SavedWorkspace) -> some View {
        HStack(spacing: 8) {
            workspaceGlyph(for: workspace)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(workspace.name)
                    .font(.callout.weight(isSelected ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text("\(workspace.windows.count) \(workspace.windows.count == 1 ? "window" : "windows")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
            selectionIndicator
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .boardDraggable(
            id: workspace.id,
            sourcePrimaryBoardID: nil
        )
        .simultaneousGesture(
            TapGesture().onEnded {
                selectBoard(
                    SidebarBoardSelection(
                        memberBoardID: workspace.id,
                        groupPrimaryID: workspace.id
                    )
                )
            }
        )
        .contextMenu { contextMenu(workspace) }
        .help(workspace.displayName)
        .onDrop(
            of: [
                WindowBoardDragKind.window.type.identifier
            ],
            delegate: WindowBoardDropDelegate(
                acceptedKinds: [.window],
                setTargeted: { isTargeted in
                    boardDropTargetID = isTargeted ? workspace.id : nil
                },
                perform: { payload, _ in
                    switch payload {
                    case .board:
                        break
                    case let .window(windowID):
                        _ = moveWindow(windowID, workspace.id)
                    }
                }
            )
        )
        .background(
            isSelected
                ? Color.accentColor.opacity(0.18)
                : (isBoardDropTargeted ? Color.accentColor.opacity(0.12) : (isHovering ? Color.primary.opacity(0.045) : Color.clear)),
            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(
                    isDropTargeted(workspace.id) ? Color.accentColor.opacity(0.75) : Color.clear,
                    lineWidth: 1.2
                )
        }
        .onHover { isHovering = $0 }
    }

    private func tab(for workspace: SavedWorkspace) -> some View {
        HStack(spacing: 6) {
            workspaceGlyph(for: workspace)
                .frame(width: 16)
            Text(workspace.name)
                .font(.callout.weight(isSelected ? .semibold : .regular))
                .lineLimit(2)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
        .background(
            isBoardDropTargeted ? Color.accentColor.opacity(0.12) : (isSelected ? Color.accentColor.opacity(0.16) : Color.clear),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(workspace.displayName)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            selectBoard(SidebarBoardSelection(memberBoardID: group.primaryBoardID, groupPrimaryID: group.primaryBoardID))
        }
        .onDrop(
            of: [
                WindowBoardDragKind.window.type.identifier
            ],
            delegate: WindowBoardDropDelegate(
                acceptedKinds: [.window],
                setTargeted: { isTargeted in
                    boardDropTargetID = isTargeted ? workspace.id : nil
                },
                perform: { payload, _ in
                    switch payload {
                    case .board:
                        break
                    case let .window(windowID):
                        _ = moveWindow(windowID, workspace.id)
                    }
                }
            )
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(
                    isDropTargeted(workspace.id) ? Color.accentColor.opacity(0.75) : Color.clear,
                    lineWidth: 1.2
                )
        }
    }

    @ViewBuilder
    private var selectionIndicator: some View {
        if isSelected {
            Image(systemName: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
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

/// Equal-width cells, measured at their actual column width without a height-feedback loop.
struct SidebarBoardGridMetrics {
    static let minimumColumnWidth: CGFloat = 96
    static let spacing: CGFloat = 6

    static func resolvedWidth(_ proposedWidth: CGFloat?) -> CGFloat {
        guard let proposedWidth, proposedWidth.isFinite else {
            return minimumColumnWidth * 2 + spacing
        }
        return max(0, proposedWidth)
    }

    static func columnCount(for width: CGFloat) -> Int {
        width >= minimumColumnWidth * 2 + spacing ? 2 : 1
    }

    static func columnWidth(for width: CGFloat) -> CGFloat {
        let columns = columnCount(for: width)
        return max(0, (width - CGFloat(columns - 1) * spacing) / CGFloat(columns))
    }

    static func frames(width: CGFloat, heights: [CGFloat]) -> [CGRect] {
        let columns = columnCount(for: width)
        let cellWidth = columnWidth(for: width)
        var result: [CGRect] = []
        var y: CGFloat = 0
        for start in stride(from: 0, to: heights.count, by: columns) {
            let end = min(start + columns, heights.count)
            let rowHeight = heights[start..<end].max() ?? 0
            for index in start..<end {
                result.append(CGRect(x: CGFloat(index - start) * (cellWidth + spacing), y: y, width: cellWidth, height: rowHeight))
            }
            y += rowHeight + spacing
        }
        return result
    }

    /// Decorative geometry derived from the same placed cell bounds as the grid.
    static func separatorSegments(width: CGFloat, frames: [CGRect]) -> [SidebarBoardSeparatorSegment] {
        let columns = columnCount(for: width)
        var result: [SidebarBoardSeparatorSegment] = []
        for start in stride(from: 0, to: frames.count, by: columns) {
            let first = frames[start]
            let end = min(start + columns, frames.count)
            let rowBottom = frames[start..<end].map(\.maxY).max() ?? first.maxY
            if columns == 2, end - start == 2, rowBottom - first.minY > 12 {
                let x = (first.maxX + frames[start + 1].minX) / 2
                result.append(SidebarBoardSeparatorSegment(start: CGPoint(x: x, y: first.minY + 6), end: CGPoint(x: x, y: rowBottom - 6)))
            }
            if end < frames.count, width > 16 {
                let y = (rowBottom + frames[end].minY) / 2
                result.append(SidebarBoardSeparatorSegment(start: CGPoint(x: 8, y: y), end: CGPoint(x: width - 8, y: y)))
            }
        }
        return result
    }
}

struct SidebarBoardSeparatorSegment: Equatable {
    let start: CGPoint
    let end: CGPoint
}

private struct SidebarBoardCellBoundsKey: PreferenceKey {
    static var defaultValue: [Int: Anchor<CGRect>] { [:] }

    static func reduce(value: inout [Int: Anchor<CGRect>], nextValue: () -> [Int: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

private struct SidebarBoardSeparators: Shape {
    let segments: [SidebarBoardSeparatorSegment]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        for segment in segments {
            path.move(to: segment.start)
            path.addLine(to: segment.end)
        }
        return path
    }
}

private struct SidebarBoardGridLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = SidebarBoardGridMetrics.resolvedWidth(proposal.width)
        let frames = measuredFrames(width: width, subviews: subviews)
        return CGSize(width: width, height: frames.last?.maxY ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, frame) in zip(subviews, measuredFrames(width: bounds.width, subviews: subviews)) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), anchor: .topLeading, proposal: ProposedViewSize(frame.size))
        }
    }

    private func measuredFrames(width: CGFloat, subviews: Subviews) -> [CGRect] {
        let cellWidth = SidebarBoardGridMetrics.columnWidth(for: width)
        let heights = subviews.map { $0.sizeThatFits(ProposedViewSize(width: cellWidth, height: nil)).height }
        return SidebarBoardGridMetrics.frames(width: width, heights: heights)
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
