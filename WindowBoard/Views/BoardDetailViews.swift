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
    let actions: WorkspaceDetailActions
    let recentlyAddedWindowID: AttachedWindow.ID?
    let workspaceTransitionToken: UUID?
    let detachingAttachedWindowIDs: Set<AttachedWindow.ID>
    let composition: ResolvedBoardComposition
    let sourceBoard: (AttachedWindow.ID) -> BoardCardSource?

    @State private var isRootDropTargeted = false
    @State private var feedback: BoardDropFeedback?
    @State private var feedbackTask: Task<Void, Never>?

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                BoardContentSection(title: "Current Board", subtitle: subtitle) {
                    VStack(alignment: .leading, spacing: 14) {
                        feedbackView
                        ForEach(composition.roots) { node in
                            hierarchyNode(node)
                        }
                    }
                    .padding(8)
                    .background(isRootDropTargeted ? Color.accentColor.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(isRootDropTargeted ? Color.accentColor.opacity(0.5) : Color.clear, style: StrokeStyle(lineWidth: 1.2, dash: [6, 5]))
                    }
                    .dropDestination(for: String.self) { items, _ in handleRootDrop(items) } isTargeted: { isTargeted in
                        withAnimation(.easeInOut(duration: 0.16)) { isRootDropTargeted = isTargeted }
                    }
                }
                .padding(24)
                .frame(maxWidth: 1120, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }

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

    private var subtitle: String {
        let count = composition.roots.count
        return count == 1 ? "1 root board" : "\(count) root boards"
    }

    @ViewBuilder
    private var feedbackView: some View {
        if isRootDropTargeted {
            Label("Drop to add a root board", systemImage: "rectangle.badge.plus")
                .font(.callout.weight(.medium)).foregroundStyle(Color.accentColor)
        } else if let feedback {
            Label(feedback.message, systemImage: feedback.systemImage)
                .font(.callout)
                .foregroundStyle(feedback.isError ? Color.secondary : Color.accentColor)
        }
    }

    private func hierarchyNode(_ node: BoardCompositionNode) -> some View {
        BoardHierarchyNodeView(
            node: node,
            primaryBoardID: primaryBoardID,
            attachedWindows: attachedWindows,
            stateForWindow: attachedState,
            recoveryIssue: recoveryIssue,
            canAttachFrontmost: canAttachFrontmost,
            actions: actions,
            recentlyAddedWindowID: recentlyAddedWindowID,
            workspaceTransitionToken: workspaceTransitionToken,
            detachingAttachedWindowIDs: detachingAttachedWindowIDs,
            sourceBoard: sourceBoard,
            reportResult: report
        )
    }

    private func handleRootDrop(_ items: [String]) -> Bool {
        guard let item = items.first, let boardID = DragPayload.boardID(from: item) else {
            actions.rejectBoardDrop()
            report(.invalid("Drag a board from the sidebar."))
            return false
        }
        report(actions.includeRootBoard(boardID).feedback)
        return true
    }

    private func report(_ value: BoardDropFeedback) {
        feedbackTask?.cancel()
        withAnimation(.easeInOut(duration: 0.18)) { feedback = value }
        feedbackTask = Task {
            try? await Task.sleep(for: .seconds(2.4))
            guard !Task.isCancelled else { return }
            await MainActor.run { withAnimation(.easeInOut(duration: 0.18)) { feedback = nil } }
        }
    }
}

private struct BoardHierarchyNodeView: View {
    let node: BoardCompositionNode
    let primaryBoardID: SavedWorkspace.ID?
    let attachedWindows: [AttachedWindow]
    let stateForWindow: (AttachedWindow) -> AttachedWindowDisplayState
    let recoveryIssue: (AttachedWindow.ID) -> AttachedWindowRecoveryIssue?
    let canAttachFrontmost: Bool
    let actions: WorkspaceDetailActions
    let recentlyAddedWindowID: AttachedWindow.ID?
    let workspaceTransitionToken: UUID?
    let detachingAttachedWindowIDs: Set<AttachedWindow.ID>
    let sourceBoard: (AttachedWindow.ID) -> BoardCardSource?
    let reportResult: (BoardDropFeedback) -> Void

    @State private var isExpanded = true
    @State private var isDropTargeted = false

    private var windows: [AttachedWindow] {
        let ids = Set(node.board.windows.map(\.id))
        return attachedWindows.filter { ids.contains($0.id) }
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 14) {
                PinnedWindowCardGrid(
                    attachedWindows: windows,
                    stateForWindow: stateForWindow,
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
                    sourceBoard: { _ in
                        BoardCardSource(
                            name: node.pathNames.joined(separator: " / "),
                            isPermanent: node.board.isDefault
                        )
                    },
                    includeBoard: includeChild,
                    rejectDrop: actions.rejectMainBoardDrop,
                    showsAddCard: node.board.id == primaryBoardID
                )

                ForEach(node.children) { child in
                    BoardHierarchyNodeView(
                        node: child,
                        primaryBoardID: primaryBoardID,
                        attachedWindows: attachedWindows,
                        stateForWindow: stateForWindow,
                        recoveryIssue: recoveryIssue,
                        canAttachFrontmost: canAttachFrontmost,
                        actions: actions,
                        recentlyAddedWindowID: recentlyAddedWindowID,
                        workspaceTransitionToken: workspaceTransitionToken,
                        detachingAttachedWindowIDs: detachingAttachedWindowIDs,
                        sourceBoard: sourceBoard,
                        reportResult: reportResult
                    )
                    .padding(.leading, 22)
                }
            }
            .padding(.top, 10)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: node.board.isDefault ? "pin.fill" : "rectangle.on.rectangle")
                    .foregroundStyle(node.board.isDefault ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(node.board.name).font(.headline).lineLimit(1)
                    if node.pathNames.count > 1 {
                        Text(node.pathNames.joined(separator: " / "))
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                if node.board.isDefault {
                    Text("Permanent").font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2).background(.quaternary, in: Capsule())
                }
                Spacer()
                Text("\(node.board.windows.count) windows · \(node.children.count) boards")
                    .font(.caption).foregroundStyle(.secondary)
                relationMenu
            }
        }
        .padding(10)
        .background(isDropTargeted ? Color.accentColor.opacity(0.09) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).stroke(isDropTargeted ? Color.accentColor.opacity(0.5) : Color.clear, lineWidth: 1) }
        .dropDestination(for: String.self) { items, _ in
            guard let item = items.first, let childID = DragPayload.boardID(from: item) else { return false }
            includeChild(childID)
            return true
        } isTargeted: { isDropTargeted = $0 }
        .help(node.pathNames.joined(separator: " / "))
    }

    @ViewBuilder
    private var relationMenu: some View {
        if node.path.count > 1 {
            Menu {
                Button("Remove from Parent", role: .destructive) {
                    actions.excludeChildBoard(node.board.id, node.path[node.path.count - 2])
                }
            } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton)
        } else if node.board.id != primaryBoardID {
            Button { actions.excludeRootBoard(node.board.id) } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .help("Remove root board")
        }
    }

    private func includeChild(_ childID: SavedWorkspace.ID) {
        reportResult(actions.includeChildBoard(childID, node.board.id).feedback)
    }
}

private enum BoardDropFeedback: Equatable {
    case success(String)
    case invalid(String)

    var message: String { switch self { case .success(let value), .invalid(let value): value } }
    var systemImage: String { switch self { case .success: "checkmark.circle"; case .invalid: "exclamationmark.circle" } }
    var isError: Bool { if case .invalid = self { true } else { false } }
}

private extension BoardCompositionMutationResult {
    var feedback: BoardDropFeedback {
        self == .inserted || self == .removed ? .success(userMessage) : .invalid(userMessage)
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
