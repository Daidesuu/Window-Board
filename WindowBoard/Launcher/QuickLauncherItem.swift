import Foundation

enum QuickLauncherItemKind: String, CaseIterable, Codable, Equatable {
    case board
    case window
    case action

    var displayName: String {
        switch self {
        case .board: "Boards"
        case .window: "Windows"
        case .action: "Actions"
        }
    }
}

enum QuickLauncherWindowState: String, Codable, Equatable {
    case available = "Available"
    case resolving = "Resolving"
    case minimized = "Minimized"
    case unavailable = "Unavailable"
    case reconnecting = "Reconnecting"
    case saved = "Saved"
}

enum QuickLauncherActionID: String, Codable, Equatable {
    case showWindow
    case focusBoard
    case restoreLayout
    case attachWindow
    case recoverMissing
    case minimizeOthers
    case restoreWindows
    case refreshWindowList
}

enum QuickLauncherWindowAction: String, Codable, Equatable {
    case bringForward
    case restoreWindow
    case findOrReopen
    case detachFromBoard
}

enum QuickLauncherTarget: Equatable {
    case switchBoard(primaryBoardID: UUID, selectedMemberBoardID: UUID)
    case window(windowReferenceID: UUID, ownerBoardID: UUID, action: QuickLauncherWindowAction)
    case action(QuickLauncherActionID)
}

struct QuickLauncherSecondaryAction: Equatable {
    let title: String
    let systemImage: String
    let target: QuickLauncherTarget
}

enum QuickLauncherIcon: Equatable {
    case system(String)
    case application(appName: String, bundleURL: URL?, bundleIdentifier: String?)
}

struct QuickLauncherItem: Identifiable, Equatable {
    let id: String
    let kind: QuickLauncherItemKind
    let title: String
    let subtitle: String?
    let keywords: [String]
    let badge: String?
    let icon: QuickLauncherIcon
    let target: QuickLauncherTarget
    let secondaryAction: QuickLauncherSecondaryAction?
    let isEnabled: Bool
    let isCurrentBoardRelated: Bool
    let isSelectedBoardRelated: Bool
    let fallbackOrder: Int

    init(
        id: String,
        kind: QuickLauncherItemKind,
        title: String,
        subtitle: String? = nil,
        keywords: [String] = [],
        badge: String? = nil,
        icon: QuickLauncherIcon,
        target: QuickLauncherTarget,
        secondaryAction: QuickLauncherSecondaryAction? = nil,
        isEnabled: Bool = true,
        isCurrentBoardRelated: Bool = false,
        isSelectedBoardRelated: Bool = false,
        fallbackOrder: Int = 0
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.keywords = keywords
        self.badge = badge
        self.icon = icon
        self.target = target
        self.secondaryAction = secondaryAction
        self.isEnabled = isEnabled
        self.isCurrentBoardRelated = isCurrentBoardRelated
        self.isSelectedBoardRelated = isSelectedBoardRelated
        self.fallbackOrder = fallbackOrder
    }

    var searchableText: [String] {
        [title, subtitle].compactMap { $0 } + keywords
    }
}
