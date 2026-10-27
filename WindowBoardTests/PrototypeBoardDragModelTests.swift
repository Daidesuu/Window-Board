import XCTest
@testable import WindowBoard

final class PrototypeBoardDragModelTests: XCTestCase {
    private func card(_ id: String, physical: String? = nil) -> PrototypeCard {
        PrototypeCard(id: id, application: "Safari", title: "Same document", symbol: "safari", tint: "cyan", status: "Available", physicalWindowID: physical)
    }

    private func board(_ id: String, cards: [PrototypeCard] = []) -> PrototypeBoard {
        PrototypeBoard(id: id, name: id, symbol: "rectangle", cards: cards)
    }

    private func fixture(groups: [PrototypeSplitGroup] = [], selected: PrototypeDisplayTarget = .standalone("a")) -> PrototypeBoardDragModel {
        PrototypeBoardDragModel(boards: ["a", "b", "c", "d", "e", "f"].map { board($0) }, groups: groups, selectedTarget: selected)
    }

    private func assertRejected(_ result: PrototypeDragResult, file: StaticString = #filePath, line: UInt = #line) {
        guard case .rejected = result else { XCTFail("Expected rejection, received \(result)", file: file, line: line); return }
    }

    func testCapacityRejectionDoesNotRemoveSourceOrChangeSelection() throws {
        var model = fixture(groups: [.init(id: "source", memberIDs: ["a", "b"]), .init(id: "full", memberIDs: ["c", "d", "e", "f"])], selected: .group("source"))
        let beforeBoards = model.boards
        let beforeGroups = model.groups
        let payload = try XCTUnwrap(model.beginDrag(kind: .board("a")))
        assertRejected(model.commit(payload, to: .group("full")))
        XCTAssertEqual(model.boards, beforeBoards)
        XCTAssertEqual(model.groups, beforeGroups)
        XCTAssertEqual(model.selectedTarget, .group("source"))
        XCTAssertEqual(model.saveCount, 0)
        XCTAssertEqual(model.revision, 0)
    }

    func testMoveOneMemberNormalizesSourceAndKeepsDestinationIdentity() throws {
        var model = fixture(groups: [.init(id: "source", memberIDs: ["a", "b"]), .init(id: "destination", memberIDs: ["c", "d"])], selected: .group("source"))
        let payload = try XCTUnwrap(model.beginDrag(kind: .board("a")))
        XCTAssertEqual(model.commit(payload, to: .board("d")), .applied)
        XCTAssertEqual(model.groups, [.init(id: "destination", memberIDs: ["c", "d", "a"])])
        XCTAssertEqual(model.selectedTarget, .standalone("b"))
        XCTAssertEqual(model.boards.map(\.id), ["a", "b", "c", "d", "e", "f"])
        XCTAssertEqual(model.saveCount, 1)
    }

    func testDisplayedGroupSurvivesWithRemainingMembers() throws {
        var model = fixture(groups: [.init(id: "source", memberIDs: ["a", "b", "c"])], selected: .group("source"))
        let payload = try XCTUnwrap(model.beginDrag(kind: .board("a")))
        XCTAssertEqual(model.commit(payload, to: .board("d")), .applied)
        XCTAssertEqual(model.selectedTarget, .group("source"))
        XCTAssertEqual(model.displayedBoards.map(\.id), ["b", "c"])
    }

    func testSelectedStandaloneFollowsNewGroupButHiddenMovesPreserveDisplay() throws {
        var model = fixture()
        let first = try XCTUnwrap(model.beginDrag(kind: .board("a")))
        XCTAssertEqual(model.commit(first, to: .board("b")), .applied)
        let displayed = model.selectedTarget
        XCTAssertEqual(model.displayedBoards.map(\.id), ["b", "a"])
        let second = try XCTUnwrap(model.beginDrag(kind: .board("c")))
        XCTAssertEqual(model.commit(second, to: .board("d")), .applied)
        XCTAssertEqual(model.selectedTarget, displayed)
    }

    func testSameGroupDropIsNoChangeAndDoesNotSave() throws {
        var model = fixture(groups: [.init(id: "g", memberIDs: ["a", "b"])], selected: .group("g"))
        let payload = try XCTUnwrap(model.beginDrag(kind: .board("a")))
        XCTAssertEqual(model.commit(payload, to: .board("b")), .noChange)
        XCTAssertEqual(model.groups[0].memberIDs, ["a", "b"])
        XCTAssertEqual(model.saveCount, 0)
    }

    func testTransferPreservesReferenceAndLayoutWithoutChangingDisplay() throws {
        var reference = card("r")
        reference.saved = true
        reference.layout = .init(x: 13, y: 27, width: 901, height: 703, offsetX: -18, offsetY: 56)
        var model = PrototypeBoardDragModel(boards: [board("a", cards: [reference]), board("b", cards: [card("anchor")])], groups: [], selectedTarget: .standalone("a"))
        let payload = try XCTUnwrap(model.beginDrag(kind: .card(ownerID: "a", referenceID: "r")))
        XCTAssertEqual(model.commit(payload, to: .card(boardID: "b", anchorID: "anchor", before: true)), .applied)
        XCTAssertEqual(model.boards[0].cards, [])
        XCTAssertEqual(model.boards[1].cards.first, reference)
        XCTAssertEqual(model.boards[1].cards.map(\.id), ["r", "anchor"])
        XCTAssertEqual(model.selectedTarget, .standalone("a"))
        XCTAssertEqual(model.boards.count, 2)
    }

    func testDuplicateReferenceOrCertainPhysicalWindowRejectsAtomically() throws {
        for destination in [card("r"), card("other", physical: "live")] {
            var model = PrototypeBoardDragModel(boards: [board("a", cards: [card("r", physical: "live")]), board("b", cards: [destination])], groups: [], selectedTarget: .standalone("a"))
            let before = model.boards
            let payload = try XCTUnwrap(model.beginDrag(kind: .card(ownerID: "a", referenceID: "r")))
            assertRejected(model.commit(payload, to: .board("b")))
            XCTAssertEqual(model.boards, before)
            XCTAssertEqual(model.saveCount, 0)
        }
    }

    func testAmbiguousSameDocumentDoesNotBlockTransfer() throws {
        var model = PrototypeBoardDragModel(boards: [board("a", cards: [card("r")]), board("b", cards: [card("other")])], groups: [], selectedTarget: .standalone("a"))
        let payload = try XCTUnwrap(model.beginDrag(kind: .card(ownerID: "a", referenceID: "r")))
        XCTAssertEqual(model.commit(payload, to: .board("b")), .applied)
        XCTAssertEqual(model.boards[1].cards.map(\.id), ["other", "r"])
    }

    func testReorderResolvesAnchorAfterRemovalInBothDirections() throws {
        var model = PrototypeBoardDragModel(boards: [board("a", cards: [card("1"), card("2"), card("3")])], groups: [], selectedTarget: .standalone("a"))
        let forward = try XCTUnwrap(model.beginDrag(kind: .card(ownerID: "a", referenceID: "1")))
        XCTAssertEqual(model.commit(forward, to: .card(boardID: "a", anchorID: "3", before: false)), .applied)
        XCTAssertEqual(model.boards[0].cards.map(\.id), ["2", "3", "1"])
        let backward = try XCTUnwrap(model.beginDrag(kind: .card(ownerID: "a", referenceID: "1")))
        XCTAssertEqual(model.commit(backward, to: .card(boardID: "a", anchorID: "2", before: true)), .applied)
        XCTAssertEqual(model.boards[0].cards.map(\.id), ["1", "2", "3"])
    }

    func testSelfAdjacentAndSameBoardTabDropsDoNotSave() throws {
        var model = PrototypeBoardDragModel(boards: [board("a", cards: [card("1"), card("2")])], groups: [], selectedTarget: .standalone("a"))
        let targets: [PrototypeDropTarget] = [.card(boardID: "a", anchorID: "1", before: true), .card(boardID: "a", anchorID: "2", before: true), .board("a")]
        for target in targets {
            let payload = try XCTUnwrap(model.beginDrag(kind: .card(ownerID: "a", referenceID: "1")))
            XCTAssertEqual(model.commit(payload, to: target), .noChange)
        }
        XCTAssertEqual(model.saveCount, 0)
        XCTAssertEqual(model.boards[0].cards.map(\.id), ["1", "2"])
    }

    func testMissingAnchorRejectionKeepsSource() throws {
        var model = PrototypeBoardDragModel(boards: [board("a", cards: [card("r")]), board("b")], groups: [], selectedTarget: .standalone("a"))
        let before = model.boards
        let payload = try XCTUnwrap(model.beginDrag(kind: .card(ownerID: "a", referenceID: "r")))
        assertRejected(model.commit(payload, to: .card(boardID: "b", anchorID: "missing", before: false)))
        XCTAssertEqual(model.boards, before)
        XCTAssertEqual(model.saveCount, 0)
    }

    func testDetachOnlyRemovesPayloadOwnerSharedReference() throws {
        var model = PrototypeBoardDragModel(boards: [board("a", cards: [card("r", physical: "live")]), board("b", cards: [card("r", physical: "live")])], groups: [], selectedTarget: .standalone("b"))
        let payload = try XCTUnwrap(model.beginDrag(kind: .card(ownerID: "a", referenceID: "r")))
        XCTAssertEqual(model.commit(payload, to: .detach), .applied)
        XCTAssertTrue(model.boards[0].cards.isEmpty)
        XCTAssertEqual(model.boards[1].cards.map(\.id), ["r"])
        XCTAssertEqual(model.selectedTarget, .standalone("b"))
    }

    func testCancelledForeignAndStalePayloadsCannotMutate() throws {
        var model = fixture()
        let cancelled = try XCTUnwrap(model.beginDrag(kind: .board("a")))
        model.cancelDrag(cancelled)
        assertRejected(model.commit(cancelled, to: .board("b")))
        var foreign = fixture()
        let foreignPayload = try XCTUnwrap(foreign.beginDrag(kind: .board("a")))
        assertRejected(model.commit(foreignPayload, to: .board("b")))
        let stale = try XCTUnwrap(model.beginDrag(kind: .board("a")))
        XCTAssertEqual(model.addCard(to: "a"), .applied)
        let before = model.boards
        assertRejected(model.commit(stale, to: .board("b")))
        XCTAssertEqual(model.boards, before)
        XCTAssertTrue(model.groups.isEmpty)
    }


    func testUnrelatedBoardMutationDoesNotInvalidateDrag() throws {
        var model = fixture()
        let payload = try XCTUnwrap(model.beginDrag(kind: .board("a")))
        XCTAssertEqual(model.addCard(to: "c"), .applied)
        XCTAssertEqual(model.commit(payload, to: .board("b")), .applied)
        XCTAssertEqual(model.displayedBoards.map(\.id), ["b", "a"])
        XCTAssertEqual(model.saveCount, 2)
    }


    func testNativeDragEndInvalidatesAllPendingCallbacksAndWrongVersion() throws {
        var model = fixture()
        let first = try XCTUnwrap(model.beginDrag(kind: .board("a")))
        let second = try XCTUnwrap(model.beginDrag(kind: .board("c")))
        let wrongVersion = PrototypeDragPayload(version: 99, modelToken: first.modelToken, sessionToken: first.sessionToken, revision: first.revision, kind: first.kind)
        assertRejected(model.commit(wrongVersion, to: .board("b")))
        model.endDrag()
        assertRejected(model.commit(first, to: .board("b")))
        assertRejected(model.commit(second, to: .board("d")))
        XCTAssertTrue(model.groups.isEmpty)
        XCTAssertEqual(model.saveCount, 0)
    }

    func testHoverIsPureAndDuplicateCallbackCannotApplyTwice() throws {
        var model = fixture()
        let payload = try XCTUnwrap(model.beginDrag(kind: .board("a")))
        XCTAssertEqual(model.validate(payload, to: .board("b")), .applied)
        XCTAssertTrue(model.groups.isEmpty)
        XCTAssertEqual(model.saveCount, 0)
        XCTAssertEqual(model.commit(payload, to: .board("b")), .applied)
        let before = model.groups
        assertRejected(model.commit(payload, to: .board("c")))
        XCTAssertEqual(model.groups, before)
        XCTAssertEqual(model.saveCount, 1)
    }

    func testSaveFailureRollsBackBoardMembershipAndCardTransfer() throws {
        var model = fixture()
        let boardPayload = try XCTUnwrap(model.beginDrag(kind: .board("a")))
        model.failNextSave = true
        assertRejected(model.commit(boardPayload, to: .board("b")))
        XCTAssertTrue(model.groups.isEmpty)
        XCTAssertEqual(model.selectedTarget, .standalone("a"))
        XCTAssertEqual(model.revision, 0)
        XCTAssertEqual(model.saveCount, 0)
        XCTAssertEqual(model.addCard(to: "a"), .applied)
        let before = model.boards
        let cardPayload = try XCTUnwrap(model.beginDrag(kind: .card(ownerID: "a", referenceID: model.boards[0].cards[0].id)))
        model.failNextSave = true
        assertRejected(model.commit(cardPayload, to: .board("b")))
        XCTAssertEqual(model.boards, before)
        XCTAssertEqual(model.saveCount, 1)
        XCTAssertEqual(model.revision, 1)
    }

    func testProcessingAndWrongTargetTypesRejectWithoutMutation() throws {
        var busy = board("b")
        busy.isProcessing = true
        var processing = card("busy")
        processing.status = "Reconnecting"
        var model = PrototypeBoardDragModel(boards: [board("a", cards: [card("r"), processing]), busy], groups: [], selectedTarget: .standalone("a"))
        XCTAssertNil(model.beginDrag(kind: .card(ownerID: "a", referenceID: "busy")))
        XCTAssertNil(model.beginDrag(kind: .board("b")))
        let first = try XCTUnwrap(model.beginDrag(kind: .card(ownerID: "a", referenceID: "r")))
        assertRejected(model.commit(first, to: .board("b")))
        let second = try XCTUnwrap(model.beginDrag(kind: .board("a")))
        assertRejected(model.commit(second, to: .detach))
        XCTAssertEqual(model.boards[0].cards.map(\.id), ["r", "busy"])
        XCTAssertEqual(model.saveCount, 0)
    }
}
