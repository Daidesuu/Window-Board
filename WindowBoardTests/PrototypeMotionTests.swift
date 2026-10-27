import XCTest
@testable import WindowBoard

@MainActor
final class PrototypeMotionTests: XCTestCase {

    func testTiledLayoutThresholdAndThreeBoardEmptySlot() {
        let exactViewport = CGSize(width: 620, height: 540)
        let exact = PrototypeBoardLayout.metrics(viewport: exactViewport, count: 4)
        XCTAssertFalse(exact.isStacked)
        XCTAssertEqual(exact.canvasSize, CGSize(width: 280, height: 240))
        XCTAssertTrue(PrototypeBoardLayout.metrics(viewport: CGSize(width: 619, height: 540), count: 4).isStacked)
        XCTAssertTrue(PrototypeBoardLayout.metrics(viewport: CGSize(width: 620, height: 539), count: 4).isStacked)
        let frames = PrototypeBoardLayout.frames(viewport: exactViewport, count: 3)
        XCTAssertEqual(frames.count, 3)
        XCTAssertEqual(frames[2].origin, CGPoint(x: 0, y: 252))
        XCTAssertFalse(frames.contains { $0.origin == CGPoint(x: 292, y: 252) })
    }

    func testDegenerateLayoutRemainsFiniteAndHasNoPhantomBoards() {
        XCTAssertEqual(PrototypeBoardLayout.frames(viewport: .zero, count: 0), [])
        XCTAssertEqual(PrototypeBoardLayout.frames(viewport: .zero, count: -1), [])
        let viewport = CGSize(width: CGFloat.infinity, height: CGFloat.nan)
        let metrics = PrototypeBoardLayout.metrics(viewport: viewport, count: 2)
        XCTAssertTrue(metrics.isStacked)
        XCTAssertEqual(metrics.canvasSize, CGSize(width: 0, height: 240))
        XCTAssertEqual(metrics.contentSize, CGSize(width: 0, height: 492))
        for frame in PrototypeBoardLayout.frames(viewport: viewport, count: 2) {
            XCTAssertTrue(frame.origin.x.isFinite && frame.origin.y.isFinite)
            XCTAssertTrue(frame.width.isFinite && frame.height.isFinite)
        }
    }

    func testReducedMotionCapsFeedbackAndDisablesAllPlacement() {
        let placement: [PrototypeMotionEvent] = [.composition, .cardInsertRemove, .cardMove]
        for event in PrototypeMotionEvent.allCases {
            XCTAssertGreaterThan(event.duration(reduceMotion: false), 0)
            XCTAssertLessThanOrEqual(event.duration(reduceMotion: true), 0.1)
            XCTAssertLessThanOrEqual(event.duration(reduceMotion: true), event.duration(reduceMotion: false))
            XCTAssertNil(event.placementAnimation(reduceMotion: true))
            if placement.contains(event) {
                XCTAssertNotNil(event.placementAnimation(reduceMotion: false))
            } else {
                XCTAssertNil(event.placementAnimation(reduceMotion: false))
            }
        }
        XCTAssertEqual(PrototypeMotionEvent.composition.duration(reduceMotion: false), 0.25)
        XCTAssertEqual(PrototypeMotionEvent.cardMove.duration(reduceMotion: false), 0.2)
        XCTAssertEqual(PrototypeMotionEvent.dropHint.duration(reduceMotion: true), 0.08)
    }

    func testAcceptedDropWaitsForSourceEndAndReleasesOnlyOnce() throws {
        var gate = PrototypeMotionCommitGate()
        gate.begin()
        XCTAssertFalse(gate.receive(result: .applied))
        XCTAssertTrue(gate.isDragging)
        XCTAssertTrue(gate.hasPending)
        XCTAssertFalse(gate.release(generation: gate.generation))
        let token = try XCTUnwrap(gate.end())
        XCTAssertFalse(gate.isDragging)
        XCTAssertTrue(gate.hasPending)
        XCTAssertTrue(gate.release(generation: token))
        XCTAssertFalse(gate.hasPending)
        XCTAssertFalse(gate.release(generation: token))
        XCTAssertNil(gate.end())
    }

    func testCancelledRejectedAndNoOpDragNeverSchedulePublication() {
        for result in [PrototypeDragResult.noChange, .rejected("Save failed")] {
            var gate = PrototypeMotionCommitGate()
            gate.begin()
            XCTAssertFalse(gate.receive(result: result))
            XCTAssertFalse(gate.hasPending)
            XCTAssertNil(gate.end())
        }
        var cancelled = PrototypeMotionCommitGate()
        cancelled.begin()
        XCTAssertNil(cancelled.end())
        XCTAssertFalse(cancelled.hasPending)
    }

    func testNewDragResetAndImmediateMutationInvalidateOldRelease() throws {
        for invalidation in 0..<3 {
            var gate = PrototypeMotionCommitGate()
            gate.begin()
            XCTAssertFalse(gate.receive(result: .applied))
            let oldToken = try XCTUnwrap(gate.end())
            switch invalidation {
            case 0: gate.begin()
            case 1: gate.reset()
            default: XCTAssertTrue(gate.receive(result: .applied))
            }
            XCTAssertFalse(gate.release(generation: oldToken))
            XCTAssertFalse(gate.hasPending)
        }
    }

    func testRenderedSnapshotPreservesSourceUntilSourceEnd() throws {
        var model = PrototypeBoardDragModel()
        let presentation = PrototypeMotionPresentation(model: model)
        let initialBoards = presentation.renderedModel.boards
        presentation.beginNativeDrag()
        let payload = try XCTUnwrap(model.beginDrag(kind: .card(ownerID: "work", referenceID: "editor")))
        let result = model.commit(payload, to: .board("personal"))
        XCTAssertEqual(result, .applied)
        presentation.receive(model: model, event: .cardMove, result: result, reduceMotion: false)
        XCTAssertEqual(presentation.renderedModel.boards, initialBoards)
        XCTAssertTrue(presentation.isNativeDragActive)
        presentation.nativeDragEnded(reduceMotion: false)
        XCTAssertFalse(presentation.isNativeDragActive)
        // The native callback returns with the source tree intact; release is queued afterwards.
        XCTAssertEqual(presentation.renderedModel.boards, initialBoards)
        presentation.settle()
        XCTAssertEqual(presentation.renderedModel.boards, model.boards)
    }

    func testFailedAndNoOpReceiveCannotReplaceRenderedModel() {
        for result in [PrototypeDragResult.noChange, .rejected("Save failed")] {
            var changed = PrototypeBoardDragModel()
            let initial = changed.boards
            let presentation = PrototypeMotionPresentation(model: changed)
            presentation.beginNativeDrag()
            XCTAssertEqual(changed.addCard(to: "personal"), .applied)
            presentation.receive(model: changed, event: .cardInsertRemove, result: result, reduceMotion: true)
            presentation.nativeDragEnded(reduceMotion: true)
            presentation.settle()
            XCTAssertEqual(presentation.renderedModel.boards, initial)
        }
    }

    func testResetAndNewDragCannotPublishAnOlderPendingSnapshot() {
        var first = PrototypeBoardDragModel()
        let presentation = PrototypeMotionPresentation(model: first)
        presentation.beginNativeDrag()
        XCTAssertEqual(first.addCard(to: "personal"), .applied)
        presentation.receive(model: first, event: .cardInsertRemove, result: .applied, reduceMotion: false)
        presentation.nativeDragEnded(reduceMotion: false)
        var replacement = PrototypeBoardDragModel()
        replacement.createBoard(name: "Replacement")
        presentation.reset(to: replacement)
        presentation.beginNativeDrag()
        presentation.settle()
        XCTAssertEqual(presentation.renderedModel.boards, replacement.boards)
        XCTAssertEqual(presentation.renderedModel.selectedTarget, replacement.selectedTarget)
    }

    func testNewDragSettlesPreviousAcceptedChangeBeforeRetainingNewSource() {
        var model = PrototypeBoardDragModel()
        let presentation = PrototypeMotionPresentation(model: model)
        presentation.beginNativeDrag()
        XCTAssertEqual(model.addCard(to: "personal"), .applied)
        presentation.receive(model: model, event: .cardInsertRemove, result: .applied, reduceMotion: false)
        presentation.nativeDragEnded(reduceMotion: false)
        presentation.beginNativeDrag()
        XCTAssertEqual(presentation.renderedModel.boards, model.boards)
        XCTAssertTrue(presentation.isNativeDragActive)
        presentation.settle()
    }
}
