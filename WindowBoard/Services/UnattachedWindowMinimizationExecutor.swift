import Foundation

/// A single request's local work. Session retains all scheduling and ledger state.
struct UnattachedWindowMinimizationExecutor {
    // In Swift 5 language mode a nonisolated async method executes on the
    // generic executor, including when its caller is isolated to MainActor.
    nonisolated func run(
        request: MinimizationExecutionRequest,
        service: any WorkspaceWindowOperating,
        authorize: @escaping @MainActor (StepProposal) -> StepAuthorization,
        restorePlan: @escaping @MainActor () -> ProtectionSnapshot,
        record: @escaping @MainActor (StepReceipt) -> Void
    ) async -> MinimizationOperationResult {
        var summary = OperationSummary()
        if Task.isCancelled {
            summary.interruptionReason = .cancelled
            return MinimizationOperationResult(operationID: request.operationID, intentID: request.intentID, summary: summary, endReason: .cancelled)
        }
        let snapshot: CandidateSnapshot
        switch request.candidateSource {
        case .reuse(let existing):
            // Deferred recovery only reconciles the same intent's fixed set.
            // A stale reconcile must not discover or operate on new candidates.
            if request.kind == .reconcile && existing.intentID != request.intentID {
                summary.interruptionReason = .superseded
                return MinimizationOperationResult(operationID: request.operationID, intentID: request.intentID, summary: summary, endReason: .superseded)
            }
            if existing.intentID == request.intentID && (request.kind == .reconcile || (existing.origin != .legacyCache && existing.report.coverage != .unverifiedLegacy)) {
                snapshot = existing
            } else {
                let report = service.listWindowsReport()
                summary.enumerationCount = 1
                snapshot = CandidateSnapshot(report: report, origin: .minimization, intentID: request.intentID, capturedAt: .now, fallback: existing.report.windows + existing.fallback)
            }
        case .refresh(let fallback):
            let report = service.listWindowsReport()
            summary.enumerationCount = 1
            snapshot = CandidateSnapshot(report: report, origin: .minimization, intentID: request.intentID, capturedAt: .now, fallback: fallback)
        case .known(let windows):
            snapshot = CandidateSnapshot(report: WindowEnumerationReport(windows: windows, coverage: .unverifiedLegacy, issues: [], failedPIDs: []), origin: .legacyCache, intentID: request.intentID, capturedAt: .now)
        }
        summary.coverage = snapshot.report.coverage
        summary.issues = snapshot.report.issues
        let candidates = UnattachedWindowMinimizationPolicy.mergeCandidates(report: snapshot.report, fallback: snapshot.fallback)
        summary.candidateCount = candidates.count
        var nextStepID: UInt64 = 0

        func apply(_ receipt: StepReceipt) async {
            switch receipt.outcome {
            case .changed:
                if receipt.desiredMinimized { summary.minimizedCount += 1 } else { summary.restoredCount += 1 }
            case .alreadyDesired: summary.noOpCount += 1
            case .readFailed(let issue):
                summary.readFailureCount += 1
                summary.issues.append(issue)
            case .writeFailed(let issue, _):
                summary.writeFailureCount += 1
                summary.issues.append(issue)
            case .skipped, .superseded: break
            }
            await record(receipt)
        }

        func operate(_ window: WindowInfo, kind: WindowOperationKind, attachmentID: UUID?) async {
            while true {
                if Task.isCancelled {
                    summary.interruptionReason = .cancelled
                    return
                }
                nextStepID += 1
                let proposal = StepProposal(operationID: request.operationID, intentID: request.intentID, stepID: nextStepID, kind: kind, candidateIdentity: LiveWindowIdentity(window: window), candidateWindow: window, attachmentID: attachmentID, expectedLedgerVersion: nil)
                let desired = kind == .minimizeCandidate
                let permit: WindowOperationPermit
                switch await authorize(proposal) {
                case .perform(let value): permit = value
                case .skip(let reason):
                    await apply(StepReceipt(operationID: request.operationID, intentID: request.intentID, stepID: proposal.stepID, identity: proposal.candidateIdentity, window: window, desiredMinimized: desired, outcome: .skipped(reason), expectedLedgerVersion: nil))
                    return
                case .stop(let reason):
                    summary.interruptionReason = reason
                    return
                }
                // Do not allow a malformed authorization to redirect an operation
                // or pair a receipt's identity with a different service window.
                guard proposal.hasMatchingCandidateIdentity,
                      permit.operationID == proposal.operationID,
                      permit.intentID == proposal.intentID,
                      permit.stepID == proposal.stepID,
                      permit.kind == proposal.kind,
                      permit.attachmentID == proposal.attachmentID,
                      permit.identity == proposal.candidateIdentity,
                      permit.window.axWindow === proposal.candidateWindow.axWindow,
                      permit.identity == LiveWindowIdentity(window: permit.window) else {
                    await apply(StepReceipt(operationID: request.operationID, intentID: request.intentID, stepID: proposal.stepID, identity: proposal.candidateIdentity, window: window, desiredMinimized: desired, outcome: .skipped(.identityChanged), expectedLedgerVersion: proposal.expectedLedgerVersion))
                    return
                }
                if kind == .minimizeCandidate && permit.classification != .target {
                    let reason: WindowOperationSkipReason = permit.classification == .registered ? .registered : .sameApplicationProtected
                    await apply(StepReceipt(operationID: request.operationID, intentID: request.intentID, stepID: proposal.stepID, identity: permit.identity, window: permit.window, desiredMinimized: desired, outcome: .skipped(reason), expectedLedgerVersion: permit.expectedLedgerVersion))
                    return
                }
                if Task.isCancelled {
                    summary.interruptionReason = .cancelled
                    return
                }
                let observation = service.minimizedObservation(of: permit.window)
                let outcome: StepOutcome
                switch observation.state {
                case .failure(let issue): outcome = .readFailed(issue)
                case .success(let minimized) where minimized == desired: outcome = .alreadyDesired
                case .success:
                    do {
                        if Task.isCancelled {
                            summary.interruptionReason = .cancelled
                            return
                        }
                        let writeProposal = StepProposal(operationID: proposal.operationID, intentID: proposal.intentID, stepID: proposal.stepID, kind: proposal.kind, candidateIdentity: permit.identity, candidateWindow: permit.window, attachmentID: permit.attachmentID, expectedLedgerVersion: permit.expectedLedgerVersion)
                        switch await authorize(writeProposal) {
                        case .stop(let reason):
                            summary.interruptionReason = reason
                            return
                        case .skip(let reason):
                            await apply(StepReceipt(operationID: request.operationID, intentID: request.intentID, stepID: proposal.stepID, identity: permit.identity, window: permit.window, desiredMinimized: desired, outcome: .skipped(reason), expectedLedgerVersion: permit.expectedLedgerVersion))
                            return
                        case .perform(let current):
                            let identityMatches = current.operationID == permit.operationID && current.intentID == permit.intentID && current.stepID == permit.stepID && current.kind == permit.kind && current.attachmentID == permit.attachmentID && current.identity == permit.identity && current.identity == LiveWindowIdentity(window: current.window) && current.window.axWindow === permit.window.axWindow
                            let reason: WindowOperationSkipReason?
                            if !identityMatches { reason = .identityChanged }
                            else if current.expectedLedgerVersion != permit.expectedLedgerVersion { reason = .ledgerVersionChanged }
                            else if current.classification != permit.classification {
                                reason = current.classification == .registered ? .registered : current.classification == .sameApplicationProtected ? .sameApplicationProtected : .identityChanged
                            } else { reason = nil }
                            if reason == .ledgerVersionChanged {
                                // Discard the old observation and obtain a fresh read
                                // permit. No write is paired with the old ledger entry.
                                continue
                            }
                            if let reason {
                                await apply(StepReceipt(operationID: request.operationID, intentID: request.intentID, stepID: proposal.stepID, identity: permit.identity, window: permit.window, desiredMinimized: desired, outcome: .skipped(reason), expectedLedgerVersion: permit.expectedLedgerVersion))
                                return
                            }
                        }
                        if Task.isCancelled {
                            summary.interruptionReason = .cancelled
                            return
                        }
                    }
                    do {
                        try service.setMinimized(desired, for: permit.window)
                        outcome = .changed
                    } catch {
                        let issue: WindowInspectionIssue
                        if let inspection = error as? WindowInspectionIssue {
                            issue = inspection
                        } else if case let WindowBoardAXError.operationFailed(_, axError) = error {
                            issue = WindowInspectionIssue(stage: desired ? .writeMinimized : .restoreMinimized, pid: permit.window.pid, windowID: permit.window.id, failure: .ax(axError))
                        } else {
                            issue = WindowInspectionIssue(stage: desired ? .writeMinimized : .restoreMinimized, pid: permit.window.pid, windowID: permit.window.id, failure: .invalidValue)
                        }
                        // A failed restore may still have reached normal state;
                        // preserve that observation for version-aware ledger updates.
                        var observedAfter: MinimizedObservation?
                        if !desired && !Task.isCancelled {
                            let canRead: Bool
                            let readProposal = StepProposal(operationID: permit.operationID, intentID: permit.intentID, stepID: permit.stepID, kind: permit.kind, candidateIdentity: permit.identity, candidateWindow: permit.window, attachmentID: permit.attachmentID, expectedLedgerVersion: permit.expectedLedgerVersion)
                            switch await authorize(readProposal) {
                            case .stop(let reason):
                                summary.interruptionReason = reason
                                canRead = false
                            case .skip:
                                canRead = false
                            case .perform(let current):
                                canRead = current.operationID == permit.operationID && current.intentID == permit.intentID && current.stepID == permit.stepID && current.kind == permit.kind && current.attachmentID == permit.attachmentID && current.identity == permit.identity && current.identity == LiveWindowIdentity(window: current.window) && current.window.axWindow === permit.window.axWindow && current.expectedLedgerVersion == permit.expectedLedgerVersion && current.classification == permit.classification
                            }
                            if canRead && !Task.isCancelled {
                                observedAfter = service.minimizedObservation(of: permit.window)
                            }
                        }
                        outcome = .writeFailed(issue, observedAfter: observedAfter)
                    }
                }
                await apply(StepReceipt(operationID: request.operationID, intentID: request.intentID, stepID: proposal.stepID, identity: permit.identity, window: permit.window, desiredMinimized: desired, outcome: outcome, expectedLedgerVersion: permit.expectedLedgerVersion))
                return
            }
        }

        let protection = await restorePlan()
        for candidate in candidates {
            switch UnattachedWindowMinimizationPolicy.classify(candidate.window, protection: protection) {
            case .registered: summary.registeredCount += 1
            case .sameApplicationProtected: summary.sameApplicationProtectedCount += 1
            case .target: await operate(candidate.window, kind: .minimizeCandidate, attachmentID: nil)
            }
            if summary.interruptionReason != nil { break }
        }
        if summary.interruptionReason == nil {
            let current = await restorePlan()
            var restoredIdentities = Set<LiveWindowIdentity>()
            for attachment in current.records where attachment.isAvailable && !attachment.isReconnecting {
                guard restoredIdentities.insert(attachment.identity).inserted else { continue }
                await operate(attachment.window, kind: .restoreAttachment, attachmentID: attachment.attachmentID)
                if summary.interruptionReason != nil { break }
            }
        }
        if Task.isCancelled { summary.interruptionReason = .cancelled }
        let endReason: MinimizationOperationResult.EndReason
        if let interruption = summary.interruptionReason { endReason = interruption == .cancelled ? .cancelled : .superseded }
        else if summary.failureCount > 0 || snapshot.report.coverage == .failed { endReason = .failed }
        else if candidates.isEmpty && protection.records.isEmpty { endReason = .empty }
        else { endReason = .completed }
        return MinimizationOperationResult(operationID: request.operationID, intentID: request.intentID, summary: summary, endReason: endReason, candidateSnapshot: snapshot)
    }
}
