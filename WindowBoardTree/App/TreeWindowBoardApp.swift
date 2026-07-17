import AppKit
import SwiftUI

@main
struct TreeWindowBoardApp: App {
    @NSApplicationDelegateAdaptor(TreeAppDelegate.self) private var appDelegate
    @StateObject private var appState = TreeWindowBoardAppState()

    var body: some Scene {
        WindowGroup("WindowBoard Tree") {
            TreeContentView(appState: appState)
                .frame(minWidth: 720, minHeight: 480)
        }
        .windowResizability(.contentMinSize)

        Settings {
            TreeSettingsView()
        }
    }
}

final class TreeAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}
