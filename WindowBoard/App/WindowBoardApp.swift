import SwiftUI
import AppKit

@main
struct WindowBoardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = WindowBoardAppState()

    var body: some Scene {
        WindowGroup("Window Board", id: "main") {
            ContentView(appState: appState)
                .frame(minWidth: 360, minHeight: 420)
        }
        .windowResizability(.contentMinSize)

        MenuBarExtra("WindowBoard", systemImage: "rectangle.on.rectangle") {
            StatusMenuView(appState: appState, workspaceStore: appState.workspaceStore)
        }

        Settings {
            SettingsView(appState: appState)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}
