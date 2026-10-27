import AppKit
import XCTest
@testable import WindowBoard

@MainActor
final class PrototypeDragSupportTests: XCTestCase {
    private final class ModelBox {
        var model = PrototypeBoardDragModel()
    }

    private final class DragInfo: NSObject, NSDraggingInfo {
        var draggingDestinationWindow: NSWindow? { nil }
        var draggingSourceOperationMask: NSDragOperation { .move }
        var draggingLocation: NSPoint { .init(x: 20, y: 20) }
        var draggedImageLocation: NSPoint { draggingLocation }
        var draggedImage: NSImage? { nil }
        let draggingPasteboard: NSPasteboard
        let draggingSource: Any?
        var draggingSequenceNumber: Int { 1 }
        var draggingFormation: NSDraggingFormation = .none
        var animatesToDestination = false
        var numberOfValidItemsForDrop = 1
        var springLoadingHighlight: NSSpringLoadingHighlight { .none }

        init(source: Any?, items: [NSPasteboardItem]) {
            draggingSource = source
            draggingPasteboard = NSPasteboard.withUniqueName()
            super.init()
            draggingPasteboard.writeObjects(items)
        }
        func slideDraggedImage(to screenPoint: NSPoint) {}
        override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
        func resetSpringLoading() {}
        func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?, classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any], using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    }

    private func item(_ payload: PrototypeDragPayload) throws -> NSPasteboardItem {
        let item = NSPasteboardItem()
        let type: NSPasteboard.PasteboardType
        switch payload.kind {
        case .board: type = PrototypeDragSurface.boardType
        case .card: type = PrototypeDragSurface.cardType
        }
        item.setData(try JSONEncoder().encode(payload), forType: type)
        return item
    }

    private func surface(_ box: ModelBox, presentation: PrototypeDragPresentation, target: PrototypeDropTarget) -> PrototypeDragSurface.NativeSurface {
        var configuration = PrototypeDragSurface(presentation: presentation)
        configuration.destination = { _ in target }
        configuration.accepts = { box.model.validate($0, to: $1) }
        configuration.commit = { box.model.commit($0, to: $1) }
        configuration.ended = { box.model.endDrag() }
        let view = PrototypeDragSurface.NativeSurface(configuration: configuration)
        view.frame = .init(x: 0, y: 0, width: 300, height: 300)
        return view
    }

    func testNativeDropCommitsButRetainsPresentationUntilSourceEnds() throws {
        let box = ModelBox()
        let presentation = PrototypeDragPresentation()
        let payload = try XCTUnwrap(box.model.beginDrag(kind: .card(ownerID: "work", referenceID: "editor")))
        presentation.payload = payload
        let view = surface(box, presentation: presentation, target: .board("personal"))
        let info = DragInfo(source: view, items: [try item(payload)])
        XCTAssertEqual(view.draggingEntered(info), .move)
        XCTAssertTrue(view.prepareForDragOperation(info))
        XCTAssertTrue(view.performDragOperation(info))
        XCTAssertFalse(box.model.boards.first { $0.id == "work" }!.cards.contains { $0.id == "editor" })
        XCTAssertEqual(box.model.boards.first { $0.id == "personal" }!.cards.last?.id, "editor")
        XCTAssertEqual(box.model.saveCount, 1)
        XCTAssertEqual(presentation.payload, payload)
        XCTAssertFalse(view.performDragOperation(info))
        XCTAssertEqual(box.model.saveCount, 1)
        view.finishSourceDrag(sessionToken: payload.sessionToken)
        XCTAssertNil(presentation.payload)
    }

    func testNativeRejectedDuplicateAndSaveFailureReturnFalseAndKeepState() throws {
        for failsSave in [false, true] {
            let box = ModelBox()
            let presentation = PrototypeDragPresentation()
            let reference = failsSave ? "editor" : "shared-work"
            let payload = try XCTUnwrap(box.model.beginDrag(kind: .card(ownerID: "work", referenceID: reference)))
            presentation.payload = payload
            let before = box.model.boards
            box.model.failNextSave = failsSave
            let view = surface(box, presentation: presentation, target: .board("reference"))
            let info = DragInfo(source: view, items: [try item(payload)])
            XCTAssertFalse(view.performDragOperation(info))
            XCTAssertEqual(box.model.boards, before)
            XCTAssertEqual(box.model.saveCount, 0)
            XCTAssertEqual(presentation.payload, payload)
            view.finishSourceDrag(sessionToken: payload.sessionToken)
            XCTAssertNil(presentation.payload)
        }
    }


    func testOnlyMatchingSourceEndNotifiesOnceAndStaleEndPreservesNewDrag() throws {
        let box = ModelBox()
        let presentation = PrototypeDragPresentation()
        let oldPayload = try XCTUnwrap(box.model.beginDrag(kind: .board("personal")))
        presentation.payload = oldPayload
        let view = surface(box, presentation: presentation, target: .board("work"))
        var endedTokens: [UUID] = []
        var endCount = 0
        view.configuration.sourceEnded = { endedTokens.append($0) }
        view.configuration.ended = { endCount += 1; box.model.endDrag() }
        let info = DragInfo(source: view, items: [try item(oldPayload)])
        XCTAssertTrue(view.performDragOperation(info))
        XCTAssertTrue(endedTokens.isEmpty)
        XCTAssertEqual(endCount, 0)
        XCTAssertEqual(presentation.payload, oldPayload)
        view.finishSourceDrag(sessionToken: oldPayload.sessionToken)
        XCTAssertEqual(endedTokens, [oldPayload.sessionToken])
        XCTAssertEqual(endCount, 1)
        XCTAssertNil(presentation.payload)
        view.finishSourceDrag(sessionToken: oldPayload.sessionToken)
        XCTAssertEqual(endCount, 1)
        let newPayload = try XCTUnwrap(box.model.beginDrag(kind: .board("work")))
        presentation.payload = newPayload
        view.finishSourceDrag(sessionToken: oldPayload.sessionToken)
        XCTAssertEqual(presentation.payload, newPayload)
        XCTAssertEqual(endCount, 1)
        view.finishSourceDrag(sessionToken: newPayload.sessionToken)
        XCTAssertEqual(endedTokens, [oldPayload.sessionToken, newPayload.sessionToken])
        XCTAssertEqual(endCount, 2)
    }

    func testNativeForeignMultiItemAndStaleSessionsNeverCommit() throws {
        for invalidCase in 0..<3 {
            let box = ModelBox()
            let presentation = PrototypeDragPresentation()
            let payload = try XCTUnwrap(box.model.beginDrag(kind: .board("personal")))
            presentation.payload = payload
            let view = surface(box, presentation: presentation, target: .board("work"))
            let items = invalidCase == 1 ? [try item(payload), try item(payload)] : [try item(payload)]
            let info = DragInfo(source: invalidCase == 0 ? NSObject() : view, items: items)
            if invalidCase == 2 { box.model.endDrag() }
            let beforeBoards = box.model.boards
            let beforeGroups = box.model.groups
            XCTAssertEqual(view.draggingEntered(info), [])
            XCTAssertFalse(view.performDragOperation(info))
            XCTAssertEqual(box.model.boards, beforeBoards)
            XCTAssertEqual(box.model.groups, beforeGroups)
            XCTAssertEqual(box.model.saveCount, 0)
        }
    }
}
