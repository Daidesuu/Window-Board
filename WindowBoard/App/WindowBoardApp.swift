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
        guard !WindowBoardLaunchMode.isSplitPrototype else { return }
        _ = WindowBoardSharedObjects.statusItemController
        WindowBoardSharedObjects.quickLauncherController.start()
    }
}

// Branch before SwiftUI constructs any production scenes or shared state.
@main
@MainActor
private enum WindowBoardEntryPoint {
    static func main() {
        if WindowBoardLaunchMode.isSplitPrototype {
            SplitBoardPrototypeApp.main()
        } else {
            WindowBoardApp.main()
        }
    }
}

private enum WindowBoardLaunchMode {
    static let isSplitPrototype = ProcessInfo.processInfo.arguments.contains("--split-prototype")
        || Bundle.main.object(forInfoDictionaryKey: "WindowBoardSplitPrototype") as? Bool == true
}

private struct SplitBoardPrototypeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("WindowBoard — 分割UI試作", id: "split-prototype") {
            SplitBoardPrototypeView()
                .frame(minWidth: 620, minHeight: 420)
        }
        .defaultSize(width: 1100, height: 720)
        .windowResizability(.contentMinSize)
    }
}
