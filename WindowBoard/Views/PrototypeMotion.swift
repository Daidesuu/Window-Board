import SwiftUI

/// Motion policy for the isolated fixture UI. No production session or AX work is involved.
enum PrototypeMotionEvent: CaseIterable {
    case switchDisplay
    case composition
    case sidebarComposition
    case cardInsertRemove
    case cardMove
    case selection
    case hover
    case dragOpacity
    case dropHint
    case detachZone
    case saveFeedback
    case status

    var durationMilliseconds: Int {
        switch self {
        case .switchDisplay: 150
        case .composition: 250
        case .cardInsertRemove: 180
        case .cardMove, .sidebarComposition: 200
        case .selection, .hover, .dragOpacity: 100
        case .dropHint: 80
        case .detachZone: 120
        case .saveFeedback: 150
        case .status: 120
        }
    }

    func duration(reduceMotion: Bool) -> Double {
        Double(reduceMotion ? min(durationMilliseconds, 100) : durationMilliseconds) / 1_000
    }

    func animation(reduceMotion: Bool) -> Animation {
        switch self {
        case .composition, .cardMove, .sidebarComposition:
            .easeInOut(duration: duration(reduceMotion: reduceMotion))
        default:
            .easeOut(duration: duration(reduceMotion: reduceMotion))
        }
    }

    /// Reduced motion must never animate layout, even when opacity is still animated.
    func placementAnimation(reduceMotion: Bool) -> Animation? {
        guard !reduceMotion else { return nil }
        switch self {
        case .composition, .cardInsertRemove, .cardMove:
            return animation(reduceMotion: false)
        default:
            return nil
        }
    }

    func transition(reduceMotion: Bool) -> AnyTransition {
        .opacity
    }
}

/// Pure ordering gate: hover/failure/no-op never schedules a model publication.
/// A completed accepted drop remains pending until the *source* drag has ended.
struct PrototypeMotionCommitGate {
    private(set) var isDragging = false
    private(set) var hasPending = false
    private(set) var generation = 0

    mutating func receive(result: PrototypeDragResult) -> Bool {
        guard result == .applied else { return false }
        if isDragging {
            hasPending = true
            return false
        }
        // A new immediate update supersedes a release queued by an earlier drag.
        generation += 1
        hasPending = false
        return true
    }

    mutating func begin() {
        generation += 1
        isDragging = true
        hasPending = false
    }

    mutating func end() -> Int? {
        guard isDragging else { return nil }
        isDragging = false
        return hasPending ? generation : nil
    }

    mutating func release(generation token: Int) -> Bool {
        guard token == generation, !isDragging, hasPending else { return false }
        hasPending = false
        generation += 1
        return true
    }

    mutating func settle() {
        generation += 1
        isDragging = false
        hasPending = false
    }

    mutating func reset() { settle() }
}

@MainActor
final class PrototypeMotionPresentation: ObservableObject {
    @Published private(set) var renderedModel: PrototypeBoardDragModel
    @Published private(set) var isNativeDragActive = false
    @Published private(set) var settlementRevision = 0

    private var latestModel: PrototypeBoardDragModel
    private var pendingEvent: PrototypeMotionEvent = .cardMove
    private var gate = PrototypeMotionCommitGate()
    private var releaseTask: Task<Void, Never>?

    init(model: PrototypeBoardDragModel) {
        renderedModel = model
        latestModel = model
    }

    func receive(model: PrototypeBoardDragModel, event: PrototypeMotionEvent,
                 result: PrototypeDragResult, reduceMotion: Bool) {
        guard result == .applied else { return }
        latestModel = model
        pendingEvent = event
        if gate.receive(result: result) {
            releaseTask?.cancel()
            releaseTask = nil
            publish(event: event, reduceMotion: reduceMotion)
        }
    }

    /// Flushes a pending accepted change before retaining a new drag's source view.
    func beginNativeDrag() {
        settle()
        gate.begin()
        isNativeDragActive = true
    }

    /// Called by the native source's ended callback, never by a destination callback.
    func nativeDragEnded(reduceMotion: Bool) {
        guard isNativeDragActive else { return }
        isNativeDragActive = false
        guard let token = gate.end() else { return }
        releaseTask?.cancel()
        releaseTask = Task { @MainActor [weak self] in
            // Return from the native source callback before publishing a tree change.
            await Task.yield()
            guard !Task.isCancelled, let self,
                  self.gate.release(generation: token) else { return }
            self.publish(event: self.pendingEvent, reduceMotion: reduceMotion)
            self.releaseTask = nil
        }
    }

    /// Cancels delayed visual work and displays the authoritative fixture model immediately.
    func settle() {
        releaseTask?.cancel()
        releaseTask = nil
        gate.settle()
        isNativeDragActive = false
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            settlementRevision += 1
            renderedModel = latestModel
        }
    }

    func reset(to model: PrototypeBoardDragModel) {
        latestModel = model
        pendingEvent = .switchDisplay
        gate.reset()
        settle()
    }

    private func publish(event: PrototypeMotionEvent, reduceMotion: Bool) {
        if reduceMotion {
            // Layout jumps directly; view-level opacity feedback may still use <=100ms.
            let transaction = Transaction(animation: nil)
            withTransaction(transaction) { renderedModel = latestModel }
        } else {
            withAnimation(event.placementAnimation(reduceMotion: false)) { renderedModel = latestModel }
        }
    }
}
