import ApplicationServices
import Foundation

/// Diagnostics deliberately contain no window title or document URL.
struct WindowInspectionIssue: Error, Equatable {
    enum Stage: Equatable {
        case accessibilityPermission
        case enumerateApplications
        case enumerateWindows
        case readRole
        case readPosition
        case readSize
        case readMinimized
        case writeMinimized
        case restoreMinimized
    }

    enum Failure: Equatable {
        case ax(AXError)
        case invalidValue
    }

    let stage: Stage
    let pid: pid_t?
    let windowID: String?
    let failure: Failure
}

struct WindowEnumerationReport {
    /// Completeness is relative to the supported application/normal-window filter,
    /// never a guarantee about all Spaces or every window on the system.
    enum Coverage: CaseIterable, Hashable {
        case complete
        case partial
        case failed
        case unverifiedLegacy
    }

    let windows: [WindowInfo]
    let coverage: Coverage
    let issues: [WindowInspectionIssue]
    let failedPIDs: Set<pid_t>
}

struct MinimizedObservation {
    enum Quality: Equatable {
        case diagnostic
        case legacy
    }

    /// Failure is an unknown state; callers must not replace it with normal false.
    let state: Result<Bool, WindowInspectionIssue>
    let quality: Quality
}
