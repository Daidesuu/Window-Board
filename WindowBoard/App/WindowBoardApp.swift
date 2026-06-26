import SwiftUI
import AppKit

private enum WindowBoardSharedObjects {
    static let appState = WindowBoardAppState()
    static let statusItemController = WindowBoardStatusItemController(appState: appState)
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
                .frame(minWidth: 360, minHeight: 420)
        }
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView(appState: appState)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        _ = WindowBoardSharedObjects.statusItemController
    }
}
