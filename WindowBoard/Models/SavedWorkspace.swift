import CoreGraphics
import Foundation

struct SavedWorkspace: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var createdAt: Date
    var updatedAt: Date
    var windows: [SavedWindowReference]

    var displayName: String {
        "\(name) (\(windows.count))"
    }
}

struct SavedWindowReference: Codable, Identifiable, Equatable {
    let id: UUID
    var displayName: String
    var appName: String
    var title: String
    var bundleIdentifier: String?
    var bundleURLString: String?
    var documentURLString: String?
    var workspaceURLString: String?
    var offsetX: CGFloat
    var offsetY: CGFloat
    var originX: CGFloat?
    var originY: CGFloat?
    var width: CGFloat?
    var height: CGFloat?

    var bundleURL: URL? {
        bundleURLString.flatMap(URL.init(string:))
    }

    var documentURL: URL? {
        documentURLString.flatMap(URL.init(string:))
    }

    var workspaceURL: URL? {
        workspaceURLString.flatMap(URL.init(string:))
    }

    var isVisualStudioCode: Bool {
        Self.isVisualStudioCode(bundleIdentifier: bundleIdentifier)
    }

    var canRestoreWindow: Bool {
        documentURL != nil || bundleURL != nil || bundleIdentifier != nil
    }

    var savedOrigin: CGPoint? {
        guard let originX, let originY else {
            return nil
        }

        return CGPoint(x: originX, y: originY)
    }

    var savedSize: CGSize? {
        guard let width, let height, width > 0, height > 0 else {
            return nil
        }

        return CGSize(width: width, height: height)
    }

    func targetOrigin(from boardOrigin: CGPoint) -> CGPoint {
        CGPoint(x: boardOrigin.x + offsetX, y: boardOrigin.y + offsetY)
    }

    func targetOrigin(from boardOrigin: CGPoint, useSavedOrigin: Bool) -> CGPoint {
        if useSavedOrigin, let originX, let originY {
            return CGPoint(x: originX, y: originY)
        }

        return targetOrigin(from: boardOrigin)
    }

    static func make(
        from attachedWindow: AttachedWindow,
        boardOrigin: CGPoint,
        size: CGSize? = nil
    ) -> SavedWindowReference {
        if var savedReference = attachedWindow.savedReference {
            savedReference.offsetX = attachedWindow.lastWindowOrigin.x - boardOrigin.x
            savedReference.offsetY = attachedWindow.lastWindowOrigin.y - boardOrigin.y
            savedReference.originX = attachedWindow.lastWindowOrigin.x
            savedReference.originY = attachedWindow.lastWindowOrigin.y
            savedReference.width = size?.width
            savedReference.height = size?.height
            return savedReference
        }

        let window = attachedWindow.window
        return SavedWindowReference(
            id: UUID(),
            displayName: window.displayName,
            appName: window.appName,
            title: window.title,
            bundleIdentifier: window.bundleIdentifier,
            bundleURLString: window.bundleURL?.absoluteString,
            documentURLString: window.documentURL?.absoluteString,
            workspaceURLString: nil,
            offsetX: attachedWindow.lastWindowOrigin.x - boardOrigin.x,
            offsetY: attachedWindow.lastWindowOrigin.y - boardOrigin.y,
            originX: attachedWindow.lastWindowOrigin.x,
            originY: attachedWindow.lastWindowOrigin.y,
            width: size?.width,
            height: size?.height
        )
    }

    static func isVisualStudioCode(bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else {
            return false
        }

        return [
            "com.microsoft.VSCode",
            "com.microsoft.VSCodeInsiders",
            "com.visualstudio.code.oss"
        ].contains(bundleIdentifier)
    }

}
