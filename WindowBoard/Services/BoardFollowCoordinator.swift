import Foundation

enum BoardFollowMoveStyle {
    case immediate
    case animated
}

struct BoardFollowUpdate {
    let attachmentID: AttachedWindow.ID
    let boardOrigin: CGPoint
    let targetOrigin: CGPoint?
}

enum BoardFollowPlanner {
    static func updates(
        for boardOrigin: CGPoint,
        attachedWindows: [AttachedWindow],
        unavailableAttachmentIDs: Set<AttachedWindow.ID>
    ) -> [BoardFollowUpdate] {
        attachedWindows.map { attachedWindow in
            guard !unavailableAttachmentIDs.contains(attachedWindow.id) else {
                return BoardFollowUpdate(
                    attachmentID: attachedWindow.id,
                    boardOrigin: boardOrigin,
                    targetOrigin: nil
                )
            }

            let boardDelta = CGPoint(
                x: boardOrigin.x - attachedWindow.lastBoardOrigin.x,
                y: boardOrigin.y - attachedWindow.lastBoardOrigin.y
            )
            let targetOrigin = CGPoint(
                x: attachedWindow.lastWindowOrigin.x + boardDelta.x,
                y: attachedWindow.lastWindowOrigin.y - boardDelta.y
            )

            if let lastAppliedOrigin = attachedWindow.lastAppliedOrigin,
               abs(lastAppliedOrigin.x - targetOrigin.x) < 1,
               abs(lastAppliedOrigin.y - targetOrigin.y) < 1 {
                return BoardFollowUpdate(
                    attachmentID: attachedWindow.id,
                    boardOrigin: boardOrigin,
                    targetOrigin: nil
                )
            }

            return BoardFollowUpdate(
                attachmentID: attachedWindow.id,
                boardOrigin: boardOrigin,
                targetOrigin: targetOrigin
            )
        }
    }
}

@MainActor
final class BoardFollowCoordinator {
    private let releaseIdleDelay: TimeInterval
    private let autoFrontIdleDelay: TimeInterval
    private(set) var lastMoveDate = Date.distantPast
    private var pendingReleaseOrigin: CGPoint?
    private var pendingReleaseTask: Task<Void, Never>?
    private var isAutoFrontPending = false
    private var pendingAutoFrontTask: Task<Void, Never>?

    init(releaseIdleDelay: TimeInterval = 0.20, autoFrontIdleDelay: TimeInterval = 0.22) {
        self.releaseIdleDelay = releaseIdleDelay
        self.autoFrontIdleDelay = autoFrontIdleDelay
    }

    func recordMovement(
        to origin: CGPoint,
        mode: FollowMode,
        hasAttachedWindows: Bool,
        currentMode: @escaping @MainActor () -> FollowMode,
        applySmoothMove: @escaping @MainActor (CGPoint) -> Void,
        applyReleaseMove: @escaping @MainActor (CGPoint, BoardFollowMoveStyle) -> Void
    ) {
        lastMoveDate = Date()
        guard hasAttachedWindows else { return }

        switch mode {
        case .none:
            cancelRelease()
        case .smooth:
            applySmoothMove(origin)
        case .onRelease, .animatedRelease:
            pendingReleaseOrigin = origin
            scheduleRelease(currentMode: currentMode, applyReleaseMove: applyReleaseMove)
        }
    }

    func markAutoFrontPending(
        mode: AutoFrontMode,
        currentMode: @escaping @MainActor () -> AutoFrontMode,
        hasAttachedWindows: @escaping @MainActor () -> Bool,
        applyAutoFront: @escaping @MainActor () -> Void
    ) {
        guard mode != .off else { return }
        isAutoFrontPending = true
        pendingAutoFrontTask?.cancel()
        pendingAutoFrontTask = Task { @MainActor in
            while !Task.isCancelled {
                let remainingDelay = autoFrontIdleDelay - Date().timeIntervalSince(lastMoveDate)
                if remainingDelay > 0 {
                    try? await Task.sleep(for: .milliseconds(Int(ceil(remainingDelay * 1000))))
                    continue
                }

                guard currentMode() == .allAttached, hasAttachedWindows() else {
                    isAutoFrontPending = false
                    pendingAutoFrontTask = nil
                    return
                }

                isAutoFrontPending = false
                pendingAutoFrontTask = nil
                applyAutoFront()
                return
            }
        }
    }

    func isIdle(for delay: TimeInterval) -> Bool {
        Date().timeIntervalSince(lastMoveDate) > delay
    }

    func cancelRelease() {
        pendingReleaseOrigin = nil
        pendingReleaseTask?.cancel()
        pendingReleaseTask = nil
    }

    func cancelAll() {
        cancelRelease()
        isAutoFrontPending = false
        pendingAutoFrontTask?.cancel()
        pendingAutoFrontTask = nil
    }

    func cancelTasksForDisappearance() {
        pendingReleaseTask?.cancel()
        pendingReleaseTask = nil
        pendingAutoFrontTask?.cancel()
        pendingAutoFrontTask = nil
    }

    private func scheduleRelease(
        currentMode: @escaping @MainActor () -> FollowMode,
        applyReleaseMove: @escaping @MainActor (CGPoint, BoardFollowMoveStyle) -> Void
    ) {
        pendingReleaseTask?.cancel()
        pendingReleaseTask = Task { @MainActor in
            while !Task.isCancelled {
                let remainingDelay = releaseIdleDelay - Date().timeIntervalSince(lastMoveDate)
                if remainingDelay > 0 {
                    try? await Task.sleep(for: .milliseconds(Int(ceil(remainingDelay * 1000))))
                    continue
                }

                guard let origin = pendingReleaseOrigin else {
                    pendingReleaseTask = nil
                    return
                }

                let mode = currentMode()
                guard mode == .onRelease || mode == .animatedRelease else {
                    cancelRelease()
                    return
                }

                pendingReleaseOrigin = nil
                pendingReleaseTask = nil
                applyReleaseMove(origin, mode == .animatedRelease ? .animated : .immediate)
                return
            }
        }
    }
}
