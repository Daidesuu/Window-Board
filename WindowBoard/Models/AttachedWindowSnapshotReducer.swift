import Foundation

struct AttachedWindowSnapshotState {
    var attachedWindows: [AttachedWindow]
    var unavailableAttachmentIDs: Set<AttachedWindow.ID>
    var reconnectingAttachmentIDs: Set<AttachedWindow.ID>
    var minimizedAttachmentIDs: Set<AttachedWindow.ID>
    var failureCounts: [AttachedWindow.ID: Int]
}

struct AttachedWindowSnapshotReduction {
    let state: AttachedWindowSnapshotState
    let availableAttachmentIDs: Set<AttachedWindow.ID>
    let didChangeAttachedWindows: Bool
    let shouldPersistWorkspace: Bool
}

enum AttachedWindowSnapshotReducer {
    static func reduce(
        state initialState: AttachedWindowSnapshotState,
        snapshots: [AttachedWindowSnapshot]
    ) -> AttachedWindowSnapshotReduction {
        var state = initialState
        var availableAttachmentIDs: Set<AttachedWindow.ID> = []
        var didChangeAttachedWindows = false
        var shouldPersistWorkspace = false

        for snapshot in snapshots {
            guard let index = state.attachedWindows.firstIndex(where: { $0.id == snapshot.attachmentID }) else {
                continue
            }

            guard state.attachedWindows[index].window.id == snapshot.windowID,
                  !state.reconnectingAttachmentIDs.contains(snapshot.attachmentID) else {
                continue
            }

            if let title = snapshot.title,
               title != state.attachedWindows[index].window.title {
                state.attachedWindows[index].window = state.attachedWindows[index].window.updatingTitle(title)
                didChangeAttachedWindows = true
                shouldPersistWorkspace = true
            }

            if snapshot.isMinimized {
                state.minimizedAttachmentIDs.insert(snapshot.attachmentID)
                state.failureCounts[snapshot.attachmentID] = nil
                state.unavailableAttachmentIDs.remove(snapshot.attachmentID)
                availableAttachmentIDs.insert(snapshot.attachmentID)
                continue
            }

            state.minimizedAttachmentIDs.remove(snapshot.attachmentID)

            if let origin = snapshot.origin {
                if !originsMatch(state.attachedWindows[index].lastWindowOrigin, origin) {
                    state.attachedWindows[index].lastWindowOrigin = origin
                    state.attachedWindows[index].lastAppliedOrigin = origin
                    state.attachedWindows[index].pendingReleaseOrigin = nil
                    didChangeAttachedWindows = true
                    shouldPersistWorkspace = true
                }
                state.failureCounts[snapshot.attachmentID] = nil
                state.unavailableAttachmentIDs.remove(snapshot.attachmentID)
                availableAttachmentIDs.insert(snapshot.attachmentID)
                continue
            }

            if state.attachedWindows[index].window.pid == 0 {
                state.unavailableAttachmentIDs.insert(snapshot.attachmentID)
                shouldPersistWorkspace = true
                continue
            }

            let failureCount = (state.failureCounts[snapshot.attachmentID] ?? 0) + 1
            state.failureCounts[snapshot.attachmentID] = failureCount
            if failureCount >= 3,
               !state.unavailableAttachmentIDs.contains(snapshot.attachmentID) {
                state.unavailableAttachmentIDs.insert(snapshot.attachmentID)
                shouldPersistWorkspace = true
            }
        }

        return AttachedWindowSnapshotReduction(
            state: state,
            availableAttachmentIDs: availableAttachmentIDs,
            didChangeAttachedWindows: didChangeAttachedWindows,
            shouldPersistWorkspace: shouldPersistWorkspace
        )
    }

    private static func originsMatch(_ lhs: CGPoint, _ rhs: CGPoint) -> Bool {
        abs(lhs.x - rhs.x) < 3 && abs(lhs.y - rhs.y) < 3
    }
}
