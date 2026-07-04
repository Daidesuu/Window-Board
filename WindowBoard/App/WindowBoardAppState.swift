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

struct NeverMinimizeApp: Identifiable, Hashable {
    let bundleIdentifier: String
    let displayName: String

    var id: String {
        bundleIdentifier
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
    @Published private(set) var neverMinimizeApps: [NeverMinimizeApp]

    private let defaults: UserDefaults
    private let neverMinimizeBundleIdentifiersKey = "neverMinimizeBundleIdentifiers"

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
        neverMinimizeApps = Self.loadNeverMinimizeApps(
            from: defaults,
            key: neverMinimizeBundleIdentifiersKey
        )
        syncNeverMinimizeAppsToSession()
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

    func isNeverMinimized(bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else {
            return false
        }

        return neverMinimizeApps.contains { $0.bundleIdentifier == bundleIdentifier }
    }

    func addNeverMinimizeApp(bundleIdentifier: String, displayName: String) {
        let resolvedDisplayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? Self.displayName(for: bundleIdentifier)
            : displayName

        if let index = neverMinimizeApps.firstIndex(where: { $0.bundleIdentifier == bundleIdentifier }) {
            neverMinimizeApps[index] = NeverMinimizeApp(
                bundleIdentifier: bundleIdentifier,
                displayName: resolvedDisplayName
            )
        } else {
            neverMinimizeApps.append(
                NeverMinimizeApp(
                    bundleIdentifier: bundleIdentifier,
                    displayName: resolvedDisplayName
                )
            )
        }

        neverMinimizeApps.sort {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
        persistNeverMinimizeApps()
        syncNeverMinimizeAppsToSession()
    }

    func removeNeverMinimizeApp(bundleIdentifier: String) {
        neverMinimizeApps.removeAll { $0.bundleIdentifier == bundleIdentifier }
        persistNeverMinimizeApps()
        syncNeverMinimizeAppsToSession()
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

    private func persistNeverMinimizeApps() {
        let bundleIdentifiers = neverMinimizeApps.map(\.bundleIdentifier).sorted()
        defaults.set(bundleIdentifiers, forKey: neverMinimizeBundleIdentifiersKey)
    }

    private func syncNeverMinimizeAppsToSession() {
        session.neverMinimizeBundleIdentifiers = Set(neverMinimizeApps.map(\.bundleIdentifier))
    }

    private static func loadNeverMinimizeApps(from defaults: UserDefaults, key: String) -> [NeverMinimizeApp] {
        let bundleIdentifiers = defaults.stringArray(forKey: key) ?? []
        let uniqueBundleIdentifiers = Array(Set(bundleIdentifiers)).sorted()

        return uniqueBundleIdentifiers.map {
            NeverMinimizeApp(
                bundleIdentifier: $0,
                displayName: displayName(for: $0)
            )
        }
    }

    private static func displayName(for bundleIdentifier: String) -> String {
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            return FileManager.default.displayName(atPath: appURL.path)
        }

        return bundleIdentifier
    }

}
