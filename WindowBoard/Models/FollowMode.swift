import Foundation

enum FollowMode: String, CaseIterable, Identifiable {
    case none = "None"
    case onRelease = "On Release"
    case animatedRelease = "Animated Release"
    case smooth = "Smooth"

    var id: String { rawValue }
}
