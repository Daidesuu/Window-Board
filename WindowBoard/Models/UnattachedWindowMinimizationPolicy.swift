import Foundation

/// Value-only policy. The caller supplies the composed registration set.
enum UnattachedWindowMinimizationPolicy {
    static func classify(_ candidate: WindowInfo, protection: ProtectionSnapshot) -> CandidateClassification {
        if protection.records.contains(where: { record in
            let window = record.window
            if window.id == candidate.id { return true }
            if let number = window.windowNumber, let candidateNumber = candidate.windowNumber,
               window.pid == candidate.pid, number == candidateNumber { return true }
            guard window.pid == candidate.pid, window.appName == candidate.appName,
                  window.title == candidate.title, let origin = candidate.position else { return false }
            return abs(record.lastWindowOrigin.x - origin.x) < 3
                && abs(record.lastWindowOrigin.y - origin.y) < 3
        }) { return .registered }

        let protected = protection.records.contains { record in
            let window = record.window
            guard record.isAvailable, window.pid != 0, !record.isReconnecting else { return false }
            if let candidateBundle = candidate.bundleIdentifier, let bundle = window.bundleIdentifier {
                guard candidateBundle == bundle else { return false }
            } else {
                guard candidate.pid == window.pid || candidate.appName == window.appName else { return false }
            }
            guard !SavedWindowReference.isVisualStudioCode(bundleIdentifier: candidate.bundleIdentifier),
                  !SavedWindowReference.isVisualStudioCode(bundleIdentifier: window.bundleIdentifier) else { return false }
            if window.bundleIdentifier == "com.apple.Terminal" { return true }
            if candidate.windowNumber != nil, window.windowNumber != nil { return false }
            if candidate.documentURL != nil, window.documentURL != nil { return false }
            let title = candidate.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let registeredTitle = window.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return title.isEmpty || registeredTitle.isEmpty || title == registeredTitle
        }
        return protected ? .sameApplicationProtected : .target
    }

    static func mergeCandidates(report: WindowEnumerationReport, fallback: [WindowInfo]) -> [MinimizationCandidate] {
        var seen = Set<String>()
        var result = report.windows.compactMap { window -> MinimizationCandidate? in
            guard seen.insert(window.id).inserted else { return nil }
            return MinimizationCandidate(window: window, provenance: .fresh)
        }
        guard report.coverage != .complete else { return result }
        // Legacy reports cannot attest to any application's completeness. A
        // process-less issue likewise means the failed scope is system-wide.
        let allScopesUnknown = report.coverage == .unverifiedLegacy
            || report.issues.contains(where: { $0.pid == nil })
            || (report.coverage == .failed && report.failedPIDs.isEmpty)
        for window in fallback where allScopesUnknown || report.failedPIDs.contains(window.pid) {
            guard seen.insert(window.id).inserted else { continue }
            result.append(MinimizationCandidate(window: window, provenance: .fallback))
        }
        return result
    }
}
