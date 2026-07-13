import CoreGraphics
import Foundation

enum WindowMatching {
    static func bestReplacement(for originalWindow: WindowInfo, in candidates: [WindowInfo]) -> WindowInfo? {
        let appCandidates = candidates.filter { candidate in
            if let originalBundleIdentifier = originalWindow.bundleIdentifier,
               let candidateBundleIdentifier = candidate.bundleIdentifier {
                return originalBundleIdentifier == candidateBundleIdentifier
            }

            return candidate.appName == originalWindow.appName
        }

        if let originalDocumentURL = originalWindow.documentURL,
           let documentMatch = appCandidates.first(where: { $0.documentURL == originalDocumentURL }) {
            return documentMatch
        }

        let trimmedTitle = originalWindow.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty,
           let titleMatch = appCandidates.first(where: {
               $0.title.trimmingCharacters(in: .whitespacesAndNewlines) == trimmedTitle
           }) {
            return titleMatch
        }

        return appCandidates.first
    }

    static func bestSavedWindow(
        for reference: SavedWindowReference,
        in candidates: [WindowInfo],
        excluding usedWindowIDs: Set<WindowInfo.ID>
    ) -> WindowInfo? {
        let appCandidates = candidates.filter { candidate in
            guard !usedWindowIDs.contains(candidate.id) else {
                return false
            }

            if let referenceBundleIdentifier = reference.bundleIdentifier,
               let candidateBundleIdentifier = candidate.bundleIdentifier {
                return referenceBundleIdentifier == candidateBundleIdentifier
            }

            return candidate.appName == reference.appName
        }

        if !reference.isVisualStudioCode,
           let referenceDocumentURL = reference.documentURL,
           let documentMatch = appCandidates.first(where: { $0.documentURL == referenceDocumentURL }) {
            return documentMatch
        }

        let trimmedTitle = reference.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty,
           let titleMatch = appCandidates.first(where: {
               $0.title.trimmingCharacters(in: .whitespacesAndNewlines) == trimmedTitle
           }) {
            return titleMatch
        }

        return appCandidates.first
    }

    static func appNamesMatch(_ lhs: String, _ rhs: String) -> Bool {
        let lhs = lhs.trimmingCharacters(in: .whitespacesAndNewlines)
        let rhs = rhs.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !lhs.isEmpty, !rhs.isEmpty else {
            return false
        }

        if lhs.localizedCaseInsensitiveCompare(rhs) == .orderedSame {
            return true
        }

        let lhsLowercased = lhs.localizedLowercase
        let rhsLowercased = rhs.localizedLowercase
        return lhsLowercased.contains(rhsLowercased) || rhsLowercased.contains(lhsLowercased)
    }

    static func matchesExpectedFrontWindow(
        _ window: WindowInfo,
        expectedBundleIdentifier: String?,
        expectedAppName: String
    ) -> Bool {
        if let expectedBundleIdentifier {
            guard let windowBundleIdentifier = window.bundleIdentifier else {
                return appNamesMatch(window.appName, expectedAppName)
            }

            return expectedBundleIdentifier == windowBundleIdentifier
        }

        return appNamesMatch(window.appName, expectedAppName)
    }

    static func bestExpectedFrontWindow(
        in candidates: [WindowInfo],
        expectedBundleIdentifier: String?,
        expectedAppName: String
    ) -> WindowInfo? {
        candidates.first {
            matchesExpectedFrontWindow(
                $0,
                expectedBundleIdentifier: expectedBundleIdentifier,
                expectedAppName: expectedAppName
            )
        }
    }

    static func matchesNeverMinimizeWindow(
        bundleIdentifier: String?,
        appName: String,
        title: String,
        documentURL: URL?,
        windowNumber: CGWindowID?,
        candidate: WindowInfo
    ) -> Bool {
        if let windowNumber,
           let candidateWindowNumber = candidate.windowNumber,
           let bundleIdentifier,
           let candidateBundleIdentifier = candidate.bundleIdentifier,
           bundleIdentifier == candidateBundleIdentifier,
           windowNumber == candidateWindowNumber {
            return true
        }

        if let documentURL,
           let candidateDocumentURL = candidate.documentURL,
           documentURL == candidateDocumentURL {
            return true
        }

        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidateTitle = candidate.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty, !candidateTitle.isEmpty, trimmedTitle == candidateTitle else {
            return false
        }

        if let bundleIdentifier,
           let candidateBundleIdentifier = candidate.bundleIdentifier {
            return bundleIdentifier == candidateBundleIdentifier
        }

        return appName == candidate.appName
    }
}
