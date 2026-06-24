import Foundation

enum PositionUpdateMode: String, CaseIterable, Identifiable {
    case manual = "Manual"
    case automatic = "Auto"

    var id: String { rawValue }
}
