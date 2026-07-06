import AppKit
import Combine
import Foundation

enum WindowBoardStatusCommand {
    case showWindow
    case loadWorkspace(SavedWorkspace.ID)
    case bringAttachedToFront
    case minimizeUnattached
    case restoreMinimized
}

struct NeverMinimizeWindow: Codable, Identifiable, Hashable {
    let bundleIdentifier: String?
    let appName: String
    let title: String
    let documentURLString: String?
    let windowNumber: CGWindowID?
    let displayName: String

    var id: String {
        if let windowNumber {
            return "\(appName)-window-\(windowNumber)"
        }

        if let documentURLString {
            return "\(appName)-document-\(documentURLString)"
        }

        let appIdentity = bundleIdentifier ?? appName
        return "\(appIdentity)-title-\(title)"
    }

    var documentURL: URL? {
        documentURLString.flatMap(URL.init(string:))
    }

    init(window: WindowInfo) {
        bundleIdentifier = window.bundleIdentifier
        appName = window.appName
        title = window.title
        documentURLString = window.documentURL?.absoluteString
        windowNumber = window.windowNumber
        displayName = window.displayName
    }

    init(
        bundleIdentifier: String?,
        appName: String,
        title: String,
        documentURLString: String?,
        windowNumber: CGWindowID?,
        displayName: String
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.appName = appName
        self.title = title
        self.documentURLString = documentURLString
        self.windowNumber = windowNumber
        self.displayName = displayName
    }

    func matches(_ window: WindowInfo) -> Bool {
        if let windowNumber,
           let candidateWindowNumber = window.windowNumber,
           let bundleIdentifier,
           let candidateBundleIdentifier = window.bundleIdentifier,
           bundleIdentifier == candidateBundleIdentifier,
           windowNumber == candidateWindowNumber {
            return true
        }

        if let documentURL,
           let candidateDocumentURL = window.documentURL,
           documentURL == candidateDocumentURL {
            return true
        }

        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidateTitle = window.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty, !candidateTitle.isEmpty, trimmedTitle == candidateTitle else {
            return false
        }

        if let bundleIdentifier,
           let candidateBundleIdentifier = window.bundleIdentifier {
            return bundleIdentifier == candidateBundleIdentifier
        }

        return appName == window.appName
    }
}

final class WindowBoardAppState: ObservableObject {
    let workspaceStore: WorkspaceStore
    let session: WorkspaceSessionController
    let commandSubject = PassthroughSubject<WindowBoardStatusCommand, Never>()
    weak var mainWindow: NSWindow?

    @Published var followModeRawValue: String {
        didSet {
            defaults.set(followModeRawValue, forKey: "followMode")
            followMode = FollowMode(rawValue: followModeRawValue) ?? .none
        }
    }
    @Published var positionUpdateModeRawValue: String {
        didSet {
            defaults.set(positionUpdateModeRawValue, forKey: "positionUpdateMode")
            positionUpdateMode = PositionUpdateMode(rawValue: positionUpdateModeRawValue) ?? .manual
        }
    }
    @Published var autoFrontModeRawValue: String {
        didSet {
            defaults.set(autoFrontModeRawValue, forKey: "autoFrontMode")
            autoFrontMode = AutoFrontMode(rawValue: autoFrontModeRawValue) ?? .off
        }
    }
    @Published var boardClickActionRawValue: String {
        didSet {
            defaults.set(boardClickActionRawValue, forKey: "boardClickAction")
            boardClickAction = BoardClickAction(rawValue: boardClickActionRawValue) ?? .none
        }
    }

    @Published private(set) var followMode: FollowMode
    @Published private(set) var positionUpdateMode: PositionUpdateMode
    @Published private(set) var autoFrontMode: AutoFrontMode
    @Published private(set) var boardClickAction: BoardClickAction
    @Published private(set) var neverMinimizeWindows: [NeverMinimizeWindow]

    private let defaults: UserDefaults
    private let neverMinimizeWindowsKey = "neverMinimizeWindows"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let workspaceStore = WorkspaceStore(defaults: defaults)
        self.workspaceStore = workspaceStore
        self.session = WorkspaceSessionController(workspaceStore: workspaceStore, defaults: defaults)
        let storedFollowModeRawValue = defaults.string(forKey: "followMode") ?? FollowMode.none.rawValue
        let storedPositionUpdateModeRawValue = defaults.string(forKey: "positionUpdateMode") ?? PositionUpdateMode.manual.rawValue
        let storedAutoFrontModeRawValue = defaults.string(forKey: "autoFrontMode") ?? AutoFrontMode.off.rawValue
        let storedBoardClickActionRawValue = defaults.string(forKey: "boardClickAction") ?? BoardClickAction.none.rawValue

        followModeRawValue = storedFollowModeRawValue
        positionUpdateModeRawValue = storedPositionUpdateModeRawValue
        autoFrontModeRawValue = storedAutoFrontModeRawValue
        boardClickActionRawValue = storedBoardClickActionRawValue
        followMode = FollowMode(rawValue: storedFollowModeRawValue) ?? .none
        positionUpdateMode = PositionUpdateMode(rawValue: storedPositionUpdateModeRawValue) ?? .manual
        autoFrontMode = AutoFrontMode(rawValue: storedAutoFrontModeRawValue) ?? .off
        boardClickAction = BoardClickAction(rawValue: storedBoardClickActionRawValue) ?? .none
        neverMinimizeWindows = Self.loadNeverMinimizeWindows(
            from: defaults,
            key: neverMinimizeWindowsKey
        )
        syncNeverMinimizeWindowsToSession()
    }

    var canBringAttachedToFront: Bool {
        session.canBringAttachedToFront
    }

    var canMinimizeUnattached: Bool {
        session.canMinimizeUnattached
    }

    var canRestoreMinimized: Bool {
        session.canRestoreMinimized
    }

    var hasVisibleMainWindow: Bool {
        mainWindow?.isVisible == true || existingMainWindow?.isVisible == true
    }

    var hasMainWindow: Bool {
        mainWindow != nil || existingMainWindow != nil
    }

    func send(_ command: WindowBoardStatusCommand) {
        commandSubject.send(command)
    }

    func isNeverMinimized(window: WindowInfo) -> Bool {
        neverMinimizeWindows.contains { $0.matches(window) }
    }

    func addNeverMinimizeWindow(_ window: WindowInfo) {
        let neverMinimizeWindow = NeverMinimizeWindow(window: window)

        if let index = neverMinimizeWindows.firstIndex(where: { $0.matches(window) }) {
            neverMinimizeWindows[index] = neverMinimizeWindow
        } else {
            neverMinimizeWindows.append(neverMinimizeWindow)
        }

        neverMinimizeWindows.sort {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
        persistNeverMinimizeWindows()
        syncNeverMinimizeWindowsToSession()
    }

    func removeNeverMinimizeWindow(id: NeverMinimizeWindow.ID) {
        neverMinimizeWindows.removeAll { $0.id == id }
        persistNeverMinimizeWindows()
        syncNeverMinimizeWindowsToSession()
    }

    @discardableResult
    func focusMainWindowIfAvailable() -> Bool {
        NSApp.activate(ignoringOtherApps: true)

        if let mainWindow {
            mainWindow.makeKeyAndOrderFront(nil)
            return true
        }

        if let window = existingMainWindow {
            mainWindow = window
            window.makeKeyAndOrderFront(nil)
            return true
        }

        return false
    }

    private var existingMainWindow: NSWindow? {
        NSApp.windows.first { window in
            window.title == "Window Board"
        }
    }

    private func persistNeverMinimizeWindows() {
        guard let data = try? JSONEncoder().encode(neverMinimizeWindows) else {
            return
        }

        defaults.set(data, forKey: neverMinimizeWindowsKey)
    }

    private func syncNeverMinimizeWindowsToSession() {
        session.neverMinimizeWindows = neverMinimizeWindows
    }

    private static func loadNeverMinimizeWindows(from defaults: UserDefaults, key: String) -> [NeverMinimizeWindow] {
        guard let data = defaults.data(forKey: key),
              let windows = try? JSONDecoder().decode([NeverMinimizeWindow].self, from: data) else {
            return []
        }

        return windows
    }

}
