import CoreGraphics
import Foundation

struct SavedWorkspace: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var searchAliases: [String]
    var statusItemSymbolName: String?
    var createdAt: Date
    var updatedAt: Date
    var windows: [SavedWindowReference]
    var isDefault: Bool

    init(
        id: UUID,
        name: String,
        searchAliases: [String] = [],
        statusItemSymbolName: String?,
        createdAt: Date,
        updatedAt: Date,
        windows: [SavedWindowReference],
        isDefault: Bool = false
    ) {
        self.id = id
        self.name = name
        self.searchAliases = searchAliases
        self.statusItemSymbolName = statusItemSymbolName
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.windows = windows
        self.isDefault = isDefault
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case searchAliases
        case statusItemSymbolName
        case createdAt
        case updatedAt
        case windows
        case isDefault
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        searchAliases = try container.decodeIfPresent([String].self, forKey: .searchAliases) ?? []
        statusItemSymbolName = try container.decodeIfPresent(String.self, forKey: .statusItemSymbolName)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        windows = try container.decode([SavedWindowReference].self, forKey: .windows)
        isDefault = try container.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
    }

    var displayName: String {
        "\(name) - \(windows.count) \(windows.count == 1 ? "window" : "windows")"
    }
}

struct WorkspaceStatusItemIcon: Identifiable, Equatable {
    let symbolName: String
    let label: String

    var id: String {
        symbolName
    }

    static let defaultSymbolName = "rectangle.on.rectangle"
    static let emojiPrefix = "emoji:"
    static let textPrefix = "text:"

    static let options: [WorkspaceStatusItemIcon] = [
        WorkspaceStatusItemIcon(symbolName: defaultSymbolName, label: "Default"),
        WorkspaceStatusItemIcon(symbolName: "square.grid.2x2", label: "Grid"),
        WorkspaceStatusItemIcon(symbolName: "macwindow", label: "Window"),
        WorkspaceStatusItemIcon(symbolName: "doc.text", label: "Document"),
        WorkspaceStatusItemIcon(symbolName: "terminal", label: "Terminal"),
        WorkspaceStatusItemIcon(symbolName: "globe", label: "Web"),
        WorkspaceStatusItemIcon(symbolName: "briefcase", label: "Work"),
        WorkspaceStatusItemIcon(symbolName: "folder", label: "Folder"),
        WorkspaceStatusItemIcon(symbolName: "star", label: "Star")
    ]

    static let emojiOptions: [WorkspaceStatusItemIcon] = [
        WorkspaceStatusItemIcon(symbolName: "emoji:💼", label: "Briefcase"),
        WorkspaceStatusItemIcon(symbolName: "emoji:📁", label: "Folder"),
        WorkspaceStatusItemIcon(symbolName: "emoji:💻", label: "Laptop"),
        WorkspaceStatusItemIcon(symbolName: "emoji:🌐", label: "Web"),
        WorkspaceStatusItemIcon(symbolName: "emoji:📝", label: "Notes"),
        WorkspaceStatusItemIcon(symbolName: "emoji:⭐️", label: "Star"),
        WorkspaceStatusItemIcon(symbolName: "emoji:🚀", label: "Rocket"),
        WorkspaceStatusItemIcon(symbolName: "emoji:🔧", label: "Tools"),
        WorkspaceStatusItemIcon(symbolName: "emoji:🎨", label: "Design"),
        WorkspaceStatusItemIcon(symbolName: "emoji:📊", label: "Chart")
    ]

    var isEmoji: Bool {
        symbolName.hasPrefix(Self.emojiPrefix)
    }

    var emoji: String? {
        guard isEmoji else {
            return nil
        }

        return String(symbolName.dropFirst(Self.emojiPrefix.count))
    }

    static func emoji(from symbolName: String?) -> String? {
        guard let symbolName,
              symbolName.hasPrefix(emojiPrefix) else {
            return nil
        }

        return String(symbolName.dropFirst(emojiPrefix.count))
    }

    static func text(from symbolName: String?) -> String? {
        guard let symbolName,
              symbolName.hasPrefix(textPrefix) else {
            return nil
        }

        return String(symbolName.dropFirst(textPrefix.count))
    }

    static func title(from symbolName: String?) -> String? {
        emoji(from: symbolName) ?? text(from: symbolName)
    }

    static func label(for symbolName: String?) -> String {
        guard let symbolName else {
            return "Default"
        }

        if let option = options.first(where: { $0.symbolName == symbolName }) {
            return option.label
        }

        if let option = emojiOptions.first(where: { $0.symbolName == symbolName }) {
            return option.label
        }

        return title(from: symbolName) ?? symbolName
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
            let window = attachedWindow.window
            savedReference.displayName = window.displayName
            savedReference.appName = window.appName
            savedReference.title = window.title
            savedReference.bundleIdentifier = window.bundleIdentifier
            savedReference.bundleURLString = window.bundleURL?.absoluteString
            savedReference.documentURLString = window.documentURL?.absoluteString
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
            id: attachedWindow.id,
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

    static func makePreservingOffset(
        from attachedWindow: AttachedWindow,
        size: CGSize? = nil
    ) -> SavedWindowReference {
        if var savedReference = attachedWindow.savedReference {
            let window = attachedWindow.window
            savedReference.displayName = window.displayName
            savedReference.appName = window.appName
            savedReference.title = window.title
            savedReference.bundleIdentifier = window.bundleIdentifier
            savedReference.bundleURLString = window.bundleURL?.absoluteString
            savedReference.documentURLString = window.documentURL?.absoluteString
            savedReference.originX = attachedWindow.lastWindowOrigin.x
            savedReference.originY = attachedWindow.lastWindowOrigin.y
            if let size {
                savedReference.width = size.width
                savedReference.height = size.height
            }
            return savedReference
        }

        return make(
            from: attachedWindow,
            boardOrigin: attachedWindow.lastBoardOrigin,
            size: size
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
