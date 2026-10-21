import Foundation
@testable import WindowBoard

/// Every mutable service field is protected by `lock`; gate state has its own
/// condition. No Sendable claim is needed by the synchronous service protocol.
final class ControlledMinimizationWindowService: WorkspaceWindowOperating {
    enum Operation: Hashable { case list, read, readResult, minimize, restore }
    enum Phase { case started, finished }
    struct Event {
        let operation: Operation
        let phase: Phase
        let windowID: String?
        let onMainThread: Bool
    }
    struct Snapshot {
        let events: [Event]
        let activeCalls: Int
        let maximumConcurrentCalls: Int
        func count(for operation: Operation) -> Int {
            events.filter { $0.operation == operation && $0.phase == .started }.count
        }
    }
    final class Gate {
        private let condition = NSCondition()
        private var released = false
        private let onStart: () -> Void
        init(onStart: @escaping () -> Void) { self.onStart = onStart }
        fileprivate func wait() {
            onStart()
            condition.lock()
            defer { condition.unlock() }
            while !released { condition.wait() }
        }
        func release() {
            condition.lock()
            released = true
            condition.broadcast()
            condition.unlock()
        }
    }
    private let lock = NSLock()
    private var report = WindowEnumerationReport(windows: [], coverage: .complete, issues: [], failedPIDs: [])
    private var observations: [String: MinimizedObservation] = [:]
    private var minimizeFailures: [String: WindowInspectionIssue] = [:]
    private var restoreFailures: [String: WindowInspectionIssue] = [:]
    private var gates: [Operation: [Gate]] = [:]
    private var events: [Event] = []
    private var activeCalls = 0
    private var maximumConcurrentCalls = 0

    var snapshot: Snapshot {
        locked { Snapshot(events: events, activeCalls: activeCalls, maximumConcurrentCalls: maximumConcurrentCalls) }
    }
    func setReport(_ value: WindowEnumerationReport) { locked { report = value } }
    func setObservation(_ value: MinimizedObservation, for id: String) { locked { observations[id] = value } }
    func setWriteFailure(_ issue: WindowInspectionIssue?, minimized: Bool, for id: String) {
        locked {
            if minimized { minimizeFailures[id] = issue } else { restoreFailures[id] = issue }
        }
    }
    /// Queue one gate per selected occurrence; release is safe even before arrival.
    @discardableResult
    func holdNext(_ operation: Operation, onStart: @escaping () -> Void = {}) -> Gate {
        let gate = Gate(onStart: onStart)
        locked { gates[operation, default: []].append(gate) }
        return gate
    }
    func listWindows() -> [WindowInfo] { listWindowsReport().windows }
    func listWindowsReport() -> WindowEnumerationReport {
        begin(.list, id: nil)
        defer { end(.list, id: nil) }
        return locked { report }
    }
    func minimizedObservation(of window: WindowInfo) -> MinimizedObservation {
        begin(.read, id: window.id)
        defer { end(.read, id: window.id) }
        let value = locked { observations[window.id] ?? MinimizedObservation(state: .success(false), quality: .diagnostic) }
        // A distinct checkpoint permits invalidation after the read has sampled.
        checkpoint(.readResult)
        return value
    }
    func isMinimized(_ window: WindowInfo) -> Bool {
        (try? minimizedObservation(of: window).state.get()) ?? false
    }
    func setMinimized(_ minimized: Bool, for window: WindowInfo) throws {
        let operation: Operation = minimized ? .minimize : .restore
        begin(operation, id: window.id)
        defer { end(operation, id: window.id) }
        try locked {
            if let issue = minimized ? minimizeFailures[window.id] : restoreFailures[window.id] { throw issue }
            observations[window.id] = MinimizedObservation(state: .success(minimized), quality: .diagnostic)
        }
    }
    private func begin(_ operation: Operation, id: String?) {
        let gate: Gate? = locked {
            activeCalls += 1
            maximumConcurrentCalls = max(maximumConcurrentCalls, activeCalls)
            events.append(Event(operation: operation, phase: .started, windowID: id, onMainThread: Thread.isMainThread))
            return takeGateLocked(operation)
        }
        gate?.wait()
    }
    private func end(_ operation: Operation, id: String?) {
        locked {
            activeCalls -= 1
            events.append(Event(operation: operation, phase: .finished, windowID: id, onMainThread: Thread.isMainThread))
        }
    }
    private func checkpoint(_ operation: Operation) {
        let gate = locked { takeGateLocked(operation) }
        gate?.wait()
    }
    /// Caller holds `lock`, keeping gate assignment in recorded arrival order.
    private func takeGateLocked(_ operation: Operation) -> Gate? {
        guard var queued = gates[operation], !queued.isEmpty else { return nil }
        let next = queued.removeFirst()
        gates[operation] = queued
        return next
    }
    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
    func windows(matching window: WindowInfo) -> [WindowInfo] { locked { report.windows.filter { $0.id == window.id } } }
    func position(of window: WindowInfo) throws -> CGPoint { window.position ?? .zero }
    func size(of window: WindowInfo) throws -> CGSize { .zero }
    func setPosition(_ position: CGPoint, for window: WindowInfo) throws {}
    func setSize(_ size: CGSize, for window: WindowInfo) throws {}
    func raise(_ window: WindowInfo) {}
    func openSavedWindowReference(_ reference: SavedWindowReference) -> Bool { false }
    func activateSavedApplication(_ reference: SavedWindowReference) -> Bool { false }
}
