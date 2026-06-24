import Foundation

enum BoardClickAction: String, CaseIterable, Identifiable {
    case none = "None"
    case bringAttachedToFront = "Bring Attached"

    var id: String { rawValue }
}
