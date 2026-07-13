import Foundation

struct AttachedWindowSnapshotRequest {
    let attachmentID: AttachedWindow.ID
    let window: WindowInfo
}

struct AttachedWindowSnapshot {
    let attachmentID: AttachedWindow.ID
    let windowID: WindowInfo.ID
    let title: String?
    let origin: CGPoint?
    let isMinimized: Bool
}

struct AttachedWindowSnapshotBatch {
    let workspaceID: SavedWorkspace.ID?
    let requests: [AttachedWindowSnapshotRequest]
}

struct AttachedWindowSnapshotBatchResult {
    let workspaceID: SavedWorkspace.ID?
    let snapshots: [AttachedWindowSnapshot]
}

@MainActor
final class AttachedWindowSnapshotCoordinator {
    struct Activity {
        let hasAttachments: Bool
        let isLoadingWorkspace: Bool
        let isApplyingWorkspaceWindows: Bool
        let isMinimizingUnattached: Bool
        let isRestoringMinimized: Bool

        var permitsSnapshots: Bool {
            hasAttachments &&
                !isLoadingWorkspace &&
                !isApplyingWorkspaceWindows &&
                !isMinimizingUnattached &&
                !isRestoringMinimized
        }
    }

    typealias Sampler = @Sendable ([AttachedWindowSnapshotRequest]) async -> [AttachedWindowSnapshot]

    private let interval: Duration
    private let sampler: Sampler
    private var loopTask: Task<Void, Never>?
    private var samplingTask: Task<[AttachedWindowSnapshot], Never>?
    private var revision = 0

    init(
        interval: Duration = .seconds(10),
        serviceFactory: @escaping @Sendable () -> any ContentWindowOperating
    ) {
        self.interval = interval
        sampler = { requests in
            let service = serviceFactory()
            var snapshots: [AttachedWindowSnapshot] = []
            snapshots.reserveCapacity(requests.count)

            for request in requests {
                guard !Task.isCancelled else {
                    return []
                }

                let origin = try? service.position(of: request.window)
                guard !Task.isCancelled else {
                    return []
                }

                let title = service.title(of: request.window)
                let isMinimized = service.isMinimized(request.window)
                snapshots.append(
                    AttachedWindowSnapshot(
                        attachmentID: request.attachmentID,
                        windowID: request.window.id,
                        title: title,
                        origin: origin,
                        isMinimized: isMinimized
                    )
                )
            }

            return snapshots
        }
    }

    init(interval: Duration, sampler: @escaping Sampler) {
        self.interval = interval
        self.sampler = sampler
    }

    func restart(
        activity: Activity,
        requestProvider: @escaping @MainActor () -> AttachedWindowSnapshotBatch?,
        consume: @escaping @MainActor (AttachedWindowSnapshotBatchResult) -> Void
    ) {
        stop()
        guard activity.permitsSnapshots else {
            return
        }

        let currentRevision = revision
        loopTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, currentRevision == revision else {
                    return
                }

                guard let batch = requestProvider(), !batch.requests.isEmpty else {
                    stop()
                    return
                }

                let sampler = self.sampler
                let task = Task.detached(priority: .utility) {
                    await sampler(batch.requests)
                }
                samplingTask = task
                let snapshots = await task.value

                guard !Task.isCancelled, currentRevision == revision else {
                    return
                }

                samplingTask = nil
                consume(
                    AttachedWindowSnapshotBatchResult(
                        workspaceID: batch.workspaceID,
                        snapshots: snapshots
                    )
                )
            }
        }
    }

    func stop() {
        revision += 1
        loopTask?.cancel()
        loopTask = nil
        samplingTask?.cancel()
        samplingTask = nil
    }
}
