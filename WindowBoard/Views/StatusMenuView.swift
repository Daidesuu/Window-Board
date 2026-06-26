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
                    Button {
                        showMainWindow()
                        appState.send(.loadWorkspace(workspace.id))
                    } label: {
                        Label(
                            workspace.displayName,
                            systemImage: appState.activeWorkspaceID == workspace.id ? "checkmark" : ""
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
}
