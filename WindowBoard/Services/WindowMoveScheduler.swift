import Foundation

final class WindowMoveScheduler {
    static let shared = WindowMoveScheduler()

    private let queue = DispatchQueue(label: "WindowBoard.WindowMoveScheduler")
    private let animationQueue = DispatchQueue(label: "WindowBoard.WindowMoveScheduler.Animation")
    private let lock = NSLock()
    private let service = AccessibilityWindowService()

    private var pendingMoves: [WindowInfo.ID: PendingMove] = [:]
    private var animationTokens: [WindowInfo.ID: UUID] = [:]
    private var isProcessing = false

    private init() {}

    func scheduleMove(
        window: WindowInfo,
        to position: CGPoint,
        onComplete: (@MainActor () -> Void)? = nil,
        onFailure: @escaping @MainActor (Error) -> Void
    ) {
        lock.lock()
        pendingMoves[window.id] = PendingMove(
            window: window,
            position: position,
            onComplete: onComplete,
            onFailure: onFailure
        )
        let shouldStart = !isProcessing
        if shouldStart {
            isProcessing = true
        }
        lock.unlock()

        guard shouldStart else {
            return
        }

        queue.async { [weak self] in
            self?.processMoves()
        }
    }

    func scheduleAnimatedMove(
        window: WindowInfo,
        to position: CGPoint,
        duration: TimeInterval = 0.14,
        steps: Int = 5,
        onComplete: (@MainActor () -> Void)? = nil,
        onFailure: @escaping @MainActor (Error) -> Void
    ) {
        let token = UUID()

        lock.lock()
        animationTokens[window.id] = token
        pendingMoves.removeValue(forKey: window.id)
        lock.unlock()

        animationQueue.async { [weak self] in
            self?.processAnimatedMove(
                window: window,
                to: position,
                duration: duration,
                steps: steps,
                token: token,
                onComplete: onComplete,
                onFailure: onFailure
            )
        }
    }

    private func processMoves() {
        while true {
            lock.lock()
            guard let move = pendingMoves.values.first else {
                isProcessing = false
                lock.unlock()
                return
            }
            pendingMoves.removeValue(forKey: move.window.id)
            lock.unlock()

            do {
                try service.setPosition(move.position, for: move.window)
                Task { @MainActor in
                    move.onComplete?()
                }
            } catch {
                Task { @MainActor in
                    move.onFailure(error)
                }
            }
        }
    }

    private func processAnimatedMove(
        window: WindowInfo,
        to targetPosition: CGPoint,
        duration: TimeInterval,
        steps: Int,
        token: UUID,
        onComplete: (@MainActor () -> Void)?,
        onFailure: @escaping @MainActor (Error) -> Void
    ) {
        do {
            let startPosition = try service.position(of: window)
            let safeSteps = max(1, steps)
            let sleepInterval = max(0, duration / Double(safeSteps))

            for step in 1...safeSteps {
                guard isCurrentAnimation(token, for: window.id) else {
                    return
                }

                let progress = Double(step) / Double(safeSteps)
                let easedProgress = 1 - pow(1 - progress, 3)
                let nextPosition = CGPoint(
                    x: startPosition.x + (targetPosition.x - startPosition.x) * easedProgress,
                    y: startPosition.y + (targetPosition.y - startPosition.y) * easedProgress
                )

                try service.setPosition(nextPosition, for: window)
                Thread.sleep(forTimeInterval: sleepInterval)
            }

            clearAnimation(token, for: window.id)
            Task { @MainActor in
                onComplete?()
            }
        } catch {
            clearAnimation(token, for: window.id)
            Task { @MainActor in
                onFailure(error)
            }
        }
    }

    private func isCurrentAnimation(_ token: UUID, for id: WindowInfo.ID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return animationTokens[id] == token
    }

    private func clearAnimation(_ token: UUID, for id: WindowInfo.ID) {
        lock.lock()
        if animationTokens[id] == token {
            animationTokens.removeValue(forKey: id)
        }
        lock.unlock()
    }
}

private struct PendingMove {
    let window: WindowInfo
    let position: CGPoint
    let onComplete: (@MainActor () -> Void)?
    let onFailure: @MainActor (Error) -> Void
}
