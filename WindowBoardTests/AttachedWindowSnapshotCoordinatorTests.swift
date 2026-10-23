import ApplicationServices
import XCTest
@testable import WindowBoard

@MainActor
final class AttachedWindowSnapshotCoordinatorTests: XCTestCase {
    func testSnapshotWaitsForIntervalBeforeFirstSample() async {
        let probe = SnapshotSamplerProbe()
        let fixture = makeSnapshotFixture()
        let interval: Duration = .milliseconds(15)
        let consumed = expectation(description: "First interval snapshot consumed")
        let coordinator = AttachedWindowSnapshotCoordinator(
            interval: interval,
            sampler: { requests in await probe.sample(requests) }
        )
        let startedAt = ContinuousClock.now
        coordinator.restart(
            activity: activeSnapshotActivity,
            requestProvider: { fixture.batch },
            consume: { _ in
                consumed.fulfill()
                coordinator.stop()
            }
        )

        await fulfillment(of: [consumed], timeout: 2)
        coordinator.stop()
        let firstSampleAt = await probe.firstSampleAt
        guard let firstSampleAt else {
            XCTFail("Expected a first sample before consumption")
            return
        }
        XCTAssertGreaterThanOrEqual(startedAt.duration(to: firstSampleAt), interval)
        let callCount = await probe.callCount
        XCTAssertEqual(callCount, 1)
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
        let firstStarted = expectation(description: "Old generation sampler entered")
        let firstReturned = expectation(description: "Old generation sampler returned")
        let latestConsumed = expectation(description: "New generation snapshot consumed")
        let gate = SnapshotRestartGate()
        let fixture = makeSnapshotFixture()
        let coordinator = AttachedWindowSnapshotCoordinator(
            interval: .milliseconds(5),
            sampler: { requests in
                let call = await gate.beginCall()
                if call == 1 {
                    firstStarted.fulfill()
                    // A real synchronous AX call can finish despite cancellation.
                    await gate.waitForRelease()
                    firstReturned.fulfill()
                }
                return requests.map {
                    AttachedWindowSnapshot(attachmentID: $0.attachmentID,
                        windowID: $0.window.id, title: "sample-\(call)",
                        origin: $0.window.position, isMinimized: false)
                }
            }
        )
        var consumedTitles: [String] = []
        coordinator.restart(activity: activeSnapshotActivity,
            requestProvider: { fixture.batch }, consume: { _ in
                XCTFail("Old generation consumed after restart")
            })
        await fulfillment(of: [firstStarted], timeout: 1)
        coordinator.restart(activity: activeSnapshotActivity,
            requestProvider: { fixture.batch }, consume: { result in
                consumedTitles.append(contentsOf: result.snapshots.compactMap(\.title))
                latestConsumed.fulfill()
                coordinator.stop()
            })
        await gate.release()
        await fulfillment(of: [firstReturned, latestConsumed], timeout: 1)
        coordinator.stop()
        XCTAssertFalse(consumedTitles.contains("sample-1"))
        XCTAssertTrue(consumedTitles.contains("sample-2"))
    }

    func testReducerUpdatesTitleAndOriginAndRequestsPersistence() {
        let fixture = makeReducerFixture()
        let newOrigin = CGPoint(x: 80, y: 90)
        let reduction = AttachedWindowSnapshotReducer.reduce(
            state: fixture.state,
            snapshots: [fixture.snapshot(title: "Renamed", origin: newOrigin)]
        )

        XCTAssertEqual(reduction.state.attachedWindows[0].window.title, "Renamed")
        XCTAssertEqual(reduction.state.attachedWindows[0].lastWindowOrigin, newOrigin)
        XCTAssertEqual(reduction.state.attachedWindows[0].lastAppliedOrigin, newOrigin)
        XCTAssertNil(reduction.state.attachedWindows[0].pendingReleaseOrigin)
        XCTAssertTrue(reduction.didChangeAttachedWindows)
        XCTAssertTrue(reduction.shouldPersistWorkspace)
    }

    func testReducerDoesNotPersistForEquivalentOriginAndTitle() {
        let fixture = makeReducerFixture()
        let reduction = AttachedWindowSnapshotReducer.reduce(
            state: fixture.state,
            snapshots: [fixture.snapshot(title: "Document", origin: CGPoint(x: 11, y: 21))]
        )

        XCTAssertFalse(reduction.didChangeAttachedWindows)
        XCTAssertFalse(reduction.shouldPersistWorkspace)
    }

    func testReducerTreatsMinimizedWindowAsAvailableWithoutPosition() {
        let fixture = makeReducerFixture(
            unavailable: true,
            failureCount: 2
        )
        let reduction = AttachedWindowSnapshotReducer.reduce(
            state: fixture.state,
            snapshots: [fixture.snapshot(origin: nil, isMinimized: true)]
        )

        XCTAssertTrue(reduction.state.minimizedAttachmentIDs.contains(fixture.attachmentID))
        XCTAssertFalse(reduction.state.unavailableAttachmentIDs.contains(fixture.attachmentID))
        XCTAssertNil(reduction.state.failureCounts[fixture.attachmentID])
        XCTAssertTrue(reduction.availableAttachmentIDs.contains(fixture.attachmentID))
        XCTAssertFalse(reduction.shouldPersistWorkspace)
    }

    func testReducerMarksWindowUnavailableAfterThirdFailure() {
        let fixture = makeReducerFixture(failureCount: 2)
        let reduction = AttachedWindowSnapshotReducer.reduce(
            state: fixture.state,
            snapshots: [fixture.snapshot(origin: nil)]
        )

        XCTAssertEqual(reduction.state.failureCounts[fixture.attachmentID], 3)
        XCTAssertTrue(reduction.state.unavailableAttachmentIDs.contains(fixture.attachmentID))
        XCTAssertTrue(reduction.shouldPersistWorkspace)
    }

    func testReducerSuccessResetsFailureAndUnavailableState() {
        let fixture = makeReducerFixture(unavailable: true, failureCount: 2)
        let reduction = AttachedWindowSnapshotReducer.reduce(
            state: fixture.state,
            snapshots: [fixture.snapshot(origin: CGPoint(x: 10, y: 20))]
        )

        XCTAssertNil(reduction.state.failureCounts[fixture.attachmentID])
        XCTAssertFalse(reduction.state.unavailableAttachmentIDs.contains(fixture.attachmentID))
        XCTAssertTrue(reduction.availableAttachmentIDs.contains(fixture.attachmentID))
    }

    func testReducerIgnoresReconnectingAndStaleWindows() {
        let reconnectingFixture = makeReducerFixture(reconnecting: true)
        let reconnectingReduction = AttachedWindowSnapshotReducer.reduce(
            state: reconnectingFixture.state,
            snapshots: [reconnectingFixture.snapshot(title: "Ignored", origin: CGPoint(x: 90, y: 90))]
        )
        XCTAssertEqual(reconnectingReduction.state.attachedWindows[0].window.title, "Document")
        XCTAssertFalse(reconnectingReduction.shouldPersistWorkspace)

        let staleFixture = makeReducerFixture()
        let staleSnapshot = AttachedWindowSnapshot(
            attachmentID: staleFixture.attachmentID,
            windowID: "different-window",
            title: "Ignored",
            origin: CGPoint(x: 90, y: 90),
            isMinimized: false
        )
        let staleReduction = AttachedWindowSnapshotReducer.reduce(
            state: staleFixture.state,
            snapshots: [staleSnapshot]
        )
        XCTAssertEqual(staleReduction.state.attachedWindows[0].window.title, "Document")
        XCTAssertFalse(staleReduction.shouldPersistWorkspace)
    }

    func testReducerMarksPlaceholderUnavailableImmediately() {
        let fixture = makeReducerFixture(pid: 0)
        let reduction = AttachedWindowSnapshotReducer.reduce(
            state: fixture.state,
            snapshots: [fixture.snapshot(origin: nil)]
        )

        XCTAssertTrue(reduction.state.unavailableAttachmentIDs.contains(fixture.attachmentID))
        XCTAssertNil(reduction.state.failureCounts[fixture.attachmentID])
        XCTAssertTrue(reduction.shouldPersistWorkspace)
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

    private func makeReducerFixture(
        pid: pid_t = 100,
        unavailable: Bool = false,
        reconnecting: Bool = false,
        failureCount: Int? = nil
    ) -> ReducerFixture {
        let attachmentID = UUID()
        let window = WindowInfo(
            id: UUID().uuidString,
            appName: "Editor",
            title: "Document",
            pid: pid,
            bundleIdentifier: "com.example.editor",
            bundleURL: nil,
            documentURL: nil,
            axWindow: AXUIElementCreateSystemWide(),
            windowNumber: 1,
            position: CGPoint(x: 10, y: 20)
        )
        let attachedWindow = AttachedWindow(
            attachmentID: attachmentID,
            window: window,
            lastBoardOrigin: .zero,
            lastWindowOrigin: CGPoint(x: 10, y: 20),
            lastAppliedOrigin: CGPoint(x: 10, y: 20),
            pendingReleaseOrigin: CGPoint(x: 10, y: 20)
        )
        return ReducerFixture(
            attachmentID: attachmentID,
            windowID: window.id,
            state: AttachedWindowSnapshotState(
                attachedWindows: [attachedWindow],
                unavailableAttachmentIDs: unavailable ? [attachmentID] : [],
                reconnectingAttachmentIDs: reconnecting ? [attachmentID] : [],
                minimizedAttachmentIDs: [],
                failureCounts: failureCount.map { [attachmentID: $0] } ?? [:]
            )
        )
    }
}

private struct ReducerFixture {
    let attachmentID: AttachedWindow.ID
    let windowID: WindowInfo.ID
    let state: AttachedWindowSnapshotState

    func snapshot(
        title: String? = "Document",
        origin: CGPoint? = CGPoint(x: 10, y: 20),
        isMinimized: Bool = false
    ) -> AttachedWindowSnapshot {
        AttachedWindowSnapshot(
            attachmentID: attachmentID,
            windowID: windowID,
            title: title,
            origin: origin,
            isMinimized: isMinimized
        )
    }
}

private actor SnapshotSamplerProbe {
    private(set) var callCount = 0
    private(set) var firstSampleAt: ContinuousClock.Instant?
    private let firstCallDelay: Duration?

    init(firstCallDelay: Duration? = nil) {
        self.firstCallDelay = firstCallDelay
    }

    func sample(_ requests: [AttachedWindowSnapshotRequest]) async -> [AttachedWindowSnapshot] {
        callCount += 1
        let call = callCount
        if call == 1 {
            firstSampleAt = ContinuousClock.now
        }
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

/// Keeps the old AX-like sample in flight until the test has restarted sampling.
private actor SnapshotRestartGate {
    private var callCount = 0
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?

    func beginCall() -> Int {
        callCount += 1
        return callCount
    }

    func waitForRelease() async {
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}
