import Foundation
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let windowBoardTreeBoard = UTType(
        exportedAs: "com.local.WindowBoard.TreeExperimental.board"
    )
    static let windowBoardTreeWindow = UTType(
        exportedAs: "com.local.WindowBoard.TreeExperimental.window"
    )
}

struct TreeBoardDragPayload: Codable, Hashable, Transferable {
    let boardID: SavedWorkspace.ID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .windowBoardTreeBoard)
    }
}

struct TreeWindowDragPayload: Codable, Hashable, Transferable {
    let referenceID: SavedWindowReference.ID
    let sourceBoardID: SavedWorkspace.ID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .windowBoardTreeWindow)
    }
}

struct TreeFavoriteDragPayload: Codable, Hashable, Transferable {
    let boardID: SavedWorkspace.ID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .windowBoardTreeFavorite)
    }
}

extension UTType {
    static let windowBoardTreeFavorite = UTType(
        exportedAs: "com.local.WindowBoard.TreeExperimental.favorite"
    )
}
