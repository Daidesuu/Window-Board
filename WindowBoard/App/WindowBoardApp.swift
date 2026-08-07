import SwiftUI
import AppKit

@MainActor
private enum WindowBoardSharedObjects {
    static let appState = WindowBoardAppState()
    static let updateController = WindowBoardUpdateController()
    static let quickLauncherController = QuickLauncherWindowController(appState: appState)
    static let statusItemController = WindowBoardStatusItemController(
        appState: appState,
        showQuickLauncher: { quickLauncherController.show() },
        checkForUpdates: { updateController.checkForUpdates() }
    )
}

@main
struct WindowBoardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState: WindowBoardAppState

    init() {
        let appState = WindowBoardSharedObjects.appState
        _appState = StateObject(wrappedValue: appState)
    }

    var body: some Scene {
        WindowGroup("Window Board", id: "main") {
            ContentView(appState: appState)
                .frame(minWidth: 880, minHeight: 560)
        }
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView(appState: appState)
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    WindowBoardSharedObjects.updateController.checkForUpdates()
                }
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        _ = WindowBoardSharedObjects.statusItemController
        WindowBoardSharedObjects.quickLauncherController.start()
    }
}
