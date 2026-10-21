import ApplicationServices
import XCTest
@testable import WindowBoard

final class ControlledMinimizationWindowServiceTests: XCTestCase {
    @MainActor
    func testIndependentGatesRecordConcurrencyWithoutBlockingMainActor() async throws {
        let service = ControlledMinimizationWindowService()
        let listed = expectation(description: "listing started")
        let written = expectation(description: "write started")
        let listGate = service.holdNext(.list, onStart: { listed.fulfill() })
        let writeGate = service.holdNext(.minimize, onStart: { written.fulfill() })
        let window = makeWindow()
        let listing = Task.detached { service.listWindowsReport() }
        await fulfillment(of: [listed], timeout: 2)
        let writing = Task.detached { try service.setMinimized(true, for: window) }
        await fulfillment(of: [written], timeout: 2)
        XCTAssertEqual(service.snapshot.activeCalls, 2)
        XCTAssertEqual(service.snapshot.maximumConcurrentCalls, 2)
        XCTAssertFalse(service.snapshot.events.contains { $0.onMainThread })
        writeGate.release()
        try await writing.value
        XCTAssertEqual(service.snapshot.activeCalls, 1)
        listGate.release()
        _ = await listing.value
        XCTAssertEqual(service.snapshot.activeCalls, 0)
        XCTAssertEqual(service.snapshot.events.filter { $0.phase == .started }.map(\.operation), [.list, .minimize])
    }

    func testUnknownStateAndDirectionalFailuresRemainIndependent() throws {
        let service = ControlledMinimizationWindowService()
        let window = makeWindow()
        let issue = WindowInspectionIssue(stage: .readMinimized, pid: window.pid, windowID: window.id, failure: .invalidValue)
        service.setObservation(MinimizedObservation(state: .failure(issue), quality: .diagnostic), for: window.id)
        XCTAssertThrowsError(try service.minimizedObservation(of: window).state.get())
        service.setWriteFailure(issue, minimized: true, for: window.id)
        XCTAssertThrowsError(try service.setMinimized(true, for: window))
        try service.setMinimized(false, for: window)
        XCTAssertFalse(try service.minimizedObservation(of: window).state.get())
        XCTAssertEqual(service.snapshot.count(for: .minimize), 1)
        XCTAssertEqual(service.snapshot.count(for: .restore), 1)
        XCTAssertEqual(ControlledMinimizationWindowService().snapshot.events.count, 0)
    }

    @MainActor
    func testReadResultCanPauseAfterSamplingAndReportPreservesCoverage() async throws {
        let service = ControlledMinimizationWindowService()
        let window = makeWindow()
        service.setReport(WindowEnumerationReport(windows: [window], coverage: .partial, issues: [], failedPIDs: [42]))
        XCTAssertEqual(service.listWindowsReport().coverage, .partial)
        let sampled = expectation(description: "read sampled")
        let gate = service.holdNext(.readResult, onStart: { sampled.fulfill() })
        let reading = Task.detached { service.minimizedObservation(of: window) }
        await fulfillment(of: [sampled], timeout: 2)
        service.setObservation(MinimizedObservation(state: .success(true), quality: .diagnostic), for: window.id)
        gate.release()
        let observation = await reading.value
        XCTAssertFalse(try observation.state.get())
        XCTAssertTrue(try service.minimizedObservation(of: window).state.get())
    }

    @MainActor
    func testReadAndRestoreGatesPauseBeforeStateMutation() async throws {
        let service = ControlledMinimizationWindowService()
        let window = makeWindow()
        service.setObservation(MinimizedObservation(state: .success(true), quality: .diagnostic), for: window.id)
        let readStarted = expectation(description: "read started")
        let readGate = service.holdNext(.read, onStart: { readStarted.fulfill() })
        let reading = Task.detached { service.minimizedObservation(of: window) }
        await fulfillment(of: [readStarted], timeout: 2)
        XCTAssertEqual(service.snapshot.count(for: .read), 1)
        readGate.release()
        let original = await reading.value
        XCTAssertTrue(try original.state.get())
        let restoreStarted = expectation(description: "restore started")
        let restoreGate = service.holdNext(.restore, onStart: { restoreStarted.fulfill() })
        let restoring = Task.detached { try service.setMinimized(false, for: window) }
        await fulfillment(of: [restoreStarted], timeout: 2)
        XCTAssertTrue(try service.minimizedObservation(of: window).state.get())
        restoreGate.release()
        try await restoring.value
        XCTAssertFalse(try service.minimizedObservation(of: window).state.get())
    }

    private func makeWindow() -> WindowInfo {
        WindowInfo(id: "test", appName: "Test", title: "", pid: 42, bundleIdentifier: nil, bundleURL: nil, documentURL: nil, axWindow: AXUIElementCreateApplication(42), windowNumber: 1, position: .zero)
    }
}
