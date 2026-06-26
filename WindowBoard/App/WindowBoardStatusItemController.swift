import AppKit
import Combine

final class WindowBoardStatusItemController: NSObject {
    private let appState: WindowBoardAppState
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private var cancellables: Set<AnyCancellable> = []

    init(appState: WindowBoardAppState) {
        self.appState = appState
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        configureStatusItem()
        observeStateChanges()
        rebuildMenu()
    }

    private func configureStatusItem() {
        statusItem.button?.image = NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: "WindowBoard")
        statusItem.button?.title = ""
        statusItem.menu = menu
    }

    private func observeStateChanges() {
        appState.$activeWorkspaceID
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.rebuildMenu()
            }
            .store(in: &cancellables)

        appState.workspaceStore.$workspaces
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.rebuildMenu()
            }
            .store(in: &cancellables)

        appState.$hasAttachedWindows
            .combineLatest(appState.$hasMinimizedWindows, appState.$isMinimizingUnattached, appState.$isRestoringMinimized)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.rebuildMenu()
            }
            .store(in: &cancellables)

        appState.$statusItemMessage
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.rebuildMenu()
            }
            .store(in: &cancellables)

        appState.$isLoadingWorkspaceFromStatusItem
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.rebuildMenu()
            }
            .store(in: &cancellables)
    }

    private func rebuildMenu() {
        menu.removeAllItems()
        menu.autoenablesItems = false

        let statusItem = NSMenuItem(
            title: appState.isLoadingWorkspaceFromStatusItem ? "Status: Loading..." : "Status: \(appState.statusItemMessage)",
            action: nil,
            keyEquivalent: ""
        )
        statusItem.isEnabled = false
        menu.addItem(statusItem)
        menu.addItem(NSMenuItem.separator())

        menu.addItem(menuItem("Show Window", action: #selector(showWindow)))
        menu.addItem(NSMenuItem.separator())

        let workspacesItem = NSMenuItem(title: "Workspaces", action: nil, keyEquivalent: "")
        let workspacesMenu = NSMenu()
        workspacesMenu.autoenablesItems = false

        if appState.workspaceStore.workspaces.isEmpty {
            let emptyItem = NSMenuItem(title: "No Saved Workspaces", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            workspacesMenu.addItem(emptyItem)
        } else {
            for workspace in appState.workspaceStore.workspaces {
                let item = menuItem(workspace.displayName, action: #selector(loadWorkspace(_:)))
                item.representedObject = workspace.id
                item.state = workspace.id == appState.activeWorkspaceID ? .on : .off
                workspacesMenu.addItem(item)
            }
        }

        workspacesItem.submenu = workspacesMenu
        menu.addItem(workspacesItem)
        menu.addItem(NSMenuItem.separator())

        let bringItem = menuItem("Bring Attached To Front", action: #selector(bringAttachedToFront))
        bringItem.isEnabled = appState.canBringAttachedToFront
        menu.addItem(bringItem)

        let minimizeItem = menuItem("Minimize Unattached", action: #selector(minimizeUnattached))
        minimizeItem.isEnabled = appState.canMinimizeUnattached
        menu.addItem(minimizeItem)

        let restoreItem = menuItem("Restore Minimized", action: #selector(restoreMinimized))
        restoreItem.isEnabled = appState.canRestoreMinimized
        menu.addItem(restoreItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(menuItem("Settings...", action: #selector(openSettings)))
        menu.addItem(menuItem("Quit WindowBoard", action: #selector(quit)))

        statusItem.menu = menu
    }

    private func menuItem(_ title: String, action: Selector?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func showWindow() {
        appState.send(.showWindow)
    }

    @objc private func loadWorkspace(_ sender: NSMenuItem) {
        guard let workspaceID = sender.representedObject as? SavedWorkspace.ID else {
            return
        }

        appState.loadWorkspaceFromStatusItem(id: workspaceID)
    }

    @objc private func bringAttachedToFront() {
        appState.send(.bringAttachedToFront)
    }

    @objc private func minimizeUnattached() {
        if appState.hasVisibleMainWindow {
            appState.send(.minimizeUnattached)
        } else {
            appState.minimizeUnattachedFromStatusItem()
        }
    }

    @objc private func restoreMinimized() {
        if appState.hasVisibleMainWindow {
            appState.send(.restoreMinimized)
        } else {
            appState.restoreMinimizedFromStatusItem()
        }
    }

    @objc private func openSettings() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
