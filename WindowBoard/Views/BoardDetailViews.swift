import AppKit
import SwiftUI

struct WorkspaceDetailActions {
    let attachFromAddCard: () -> Void
    let clearRecentlyAddedWindowID: () -> Void
    let recoverAttached: (AttachedWindow) -> Void
    let useFrontWindowForAttached: (AttachedWindow) -> Void
    let updateAttached: (AttachedWindow.ID) -> Void
    let detachAttached: (AttachedWindow.ID) -> Void
    let bringForwardAttached: (AttachedWindow) -> Void
    let bringAndMoveAttachedBelowCard: (AttachedWindow, CGPoint) -> Void
    let moveAttachedWindow: (AttachedWindow.ID, SavedWorkspace.ID) -> BoardWindowMutationResult
    let reorderAttachedWindow: (AttachedWindow.ID, AttachedWindow.ID?) -> BoardWindowMutationResult
    let rejectMainBoardDrop: () -> Void
    let includeRootBoard: (SavedWorkspace.ID) -> BoardCompositionMutationResult
    let excludeRootBoard: (SavedWorkspace.ID) -> Void
    let includeChildBoard: (SavedWorkspace.ID, SavedWorkspace.ID) -> BoardCompositionMutationResult
    let excludeChildBoard: (SavedWorkspace.ID, SavedWorkspace.ID) -> Void
    let rejectBoardDrop: () -> Void
}

struct WorkspaceDetailView: View {
    let primaryBoardID: SavedWorkspace.ID?
    let attachedWindows: [AttachedWindow]
    let isLoadingWorkspace: Bool
    let isMinimizingUnattached: Bool
    let isRestoringMinimized: Bool
    let canAttachFrontmost: Bool
    let attachedState: (AttachedWindow) -> AttachedWindowDisplayState
    let recoveryIssue: (AttachedWindow.ID) -> AttachedWindowRecoveryIssue?
    let ownerBoardID: (AttachedWindow.ID) -> SavedWorkspace.ID?
    let actions: WorkspaceDetailActions
    let recentlyAddedWindowID: AttachedWindow.ID?
    let workspaceTransitionToken: UUID?
    let detachingAttachedWindowIDs: Set<AttachedWindow.ID>
    let composition: ResolvedBoardComposition
    let sourceBoard: (AttachedWindow.ID) -> BoardCardSource?

    @State private var feedback: BoardDropFeedback?
    @State private var feedbackTask: Task<Void, Never>?
    @State private var isDetachDropTargeted = false

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                CurrentBoardCanvasView(
                    primaryBoardID: primaryBoardID,
                    attachedWindows: attachedWindows,
                    canAttachFrontmost: canAttachFrontmost,
                    attachedState: attachedState,
                    recoveryIssue: recoveryIssue,
                    ownerBoardID: ownerBoardID,
                    actions: actions,
                    recentlyAddedWindowID: recentlyAddedWindowID,
                    workspaceTransitionToken: workspaceTransitionToken,
                    detachingAttachedWindowIDs: detachingAttachedWindowIDs,
                    composition: composition,
                    sourceBoard: sourceBoard,
                    feedback: feedback,
                    report: report
                )
                .padding(24)
                .frame(maxWidth: 1120, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }

            WindowDetachDropZone(isTargeted: isDetachDropTargeted)
                .padding(.horizontal, 24)
                .padding(.bottom, 62)
                .onDrop(
                    of: [WindowBoardDragKind.window.type.identifier],
                    delegate: WindowBoardDropDelegate(
                        acceptedKinds: [.window],
                        setTargeted: { isDetachDropTargeted = $0 },
                        perform: handleDetachDrop
                    )
                )

            ProcessingStatusOverlay(
                isLoadingWorkspace: isLoadingWorkspace,
                isMinimizingUnattached: isMinimizingUnattached,
                isRestoringMinimized: isRestoringMinimized
            )
            .padding(.bottom, 16)
        }
        .navigationTitle("")
        .onDisappear { feedbackTask?.cancel() }
    }

    private func report(_ value: BoardDropFeedback) {
        feedbackTask?.cancel()
        withAnimation(.easeInOut(duration: 0.18)) { feedback = value }
        feedbackTask = Task {
            try? await Task.sleep(for: .seconds(2.4))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.18)) { feedback = nil }
            }
        }
    }

    private func handleDetachDrop(_ payload: WindowBoardDragPayload, _: CGPoint) {
        guard case let .window(id) = payload,
              let attachment = attachedWindows.first(where: { $0.id == id }) else { return }

        guard canDetachFromDrop(attachment) else {
            report(.invalid("This window cannot be removed while it is updating."))
            return
        }

        actions.detachAttached(id)
    }

    private func canDetachFromDrop(_ attachment: AttachedWindow) -> Bool {
        guard !detachingAttachedWindowIDs.contains(attachment.id) else { return false }

        switch attachedState(attachment) {
        case .available, .minimized, .unavailable:
            return true
        case .resolving, .reconnecting:
            return false
        }
    }
}

private struct CurrentBoardCanvasView: View {
    let primaryBoardID: SavedWorkspace.ID?
    let attachedWindows: [AttachedWindow]
    let canAttachFrontmost: Bool
    let attachedState: (AttachedWindow) -> AttachedWindowDisplayState
    let recoveryIssue: (AttachedWindow.ID) -> AttachedWindowRecoveryIssue?
    let ownerBoardID: (AttachedWindow.ID) -> SavedWorkspace.ID?
    let actions: WorkspaceDetailActions
    let recentlyAddedWindowID: AttachedWindow.ID?
    let workspaceTransitionToken: UUID?
    let detachingAttachedWindowIDs: Set<AttachedWindow.ID>
    let composition: ResolvedBoardComposition
    let sourceBoard: (AttachedWindow.ID) -> BoardCardSource?
    let feedback: BoardDropFeedback?
    let report: (BoardDropFeedback) -> Void

    @State private var isRootDropTargeted = false

    private var nestedBoardCount: Int {
        max(composition.uniqueBoards.count - composition.roots.count, 0)
    }

    private var attachedWindowsByID: [AttachedWindow.ID: AttachedWindow] {
        Dictionary(uniqueKeysWithValues: attachedWindows.map { ($0.id, $0) })
    }

    private var subtitle: String {
        let rootText = "\(composition.roots.count) \(composition.roots.count == 1 ? "root board" : "root boards")"
        let windowText = "\(composition.uniqueWindowReferences.count) \(composition.uniqueWindowReferences.count == 1 ? "window" : "windows")"
        guard nestedBoardCount > 0 else { return "\(rootText) · \(windowText)" }
        return "\(rootText) · \(windowText) · \(nestedBoardCount) nested \(nestedBoardCount == 1 ? "board" : "boards")"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            BoardContentSection(title: "Current Board", subtitle: subtitle) {
                if let feedback {
                    Label(feedback.message, systemImage: feedback.systemImage)
                        .font(.callout)
                        .foregroundStyle(feedback.isError ? Color.secondary : Color.accentColor)
                }

                LazyVStack(alignment: .leading, spacing: 32) {
                    ForEach(composition.roots) { node in
                        RootBoardLaneView(
                            node: node,
                            primaryBoardID: primaryBoardID,
                            attachedWindowsByID: attachedWindowsByID,
                            canAttachFrontmost: canAttachFrontmost,
                            attachedState: attachedState,
                            recoveryIssue: recoveryIssue,
                            ownerBoardID: ownerBoardID,
                            actions: actions,
                            recentlyAddedWindowID: recentlyAddedWindowID,
                            workspaceTransitionToken: workspaceTransitionToken,
                            detachingAttachedWindowIDs: detachingAttachedWindowIDs,
                            sourceBoard: sourceBoard,
                            report: report
                        )
                    }
                }

                RootBoardDropZone(isTargeted: isRootDropTargeted)
                    .onDrop(
                        of: [WindowBoardDragKind.board.type.identifier],
                        delegate: WindowBoardDropDelegate(
                            acceptedKinds: [.board],
                            setTargeted: { isRootDropTargeted = $0 },
                            perform: handleRootDrop
                        )
                    )
            }
        }
    }

    private func handleRootDrop(_ payload: WindowBoardDragPayload, _: CGPoint) {
        guard case let .board(boardID) = payload else {
            actions.rejectBoardDrop()
            report(.invalid("Drop a Board here to add a root."))
            return
        }
        report(actions.includeRootBoard(boardID).feedback)
    }
}

private struct RootBoardLaneView: View {
    let node: BoardCompositionNode
    let primaryBoardID: SavedWorkspace.ID?
    let attachedWindowsByID: [AttachedWindow.ID: AttachedWindow]
    let canAttachFrontmost: Bool
    let attachedState: (AttachedWindow) -> AttachedWindowDisplayState
    let recoveryIssue: (AttachedWindow.ID) -> AttachedWindowRecoveryIssue?
    let ownerBoardID: (AttachedWindow.ID) -> SavedWorkspace.ID?
    let actions: WorkspaceDetailActions
    let recentlyAddedWindowID: AttachedWindow.ID?
    let workspaceTransitionToken: UUID?
    let detachingAttachedWindowIDs: Set<AttachedWindow.ID>
    let sourceBoard: (AttachedWindow.ID) -> BoardCardSource?
    let report: (BoardDropFeedback) -> Void

    var body: some View {
        BoardHierarchyNodeView(
            node: node,
            depth: 0,
            primaryBoardID: primaryBoardID,
            attachedWindowsByID: attachedWindowsByID,
            canAttachFrontmost: canAttachFrontmost,
            attachedState: attachedState,
            recoveryIssue: recoveryIssue,
            ownerBoardID: ownerBoardID,
            actions: actions,
            recentlyAddedWindowID: recentlyAddedWindowID,
            workspaceTransitionToken: workspaceTransitionToken,
            detachingAttachedWindowIDs: detachingAttachedWindowIDs,
            sourceBoard: sourceBoard,
            report: report
        )
    }
}

private struct BoardHierarchyNodeView: View {
    let node: BoardCompositionNode
    let depth: Int
    let primaryBoardID: SavedWorkspace.ID?
    let attachedWindowsByID: [AttachedWindow.ID: AttachedWindow]
    let canAttachFrontmost: Bool
    let attachedState: (AttachedWindow) -> AttachedWindowDisplayState
    let recoveryIssue: (AttachedWindow.ID) -> AttachedWindowRecoveryIssue?
    let ownerBoardID: (AttachedWindow.ID) -> SavedWorkspace.ID?
    let actions: WorkspaceDetailActions
    let recentlyAddedWindowID: AttachedWindow.ID?
    let workspaceTransitionToken: UUID?
    let detachingAttachedWindowIDs: Set<AttachedWindow.ID>
    let sourceBoard: (AttachedWindow.ID) -> BoardCardSource?
    let report: (BoardDropFeedback) -> Void

    @State private var isExpanded = true
    @State private var isBoardDropTargeted = false

    private var isRoot: Bool { depth == 0 }

    private var windows: [AttachedWindow] {
        node.board.windows.compactMap { attachedWindowsByID[$0.id] }
    }

    var body: some View {
        if isRoot {
            rootLane
        } else if depth <= 3 {
            HStack(alignment: .top, spacing: 8) {
                TreeBranchGuide()
                nodeContents
            }
        } else {
            nodeContents
        }
    }

    private var rootLane: some View {
        VStack(alignment: .leading, spacing: 16) {
            rootHeader

            if isExpanded {
                nodeBody
            }
        }
        .padding(.vertical, 2)
        .background(
            isDropTargeted ? Color.accentColor.opacity(0.07) : Color.clear,
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isDropTargeted ? Color.accentColor.opacity(0.45) : Color.clear, lineWidth: 1)
        }
        .onDrop(
            of: [
                WindowBoardDragKind.board.type.identifier,
                WindowBoardDragKind.window.type.identifier
            ],
            delegate: WindowBoardDropDelegate(
                acceptedKinds: [.board, .window],
                setTargeted: { isBoardDropTargeted = $0 },
                perform: handleDrop
            )
        )
    }

    private var nodeContents: some View {
        VStack(alignment: .leading, spacing: 12) {
            childHeader

            if isExpanded { nodeBody }
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 10)
        .background(
            isDropTargeted ? Color.accentColor.opacity(0.07) : Color.clear,
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isDropTargeted ? Color.accentColor.opacity(0.45) : Color.clear, lineWidth: 1)
        }
        .onDrop(
            of: [
                WindowBoardDragKind.board.type.identifier,
                WindowBoardDragKind.window.type.identifier
            ],
            delegate: WindowBoardDropDelegate(
                acceptedKinds: [.board, .window],
                setTargeted: { isBoardDropTargeted = $0 },
                perform: handleDrop
            )
        )
    }

    private var nodeBody: some View {
        VStack(alignment: .leading, spacing: 18) {
            PinnedWindowCardGrid(
                attachedWindows: windows,
                stateForWindow: attachedState,
                recoveryIssue: recoveryIssue,
                canAttachFrontmost: canAttachFrontmost,
                attachFromAddCard: actions.attachFromAddCard,
                recentlyAddedWindowID: recentlyAddedWindowID,
                clearRecentlyAddedWindowID: actions.clearRecentlyAddedWindowID,
                workspaceTransitionToken: workspaceTransitionToken,
                detachingAttachedWindowIDs: detachingAttachedWindowIDs,
                recover: actions.recoverAttached,
                useFrontWindow: actions.useFrontWindowForAttached,
                update: actions.updateAttached,
                detach: actions.detachAttached,
                bringForward: actions.bringForwardAttached,
                bringAndMoveBelowCard: actions.bringAndMoveAttachedBelowCard,
                sourceBoard: sourceBoard,
                includeBoard: includeChild,
                handleWindowDrop: handleWindowDrop,
                rejectDrop: actions.rejectMainBoardDrop,
                showsAddCard: node.board.id == primaryBoardID
            )

            if !node.children.isEmpty {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(node.children) { child in
                        BoardHierarchyNodeView(
                            node: child,
                            depth: depth + 1,
                            primaryBoardID: primaryBoardID,
                            attachedWindowsByID: attachedWindowsByID,
                            canAttachFrontmost: canAttachFrontmost,
                            attachedState: attachedState,
                            recoveryIssue: recoveryIssue,
                            ownerBoardID: ownerBoardID,
                            actions: actions,
                            recentlyAddedWindowID: recentlyAddedWindowID,
                            workspaceTransitionToken: workspaceTransitionToken,
                            detachingAttachedWindowIDs: detachingAttachedWindowIDs,
                            sourceBoard: sourceBoard,
                            report: report
                        )
                    }
                }
            }
        }
    }

    private var rootHeader: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) { isExpanded.toggle() }
            } label: {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption.weight(.semibold))
                    .frame(width: 14, height: 18)
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "Collapse board" : "Expand board")

            Image(systemName: node.board.isDefault ? "pin.fill" : "rectangle.on.rectangle")
                .foregroundStyle(node.board.isDefault ? Color.accentColor : Color.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(node.board.name)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(nodeMetadata)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if node.board.isDefault {
                Text("Permanent")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }

            Spacer(minLength: 8)

            relationMenu
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(alignment: .leading) {
            Capsule()
                .fill(node.board.isDefault ? Color.accentColor : Color.secondary.opacity(0.45))
                .frame(width: 3)
                .padding(.vertical, 8)
        }
        .contentShape(Rectangle())
        .help(node.pathNames.joined(separator: " / "))
        .accessibilityLabel("Root board \(node.board.name), \(nodeMetadata)")
    }

    private var childHeader: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) { isExpanded.toggle() }
            } label: {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption.weight(.semibold))
                    .frame(width: 14, height: 18)
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "Collapse board" : "Expand board")

            Image(systemName: node.board.isDefault ? "pin.fill" : "rectangle.on.rectangle")
                .foregroundStyle(node.board.isDefault ? Color.accentColor : Color.secondary)

            Text(node.board.name)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.tail)

            if node.board.isDefault {
                Text("Permanent")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }

            Spacer(minLength: 8)

            Text(nodeMetadata)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            relationMenu
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .help(node.pathNames.joined(separator: " / "))
        .accessibilityLabel("Child board \(node.board.name), \(nodeMetadata)")
    }

    private var nodeMetadata: String {
        "\(node.board.windows.count) windows · \(node.children.count) boards"
    }

    @ViewBuilder
    private var relationMenu: some View {
        if node.path.count > 1 {
            Menu {
                Button("Remove from Parent", role: .destructive) {
                    actions.excludeChildBoard(node.board.id, node.path[node.path.count - 2])
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
        } else if node.board.id != primaryBoardID {
            Button {
                actions.excludeRootBoard(node.board.id)
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Remove root board")
        }
    }

    private var isDropTargeted: Bool {
        isBoardDropTargeted
    }

    private func handleDrop(_ payload: WindowBoardDragPayload, _: CGPoint) {
        switch payload {
        case let .board(boardID):
            includeChild(boardID)
        case let .window(windowID):
            _ = handleWindowDrop(windowID, before: nil)
        }
    }

    private func includeChild(_ childID: SavedWorkspace.ID) {
        report(actions.includeChildBoard(childID, node.board.id).feedback)
    }

    private func handleWindowDrop(
        _ sourceID: AttachedWindow.ID,
        before destinationID: AttachedWindow.ID?
    ) -> BoardWindowMutationResult {
        let result: BoardWindowMutationResult
        if ownerBoardID(sourceID) == node.board.id {
            result = actions.reorderAttachedWindow(sourceID, destinationID)
        } else {
            result = actions.moveAttachedWindow(sourceID, node.board.id)
        }
        report(result.feedback)
        return result
    }
}

private struct TreeBranchGuide: View {
    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Color.secondary.opacity(0.28))
                .frame(width: 1, height: 17)
            HStack(spacing: 0) {
                Rectangle()
                    .fill(Color.secondary.opacity(0.28))
                    .frame(width: 11, height: 1)
                Circle()
                    .fill(Color.secondary.opacity(0.42))
                    .frame(width: 5, height: 5)
            }
            Spacer(minLength: 16)
            Rectangle()
                .fill(Color.secondary.opacity(0.28))
                .frame(width: 1)
        }
        .frame(width: 16)
        .accessibilityHidden(true)
    }
}

private struct RootBoardDropZone: View {
    let isTargeted: Bool

    var body: some View {
        Label(isTargeted ? "Drop to add a root board" : "Add root board", systemImage: "rectangle.badge.plus")
            .font(.caption.weight(.medium))
            .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary)
            .frame(maxWidth: .infinity, minHeight: isTargeted ? 52 : 28, alignment: .leading)
            .padding(.horizontal, isTargeted ? 14 : 2)
            .background(
                isTargeted ? Color.accentColor.opacity(0.08) : Color.clear,
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(
                        isTargeted ? Color.accentColor.opacity(0.48) : Color.clear,
                        style: StrokeStyle(lineWidth: 1, dash: [6, 5])
                    )
            }
            .padding(.top, 16)
            .animation(.easeInOut(duration: 0.16), value: isTargeted)
    }
}

private struct WindowDetachDropZone: View {
    let isTargeted: Bool

    var body: some View {
        Label("Remove from Board", systemImage: "trash")
            .font(.callout.weight(.semibold))
            .foregroundStyle(Color.red)
            .frame(maxWidth: .infinity, minHeight: 54)
            .padding(.horizontal, 14)
            .background(
                Color.red.opacity(isTargeted ? 0.10 : 0.001),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(
                        Color.red.opacity(isTargeted ? 0.60 : 0.001),
                        style: StrokeStyle(lineWidth: 1, dash: [6, 5])
                    )
            }
            .opacity(isTargeted ? 1 : 0.001)
            .contentShape(Rectangle())
            .accessibilityLabel("Remove window from board")
    }
}

private enum BoardDropFeedback: Equatable {
    case success(String)
    case invalid(String)

    var message: String {
        switch self {
        case let .success(value), let .invalid(value): value
        }
    }

    var systemImage: String {
        switch self {
        case .success: "checkmark.circle"
        case .invalid: "exclamationmark.circle"
        }
    }

    var isError: Bool {
        if case .invalid = self { return true }
        return false
    }
}

private extension BoardCompositionMutationResult {
    var feedback: BoardDropFeedback {
        self == .inserted || self == .removed ? .success(userMessage) : .invalid(userMessage)
    }
}

private extension BoardWindowMutationResult {
    var feedback: BoardDropFeedback {
        switch self {
        case .moved, .reordered:
            .success(userMessage)
        case .missingWindow, .missingBoard, .duplicate, .busy:
            .invalid(userMessage)
        }
    }
}

private struct BoardContentSection<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            content
        }
    }
}
