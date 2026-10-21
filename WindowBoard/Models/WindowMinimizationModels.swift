import CoreGraphics
import Foundation

// Runtime-only contracts. Session owns generations, execution slots and ledger
// storage; these values do not introduce persistence or another state owner.
struct MinimizationIntentID: Hashable, Comparable {
    let value: UInt64

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.value < rhs.value }
}

struct MinimizationResolution {
    let targetBoardID: SavedWorkspace.ID
    let composedReferenceIDs: Set<SavedWindowReference.ID>
    let report: WindowEnumerationReport?
    let switchRevision: Int
    let notBefore: ContinuousClock.Instant
}

struct MinimizationExecutionRequest {
    enum Kind: Equatable {
        case automatic
        case manual
        case reconcile
    }

    let intentID: MinimizationIntentID
    let operationID: UUID
    let kind: Kind
    let candidateSource: CandidateSource
}

struct CandidateSnapshot {
    enum Origin: Equatable {
        case switchResolution
        case minimization
        case legacyCache
    }

    let report: WindowEnumerationReport
    let origin: Origin
    let intentID: MinimizationIntentID
    let capturedAt: ContinuousClock.Instant
    /// Preserve the limited fallback separately so reuse neither loses known
    /// candidates nor promotes an incomplete cache to fresh/complete evidence.
    let fallback: [WindowInfo]

    init(
        report: WindowEnumerationReport,
        origin: Origin,
        intentID: MinimizationIntentID,
        capturedAt: ContinuousClock.Instant,
        fallback: [WindowInfo] = []
    ) {
        self.report = report
        self.origin = origin
        self.intentID = intentID
        self.capturedAt = capturedAt
        self.fallback = fallback
    }
}

enum CandidateSource {
    case reuse(CandidateSnapshot)
    case refresh(fallback: [WindowInfo])
    case known([WindowInfo])
}

struct MinimizationCandidate {
    enum Provenance: Equatable {
        case fresh
        case fallback
    }

    let window: WindowInfo
    let provenance: Provenance
}

struct LiveWindowIdentity: Hashable {
    let pid: pid_t
    let windowID: String
    let windowNumber: CGWindowID?

    init(pid: pid_t, windowID: String, windowNumber: CGWindowID?) {
        self.pid = pid
        self.windowID = windowID
        self.windowNumber = windowNumber
    }

    init(window: WindowInfo) {
        self.init(pid: window.pid, windowID: window.id, windowNumber: window.windowNumber)
    }
}

/// A value copy of everything the policy uses for one attachment. Availability
/// and reconnecting state are supplied by Session rather than inferred from AX.
struct ProtectionRecord {
    let attachmentID: UUID
    let window: WindowInfo
    let savedReference: SavedWindowReference?
    let isAvailable: Bool
    let isReconnecting: Bool
    let lastWindowOrigin: CGPoint

    var identity: LiveWindowIdentity { LiveWindowIdentity(window: window) }
}

/// Value equality detects changes relevant to classification and live identity,
/// including a reconnect that preserves the attachment ID.
struct ProtectionFingerprint: Equatable {
    struct Record: Equatable {
        let attachmentID: UUID
        let identity: LiveWindowIdentity
        let appName: String
        let title: String
        let bundleIdentifier: String?
        let documentURL: URL?
        let position: CGPoint?
        let lastWindowOrigin: CGPoint
        let savedReference: SavedWindowReference?
        let isAvailable: Bool
        let isReconnecting: Bool
    }

    let records: [Record]
}

struct ProtectionSnapshot {
    let records: [ProtectionRecord]

    var fingerprint: ProtectionFingerprint {
        ProtectionFingerprint(records: records.map {
            ProtectionFingerprint.Record(
                attachmentID: $0.attachmentID, identity: $0.identity,
                appName: $0.window.appName, title: $0.window.title,
                bundleIdentifier: $0.window.bundleIdentifier, documentURL: $0.window.documentURL,
                position: $0.window.position,
                lastWindowOrigin: $0.lastWindowOrigin, savedReference: $0.savedReference,
                isAvailable: $0.isAvailable, isReconnecting: $0.isReconnecting
            )
        })
    }
}

enum CandidateClassification: Equatable {
    case target
    case registered
    case sameApplicationProtected
}

enum WindowOperationKind: Equatable {
    case minimizeCandidate
    case restoreAttachment
}

enum WindowOperationSkipReason: Equatable {
    case registered
    case sameApplicationProtected
    case unavailable
    case reconnecting
    case identityChanged
    case noLongerRegistered
    case ledgerVersionChanged
}

enum WindowOperationStopReason: Equatable {
    case superseded
    case cancelled
}

struct StepProposal {
    let operationID: UUID
    let intentID: MinimizationIntentID
    let stepID: UInt64
    let kind: WindowOperationKind
    let candidateIdentity: LiveWindowIdentity
    let attachmentID: UUID?
    let expectedLedgerVersion: UInt64?
}

/// Authorization applies to exactly one step and one live window. Reauthorization
/// before a write must compare identity and classification with the read permit.
struct WindowOperationPermit {
    let operationID: UUID
    let intentID: MinimizationIntentID
    let stepID: UInt64
    let kind: WindowOperationKind
    let identity: LiveWindowIdentity
    let window: WindowInfo
    let attachmentID: UUID?
    let expectedLedgerVersion: UInt64?
    let protectionFingerprint: ProtectionFingerprint
    let classification: CandidateClassification
}

enum StepAuthorization {
    case perform(WindowOperationPermit)
    case skip(WindowOperationSkipReason)
    case stop(WindowOperationStopReason)
}

enum StepOutcome {
    /// A normal pre-read and successful AX write, not animation completion.
    case changed
    case alreadyDesired
    case readFailed(WindowInspectionIssue)
    case writeFailed(WindowInspectionIssue, observedAfter: MinimizedObservation?)
    case skipped(WindowOperationSkipReason)
    case superseded
}

/// A receipt is deduplicated by the execution and step, independently of intent.
struct StepReceiptID: Hashable {
    let operationID: UUID
    let stepID: UInt64
}

struct StepReceipt: Identifiable {
    let operationID: UUID
    let intentID: MinimizationIntentID
    let stepID: UInt64
    let identity: LiveWindowIdentity
    let window: WindowInfo
    let desiredMinimized: Bool
    let outcome: StepOutcome
    let expectedLedgerVersion: UInt64?

    var id: StepReceiptID { StepReceiptID(operationID: operationID, stepID: stepID) }
}

struct OperationSummary {
    // Classification counts describe the latest fingerprint, whereas operation
    // counts describe distinct receipts. Reclassification must not add writes.
    var candidateCount: Int = 0
    var registeredCount: Int = 0
    var sameApplicationProtectedCount: Int = 0
    var noOpCount: Int = 0
    var minimizedCount: Int = 0
    var restoredCount: Int = 0
    var readFailureCount: Int = 0
    var writeFailureCount: Int = 0
    var enumerationCount: Int = 0
    var issues: [WindowInspectionIssue] = []
    var interruptionReason: WindowOperationStopReason?
    var coverage: WindowEnumerationReport.Coverage = .unverifiedLegacy

    var failureCount: Int { readFailureCount + writeFailureCount }
}

struct MinimizationOperationResult {
    enum EndReason: Equatable {
        case completed
        case empty
        case failed
        case superseded
        case cancelled
    }

    let operationID: UUID
    let intentID: MinimizationIntentID
    let summary: OperationSummary
    let endReason: EndReason
    /// The fixed candidates discovered by this execution. Session may retain
    /// them for the same intent's deferred-recovery reconcile without relisting.
    let candidateSnapshot: CandidateSnapshot?

    init(
        operationID: UUID,
        intentID: MinimizationIntentID,
        summary: OperationSummary,
        endReason: EndReason,
        candidateSnapshot: CandidateSnapshot? = nil
    ) {
        self.operationID = operationID
        self.intentID = intentID
        self.summary = summary
        self.endReason = endReason
        self.candidateSnapshot = candidateSnapshot
    }
}

enum MinimizationProgress {
    case notRequested
    case waiting
    case preparing
    case running
    case completed(OperationSummary)
}

struct MinimizedLedgerEntry {
    let identity: LiveWindowIdentity
    let window: WindowInfo
    let entryVersion: UInt64
    let insertionOrder: UInt64
}

struct LedgerRestoreTarget {
    let identity: LiveWindowIdentity
    let window: WindowInfo
    let expectedEntryVersion: UInt64
}
