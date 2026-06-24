import Foundation

enum AutoFrontMode: String, CaseIterable, Identifiable {
    case off = "Off"
    case allAttached = "All Attached"

    var id: String { rawValue }
}
