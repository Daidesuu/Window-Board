import AppKit
import SwiftUI

struct StatusMenuView: View {
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var appState: WindowBoardAppState
    @ObservedObject var workspaceStore: WorkspaceStore

    var body: some View {
        Button("Show Window") {
            showMainWindow()
        }

        Menu("Workspaces") {
            if workspaceStore.workspaces.isEmpty {
                Text("No Saved Workspaces")
            } else {
                ForEach(workspaceStore.workspaces) { workspace in
                    Button(workspaceMenuTitle(for: workspace)) {
                        appState.session.switchWorkspace(
                            id: workspace.id,
                            boardOrigin: nil,
                            source: .statusItem,
                            followMode: appState.followMode
                        )
                    }
                }
            }
        }

        Divider()

        Button("Bring Attached To Front") {
            showMainWindow()
            appState.send(.bringAttachedToFront)
        }
        .disabled(!appState.canBringAttachedToFront)

        Button("Minimize Unattached") {
            showMainWindow()
            appState.send(.minimizeUnattached)
        }
        .disabled(!appState.canMinimizeUnattached)

        Button("Restore Minimized") {
            showMainWindow()
            appState.send(.restoreMinimized)
        }
        .disabled(!appState.canRestoreMinimized)

        Divider()

        Button("Settings...") {
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        }

        Button("Quit WindowBoard") {
            NSApp.terminate(nil)
        }
    }

    private func showMainWindow() {
        if !appState.focusMainWindowIfAvailable() {
            openWindow(id: "main")
        }
    }

    private func workspaceMenuTitle(for workspace: SavedWorkspace) -> String {
        let prefix = appState.session.activeWorkspaceID == workspace.id ? "✓ " : "   "
        return prefix + workspace.displayName
    }
}
