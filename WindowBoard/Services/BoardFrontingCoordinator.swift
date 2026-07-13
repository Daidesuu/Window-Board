import Foundation

@MainActor
final class BoardFrontingCoordinator {
    struct WorkspaceToken: Equatable {
        fileprivate let revision: Int
    }

    private let boardSelectionDelay: Duration
    private let boardClickDebounce: TimeInterval
    private let suppressionBaseDuration: TimeInterval
    private let suppressionPerWindowDuration: TimeInterval
    private let now: @MainActor () -> Date

    private var boardSelectionTask: Task<Void, Never>?
    private var lastBoardClickFrontDate = Date.distantPast
    private var frontingTask: Task<Void, Never>?
    private var frontingRevision = 0
    private var workspaceFrontingRevision = 0
    private var suppressExternalActivationUntil = Date.distantPast

    init(
        boardSelectionDelay: Duration = .milliseconds(180),
        boardClickDebounce: TimeInterval = 0.3,
        suppressionBaseDuration: TimeInterval = 0.8,
        suppressionPerWindowDuration: TimeInterval = 0.1,
        now: @escaping @MainActor () -> Date = Date.init
    ) {
        self.boardSelectionDelay = boardSelectionDelay
        self.boardClickDebounce = boardClickDebounce
        self.suppressionBaseDuration = suppressionBaseDuration
        self.suppressionPerWindowDuration = suppressionPerWindowDuration
        self.now = now
    }

    func scheduleBoardSelection(
        isEnabled: @escaping @MainActor () -> Bool,
        hasAvailableWindows: @escaping @MainActor () -> Bool,
        perform: @escaping @MainActor () -> Void
    ) {
        cancelBoardSelection()

        boardSelectionTask = Task { @MainActor in
            try? await Task.sleep(for: boardSelectionDelay)
            guard !Task.isCancelled else {
                return
            }

            boardSelectionTask = nil
            performBoardSelection(
                isEnabled: isEnabled,
                hasAvailableWindows: hasAvailableWindows,
                perform: perform
            )
        }
    }

    func performBoardSelection(
        isEnabled: @MainActor () -> Bool,
        hasAvailableWindows: @MainActor () -> Bool,
        perform: @MainActor () -> Void
    ) {
        let currentDate = now()
        guard isEnabled(),
              hasAvailableWindows(),
              currentDate.timeIntervalSince(lastBoardClickFrontDate) > boardClickDebounce else {
            return
        }

        lastBoardClickFrontDate = currentDate
        perform()
    }

    func cancelBoardSelection() {
        boardSelectionTask?.cancel()
        boardSelectionTask = nil
    }

    func frontAttachedWindows(
        count: Int,
        operation: @escaping @Sendable () async -> Void,
        completion: @escaping @MainActor () -> Void
    ) {
        cancelAttachedWindowFronting()
        let revision = frontingRevision
        suppressExternalActivation(
            for: suppressionBaseDuration + (Double(count) * suppressionPerWindowDuration)
        )

        frontingTask = Task.detached(priority: .utility) {
            await operation()

            await MainActor.run {
                guard !Task.isCancelled, revision == self.frontingRevision else {
                    return
                }

                completion()
                self.frontingTask = nil
            }
        }
    }

    func cancelAttachedWindowFronting() {
        frontingTask?.cancel()
        frontingTask = nil
        frontingRevision += 1
    }

    func suppressExternalActivation(for duration: TimeInterval) {
        suppressExternalActivationUntil = now().addingTimeInterval(duration)
    }

    func shouldAcceptExternalActivation(at date: Date? = nil) -> Bool {
        (date ?? now()) >= suppressExternalActivationUntil
    }

    func beginWorkspaceFronting(perform: @MainActor () -> Void) -> WorkspaceToken {
        workspaceFrontingRevision += 1
        let token = WorkspaceToken(revision: workspaceFrontingRevision)
        perform()
        return token
    }

    func endWorkspaceFronting(token: WorkspaceToken, perform: @MainActor () -> Void) {
        guard token.revision == workspaceFrontingRevision else {
            return
        }

        perform()
    }

    func cancelTasksForDisappearance() {
        cancelBoardSelection()
        cancelAttachedWindowFronting()
    }
}
