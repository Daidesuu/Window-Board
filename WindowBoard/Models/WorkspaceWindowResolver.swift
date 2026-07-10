import ApplicationServices
import CoreGraphics
import Foundation

struct WorkspaceWindowMatch {
    let reference: SavedWindowReference
    let window: WindowInfo
}

struct WorkspaceWindowResolution {
    let matches: [WorkspaceWindowMatch]
    let unresolvedReferences: [SavedWindowReference]
    let loadedWindowIDs: [SavedWindowReference.ID: WindowInfo.ID]
    fileprivate let usedWindowIDs: Set<WindowInfo.ID>
}

enum WorkspaceWindowResolver {
    static func resolve(
        references: [SavedWindowReference],
        candidates: [WindowInfo],
        cachedWindowIDs: [SavedWindowReference.ID: WindowInfo.ID],
        previous: WorkspaceWindowResolution? = nil
    ) -> WorkspaceWindowResolution {
        var matches = previous?.matches ?? []
        var loadedWindowIDs = previous?.loadedWindowIDs ?? [:]
        var usedWindowIDs = previous?.usedWindowIDs ?? []
        var unresolvedReferences: [SavedWindowReference] = []

        for reference in references {
            guard let window = bestWindow(
                for: reference,
                cachedWindowID: cachedWindowIDs[reference.id],
                in: candidates,
                excluding: usedWindowIDs
            ) else {
                unresolvedReferences.append(reference)
                continue
            }

            matches.append(WorkspaceWindowMatch(reference: reference, window: window))
            loadedWindowIDs[reference.id] = window.id
            usedWindowIDs.insert(window.id)
        }

        return WorkspaceWindowResolution(
            matches: matches,
            unresolvedReferences: unresolvedReferences,
            loadedWindowIDs: loadedWindowIDs,
            usedWindowIDs: usedWindowIDs
        )
    }

    static func placeholderAttachments(
        for references: [SavedWindowReference],
        boardOrigin: CGPoint,
        useSavedOrigin: Bool
    ) -> [AttachedWindow] {
        references.map { placeholderAttachment(for: $0, boardOrigin: boardOrigin, useSavedOrigin: useSavedOrigin) }
    }

    static func orderedAttachments(
        references: [SavedWindowReference],
        resolvedAttachments: [AttachedWindow],
        boardOrigin: CGPoint,
        useSavedOrigin: Bool
    ) -> [AttachedWindow] {
        let attachmentsByID = Dictionary(uniqueKeysWithValues: resolvedAttachments.map { ($0.id, $0) })
        return references.map { reference in
            attachmentsByID[reference.id]
                ?? placeholderAttachment(for: reference, boardOrigin: boardOrigin, useSavedOrigin: useSavedOrigin)
        }
    }

    static func bestWindow(
        for reference: SavedWindowReference,
        cachedWindowID: WindowInfo.ID?,
        in candidates: [WindowInfo],
        excluding usedWindowIDs: Set<WindowInfo.ID>
    ) -> WindowInfo? {
        if let cachedWindowID,
           !usedWindowIDs.contains(cachedWindowID),
           let exactWindow = candidates.first(where: { $0.id == cachedWindowID }) {
            return exactWindow
        }

        return WindowMatching.bestSavedWindow(
            for: reference,
            in: candidates,
            excluding: usedWindowIDs
        )
    }

    private static func placeholderAttachment(
        for reference: SavedWindowReference,
        boardOrigin: CGPoint,
        useSavedOrigin: Bool
    ) -> AttachedWindow {
        let targetOrigin = reference.targetOrigin(from: boardOrigin, useSavedOrigin: useSavedOrigin)
        let placeholder = WindowInfo(
            id: "saved-placeholder-\(reference.id.uuidString)",
            appName: reference.appName,
            title: reference.title,
            pid: 0,
            bundleIdentifier: reference.bundleIdentifier,
            bundleURL: reference.bundleURL,
            documentURL: reference.documentURL,
            axWindow: AXUIElementCreateApplication(0),
            windowNumber: nil,
            position: nil
        )
        return AttachedWindow(
            attachmentID: reference.id,
            window: placeholder,
            savedReference: reference,
            lastBoardOrigin: boardOrigin,
            lastWindowOrigin: targetOrigin,
            lastAppliedOrigin: nil,
            pendingReleaseOrigin: nil
        )
    }
}
