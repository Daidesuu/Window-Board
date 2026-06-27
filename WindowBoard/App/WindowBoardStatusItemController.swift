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
        appState.session.$activeWorkspaceID
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

        appState.session.$attachedWindows
            .combineLatest(appState.session.$minimizedWindows, appState.session.$isMinimizingUnattached, appState.session.$isRestoringMinimized)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.rebuildMenu()
            }
            .store(in: &cancellables)

        appState.session.$statusMessage
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.rebuildMenu()
            }
            .store(in: &cancellables)

        appState.session.$isLoadingWorkspace
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
            title: appState.session.isLoadingWorkspace ? "Status: Loading..." : "Status: \(appState.session.statusMessage)",
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
                item.state = workspace.id == appState.session.activeWorkspaceID ? .on : .off
                workspacesMenu.addItem(item)
            }
        }

        workspacesItem.submenu = workspacesMenu
        menu.addItem(workspacesItem)
        menu.addItem(NSMenuItem.separator())

        let bringItem = menuItem("Bring Attached To Front", action: #selector(bringAttachedToFront))
        bringItem.isEnabled = appState.session.canBringAttachedToFront
        menu.addItem(bringItem)

        let minimizeItem = menuItem("Minimize Unattached", action: #selector(minimizeUnattached))
        minimizeItem.isEnabled = appState.session.canMinimizeUnattached
        menu.addItem(minimizeItem)

        let restoreItem = menuItem("Restore Minimized", action: #selector(restoreMinimized))
        restoreItem.isEnabled = appState.session.canRestoreMinimized
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

        appState.session.switchWorkspace(
            id: workspaceID,
            boardOrigin: nil,
            source: .statusItem,
            followMode: appState.followMode
        )
    }

    @objc private func bringAttachedToFront() {
        appState.send(.bringAttachedToFront)
    }

    @objc private func minimizeUnattached() {
        appState.session.minimizeUnattachedWindows(knownWindows: [])
    }

    @objc private func restoreMinimized() {
        appState.session.restoreMinimizedWindows()
    }

    @objc private func openSettings() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
