import Foundation

enum AttachedWindowRecoveryIssue: Equatable {
    case openedButNotMatched
    case activatedButNotMatched
    case couldNotOpen

    var detail: String {
        switch self {
        case .openedButNotMatched:
            "App opened, window not matched"
        case .activatedButNotMatched:
            "App active, window not matched"
        case .couldNotOpen:
            "Could not open app"
        }
    }

    var canUseFrontWindow: Bool {
        switch self {
        case .openedButNotMatched, .activatedButNotMatched:
            true
        case .couldNotOpen:
            false
        }
    }

    var failureMessage: String {
        switch self {
        case .openedButNotMatched:
            "App opened, but WindowBoard could not identify the saved window."
        case .activatedButNotMatched:
            "App is active, but WindowBoard could not identify the saved window."
        case .couldNotOpen:
            "Could not open app. Open it manually, then try again."
        }
    }
}

enum AttachedWindowRecoveryResolver {
    static func replacementWindow(
        savedReference: SavedWindowReference?,
        originalWindow: WindowInfo,
        candidates: [WindowInfo]
    ) -> WindowInfo? {
        if let savedReference {
            return WindowMatching.bestSavedWindow(
                for: savedReference,
                in: candidates,
                excluding: []
            )
        }

        return WindowMatching.bestReplacement(for: originalWindow, in: candidates)
    }

    static func failureIssue(
        didReopen: Bool,
        didActivateApplication: Bool
    ) -> AttachedWindowRecoveryIssue {
        if didReopen {
            return .openedButNotMatched
        }
        if didActivateApplication {
            return .activatedButNotMatched
        }
        return .couldNotOpen
    }
}
