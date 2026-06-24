import ApplicationServices
import CoreGraphics
import Foundation

struct WindowInfo: Identifiable {
    let id: String
    let appName: String
    let title: String
    let pid: pid_t
    let bundleIdentifier: String?
    let bundleURL: URL?
    let documentURL: URL?
    let axWindow: AXUIElement
    let windowNumber: CGWindowID?
    let position: CGPoint?

    var displayName: String {
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return appName
        }

        return "\(appName) - \(title)"
    }
}

struct AttachedWindow: Identifiable {
    let attachmentID: UUID
    var window: WindowInfo
    var lastBoardOrigin: CGPoint
    var lastWindowOrigin: CGPoint
    var lastAppliedOrigin: CGPoint?
    var pendingReleaseOrigin: CGPoint?

    init(
        attachmentID: UUID = UUID(),
        window: WindowInfo,
        lastBoardOrigin: CGPoint,
        lastWindowOrigin: CGPoint,
        lastAppliedOrigin: CGPoint?,
        pendingReleaseOrigin: CGPoint?
    ) {
        self.attachmentID = attachmentID
        self.window = window
        self.lastBoardOrigin = lastBoardOrigin
        self.lastWindowOrigin = lastWindowOrigin
        self.lastAppliedOrigin = lastAppliedOrigin
        self.pendingReleaseOrigin = pendingReleaseOrigin
    }

    var id: UUID {
        attachmentID
    }
}
