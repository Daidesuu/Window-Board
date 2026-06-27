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

    private let defaults: UserDefaults

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

}
