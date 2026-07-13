import ApplicationServices
import XCTest
@testable import WindowBoard

@MainActor
final class AttachedWindowSnapshotCoordinatorTests: XCTestCase {
    func testSnapshotWaitsForIntervalBeforeFirstSample() async {
        let probe = SnapshotSamplerProbe()
        let fixture = makeSnapshotFixture()
        let coordinator = AttachedWindowSnapshotCoordinator(
            interval: .milliseconds(15),
            sampler: { requests in await probe.sample(requests) }
        )
        var consumedCount = 0

        coordinator.restart(
            activity: activeSnapshotActivity,
            requestProvider: { fixture.batch },
            consume: { _ in consumedCount += 1 }
        )

        try? await Task.sleep(for: .milliseconds(5))
        let callsBeforeInterval = await probe.callCount
        XCTAssertEqual(callsBeforeInterval, 0)
        try? await Task.sleep(for: .milliseconds(25))
        let callsAfterInterval = await probe.callCount
        XCTAssertGreaterThanOrEqual(callsAfterInterval, 1)
        XCTAssertGreaterThanOrEqual(consumedCount, 1)
        coordinator.stop()
    }

    func testInactiveSnapshotCoordinatorDoesNotSample() async {
        let probe = SnapshotSamplerProbe()
        let fixture = makeSnapshotFixture()
        let coordinator = AttachedWindowSnapshotCoordinator(
            interval: .milliseconds(5),
            sampler: { requests in await probe.sample(requests) }
        )

        coordinator.restart(
            activity: AttachedWindowSnapshotCoordinator.Activity(
                hasAttachments: true,
                isLoadingWorkspace: true,
                isApplyingWorkspaceWindows: false,
                isMinimizingUnattached: false,
                isRestoringMinimized: false
            ),
            requestProvider: { fixture.batch },
            consume: { _ in XCTFail("Inactive coordinator consumed a snapshot") }
        )

        try? await Task.sleep(for: .milliseconds(20))
        let callCount = await probe.callCount
        XCTAssertEqual(callCount, 0)
    }

    func testStopBeforeIntervalPreventsSample() async {
        let probe = SnapshotSamplerProbe()
        let fixture = makeSnapshotFixture()
        let coordinator = AttachedWindowSnapshotCoordinator(
            interval: .milliseconds(20),
            sampler: { requests in await probe.sample(requests) }
        )

        coordinator.restart(
            activity: activeSnapshotActivity,
            requestProvider: { fixture.batch },
            consume: { _ in XCTFail("Stopped coordinator consumed a snapshot") }
        )
        coordinator.stop()

        try? await Task.sleep(for: .milliseconds(30))
        let callCount = await probe.callCount
        XCTAssertEqual(callCount, 0)
    }

    func testRestartDiscardsResultFromPreviousGeneration() async {
        let probe = SnapshotSamplerProbe(firstCallDelay: .milliseconds(45))
        let fixture = makeSnapshotFixture()
        let coordinator = AttachedWindowSnapshotCoordinator(
            interval: .milliseconds(5),
            sampler: { requests in await probe.sample(requests) }
        )
        var consumedTitles: [String] = []

        coordinator.restart(
            activity: activeSnapshotActivity,
            requestProvider: { fixture.batch },
            consume: { result in
                consumedTitles.append(contentsOf: result.snapshots.compactMap(\.title))
            }
        )
        try? await Task.sleep(for: .milliseconds(15))
        coordinator.restart(
            activity: activeSnapshotActivity,
            requestProvider: { fixture.batch },
            consume: { result in
                consumedTitles.append(contentsOf: result.snapshots.compactMap(\.title))
            }
        )

        try? await Task.sleep(for: .milliseconds(65))
        coordinator.stop()

        XCTAssertFalse(consumedTitles.contains("sample-1"))
        XCTAssertTrue(consumedTitles.contains("sample-2"))
    }

    private var activeSnapshotActivity: AttachedWindowSnapshotCoordinator.Activity {
        AttachedWindowSnapshotCoordinator.Activity(
            hasAttachments: true,
            isLoadingWorkspace: false,
            isApplyingWorkspaceWindows: false,
            isMinimizingUnattached: false,
            isRestoringMinimized: false
        )
    }

    private func makeSnapshotFixture() -> (
        batch: AttachedWindowSnapshotBatch,
        attachmentID: AttachedWindow.ID
    ) {
        let attachmentID = UUID()
        let window = WindowInfo(
            id: UUID().uuidString,
            appName: "Editor",
            title: "Document",
            pid: 100,
            bundleIdentifier: "com.example.editor",
            bundleURL: nil,
            documentURL: nil,
            axWindow: AXUIElementCreateSystemWide(),
            windowNumber: 1,
            position: CGPoint(x: 10, y: 20)
        )
        return (
            AttachedWindowSnapshotBatch(
                workspaceID: UUID(),
                requests: [AttachedWindowSnapshotRequest(attachmentID: attachmentID, window: window)]
            ),
            attachmentID
        )
    }
}

private actor SnapshotSamplerProbe {
    private(set) var callCount = 0
    private let firstCallDelay: Duration?

    init(firstCallDelay: Duration? = nil) {
        self.firstCallDelay = firstCallDelay
    }

    func sample(_ requests: [AttachedWindowSnapshotRequest]) async -> [AttachedWindowSnapshot] {
        callCount += 1
        let call = callCount
        if call == 1, let firstCallDelay {
            try? await Task.sleep(for: firstCallDelay)
        }

        return requests.map {
            AttachedWindowSnapshot(
                attachmentID: $0.attachmentID,
                windowID: $0.window.id,
                title: "sample-\(call)",
                origin: $0.window.position,
                isMinimized: false
            )
        }
    }
}
