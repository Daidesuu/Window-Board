import AppKit
import Foundation

struct AttachedWindowRecoveryRequest {
    let originalWindow: WindowInfo
    let savedReference: SavedWindowReference?
    let shouldTryMinimizedRestore: Bool
}

enum AttachedWindowRecoveryProgress: Equatable {
    case checkingAfterRestoreFailure
    case lookingForMatch(AttachedWindowRecoveryIssue)
}

enum AttachedWindowRecoveryResult {
    case restoredOriginal(position: CGPoint?)
    case alreadyConnected(position: CGPoint)
    case reconnected(window: WindowInfo, discoveredWindows: [WindowInfo])
    case notMatched(issue: AttachedWindowRecoveryIssue, discoveredWindows: [WindowInfo])
    case cancelled
}

enum AttachedFrontWindowResult {
    case matched(window: WindowInfo, position: CGPoint?, size: CGSize?)
    case notMatched(hadVisibleFrontWindow: Bool, candidateCount: Int)
    case cancelled
}

final class AttachedWindowRecoveryCoordinator: @unchecked Sendable {
    typealias ProgressHandler = @Sendable (AttachedWindowRecoveryProgress) async -> Void

    private let serviceFactory: @Sendable () -> any ContentWindowOperating
    private let maximumAttempts: Int
    private let shortDelayAttemptLimit: Int
    private let shortRetryDelay: Duration
    private let longRetryDelay: Duration
    private let restoreSettleDelay: Duration

    init(
        serviceFactory: @escaping @Sendable () -> any ContentWindowOperating,
        maximumAttempts: Int = 40,
        shortDelayAttemptLimit: Int = 12,
        shortRetryDelay: Duration = .milliseconds(35),
        longRetryDelay: Duration = .milliseconds(90),
        restoreSettleDelay: Duration = .milliseconds(120)
    ) {
        self.serviceFactory = serviceFactory
        self.maximumAttempts = maximumAttempts
        self.shortDelayAttemptLimit = shortDelayAttemptLimit
        self.shortRetryDelay = shortRetryDelay
        self.longRetryDelay = longRetryDelay
        self.restoreSettleDelay = restoreSettleDelay
    }

    func recover(
        _ request: AttachedWindowRecoveryRequest,
        onProgress: ProgressHandler = { _ in }
    ) async -> AttachedWindowRecoveryResult {
        let service = serviceFactory()
        let originalWindow = request.originalWindow

        if originalWindow.pid != 0, service.isMinimized(originalWindow) {
            do {
                try service.setMinimized(false, for: originalWindow)
                service.activateApplication(pid: originalWindow.pid)
                try? await Task.sleep(for: restoreSettleDelay)
                guard !Task.isCancelled else { return .cancelled }
                return .restoredOriginal(position: try? service.position(of: originalWindow))
            } catch {
                await onProgress(.checkingAfterRestoreFailure)
            }
        }

        if originalWindow.pid != 0,
           let livePosition = try? service.position(of: originalWindow) {
            service.activateApplication(pid: originalWindow.pid)
            return .alreadyConnected(position: livePosition)
        }

        if request.shouldTryMinimizedRestore {
            await onProgress(.checkingAfterRestoreFailure)
        }

        var latestWindows: [WindowInfo] = []
        var didReopen = false
        var didActivateApplication = false

        for attempt in 0..<maximumAttempts {
            guard !Task.isCancelled else { return .cancelled }

            if attempt == 0 {
                if let savedReference = request.savedReference {
                    didReopen = service.openSavedWindowReference(savedReference)
                    if !didReopen {
                        didActivateApplication = service.activateSavedApplication(savedReference)
                    }
                } else {
                    didReopen = service.openDocument(for: originalWindow)
                    if !didReopen {
                        didActivateApplication = service.activateOrOpenApplication(for: originalWindow)
                    }
                }

                if didReopen || didActivateApplication {
                    await onProgress(
                        .lookingForMatch(
                            AttachedWindowRecoveryResolver.failureIssue(
                                didReopen: didReopen,
                                didActivateApplication: didActivateApplication
                            )
                        )
                    )
                }
            }

            if attempt > 0 {
                let retryDelay = attempt < shortDelayAttemptLimit ? shortRetryDelay : longRetryDelay
                try? await Task.sleep(for: retryDelay)
            }

            guard !Task.isCancelled else { return .cancelled }
            latestWindows = request.savedReference == nil
                ? service.windows(matching: originalWindow)
                : service.listWindows()

            if let replacement = AttachedWindowRecoveryResolver.replacementWindow(
                savedReference: request.savedReference,
                originalWindow: originalWindow,
                candidates: latestWindows
            ) {
                if service.isMinimized(replacement) {
                    try? service.setMinimized(false, for: replacement)
                }
                return .reconnected(window: replacement, discoveredWindows: latestWindows)
            }
        }

        return .notMatched(
            issue: AttachedWindowRecoveryResolver.failureIssue(
                didReopen: didReopen,
                didActivateApplication: didActivateApplication
            ),
            discoveredWindows: latestWindows
        )
    }

    func findFrontWindow(
        application: NSRunningApplication?,
        expectedBundleIdentifier: String?,
        expectedAppName: String
    ) async -> AttachedFrontWindowResult {
        guard !Task.isCancelled else { return .cancelled }
        let service = serviceFactory()
        var candidates: [WindowInfo] = []
        let visibleFrontWindow = service.frontmostVisibleExternalWindow()

        if let visibleFrontWindow {
            candidates.append(visibleFrontWindow)
        }
        if let application {
            if let frontmostWindow = service.frontmostWindow(for: application) {
                candidates.append(frontmostWindow)
            }
            candidates.append(contentsOf: service.windows(for: application))
        }
        candidates.append(contentsOf: service.listWindows())

        guard !Task.isCancelled else { return .cancelled }
        var seenWindowIDs = Set<WindowInfo.ID>()
        let uniqueCandidates = candidates.filter { seenWindowIDs.insert($0.id).inserted }

        guard let replacement = WindowMatching.bestExpectedFrontWindow(
            in: uniqueCandidates,
            expectedBundleIdentifier: expectedBundleIdentifier,
            expectedAppName: expectedAppName
        ) else {
            return .notMatched(
                hadVisibleFrontWindow: visibleFrontWindow != nil,
                candidateCount: uniqueCandidates.count
            )
        }

        return .matched(
            window: replacement,
            position: (try? service.position(of: replacement)) ?? replacement.position,
            size: try? service.size(of: replacement)
        )
    }
}
