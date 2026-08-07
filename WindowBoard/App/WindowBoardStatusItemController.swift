import AppKit
import Combine

final class WindowBoardStatusItemController: NSObject {
    private let appState: WindowBoardAppState
    private let showQuickLauncherAction: () -> Void
    private let checkForUpdatesAction: () -> Void
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private var cancellables: Set<AnyCancellable> = []

    init(
        appState: WindowBoardAppState,
        showQuickLauncher: @escaping () -> Void = {},
        checkForUpdates: @escaping () -> Void = {}
    ) {
        self.appState = appState
        self.showQuickLauncherAction = showQuickLauncher
        self.checkForUpdatesAction = checkForUpdates
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        configureStatusItem()
        observeStateChanges()
        rebuildMenu()
    }

    private func configureStatusItem() {
        statusItem.menu = menu
        updateStatusItemImage()
    }

    private func observeStateChanges() {
        appState.session.$activeWorkspaceID
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.rebuildMenu()
            }
            .store(in: &cancellables)

        appState.session.$selectedWorkspaceID
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
        updateStatusItemImage()

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
        menu.addItem(menuItem("Show Quick Launcher", action: #selector(showQuickLauncher)))
        menu.addItem(NSMenuItem.separator())

        let workspacesItem = NSMenuItem(title: "Boards", action: nil, keyEquivalent: "")
        let workspacesMenu = NSMenu()
        workspacesMenu.autoenablesItems = false

        if appState.workspaceStore.workspaces.isEmpty {
            let emptyItem = NSMenuItem(title: "No Saved Boards", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            workspacesMenu.addItem(emptyItem)
        } else {
            let projection = appState.boardCompositionStore.sidebarProjection(
                workspaces: appState.workspaceStore.workspaces
            )
            for group in projection.groups {
                let primaryName = group.boards.first(where: { $0.id == group.primaryBoardID })?.name
                    ?? "Board Group"
                let item = NSMenuItem(title: primaryName, action: nil, keyEquivalent: "")
                let groupMenu = NSMenu()
                groupMenu.autoenablesItems = false
                for workspace in group.boards {
                    let memberItem = menuItem(workspace.displayName, action: #selector(loadWorkspace(_:)))
                    memberItem.representedObject = SidebarBoardSelection(
                        memberBoardID: workspace.id,
                        groupPrimaryID: group.primaryBoardID
                    )
                    memberItem.state = appState.session.activeWorkspaceID == group.primaryBoardID
                        && appState.session.selectedWorkspaceID == workspace.id ? .on : .off
                    groupMenu.addItem(memberItem)
                }
                item.submenu = groupMenu
                workspacesMenu.addItem(item)
            }
            if !projection.groups.isEmpty, !projection.standaloneBoards.isEmpty {
                workspacesMenu.addItem(.separator())
            }
            for workspace in projection.standaloneBoards {
                let item = menuItem(workspace.displayName, action: #selector(loadWorkspace(_:)))
                item.representedObject = SidebarBoardSelection(
                    memberBoardID: workspace.id,
                    groupPrimaryID: workspace.id
                )
                item.state = workspace.id == appState.session.activeWorkspaceID
                    && workspace.id == appState.session.selectedWorkspaceID ? .on : .off
                workspacesMenu.addItem(item)
            }
        }

        workspacesItem.submenu = workspacesMenu
        menu.addItem(workspacesItem)
        menu.addItem(NSMenuItem.separator())

        let bringItem = menuItem("Bring Board Windows To Front", action: #selector(bringAttachedToFront))
        bringItem.isEnabled = appState.session.canBringAttachedToFront
        menu.addItem(bringItem)

        let minimizeItem = menuItem("Minimize Others", action: #selector(minimizeUnattached))
        minimizeItem.isEnabled = appState.session.canMinimizeUnattached
        menu.addItem(minimizeItem)

        let restoreItem = menuItem("Restore Minimized", action: #selector(restoreMinimized))
        restoreItem.isEnabled = appState.session.canRestoreMinimized
        menu.addItem(restoreItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(menuItem("Settings...", action: #selector(openSettings)))
        menu.addItem(menuItem("Check for Updates...", action: #selector(checkForUpdates)))
        menu.addItem(menuItem("Quit WindowBoard", action: #selector(quit)))

        statusItem.menu = menu
    }

    private func updateStatusItemImage() {
        let symbolName = activeWorkspace?.statusItemSymbolName ?? WorkspaceStatusItemIcon.defaultSymbolName
        if let title = WorkspaceStatusItemIcon.title(from: symbolName) {
            statusItem.button?.image = nil
            statusItem.button?.title = title
            return
        }

        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "WindowBoard")
            ?? NSImage(systemSymbolName: WorkspaceStatusItemIcon.defaultSymbolName, accessibilityDescription: "WindowBoard")
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.title = ""
    }

    private var activeWorkspace: SavedWorkspace? {
        let displayedWorkspaceID = appState.session.selectedWorkspaceID ?? appState.session.activeWorkspaceID
        guard let displayedWorkspaceID else {
            return appState.workspaceStore.defaultWorkspace
        }

        return appState.workspaceStore.workspaces.first { $0.id == displayedWorkspaceID }
            ?? appState.workspaceStore.defaultWorkspace
    }

    private func menuItem(_ title: String, action: Selector?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func showWindow() {
        _ = appState.showMainWindow()
    }

    @objc private func showQuickLauncher() {
        showQuickLauncherAction()
    }

    @objc private func checkForUpdates() {
        checkForUpdatesAction()
    }

    @objc private func loadWorkspace(_ sender: NSMenuItem) {
        guard let selection = sender.representedObject as? SidebarBoardSelection else {
            return
        }

        if appState.session.activeWorkspaceID == selection.groupPrimaryID,
           appState.session.requestMemberSelection(
               memberBoardID: selection.memberBoardID,
               groupPrimaryID: selection.groupPrimaryID
           ) {
            return
        }

        appState.session.switchWorkspace(
            id: selection.groupPrimaryID,
            selectedBoardID: selection.memberBoardID,
            boardOrigin: nil,
            source: .statusItem,
            followMode: appState.followMode
        )
    }

    @objc private func bringAttachedToFront() {
        appState.send(.bringAttachedToFront)
    }

    @objc private func minimizeUnattached() {
        appState.session.minimizeUnattachedWindows(knownWindows: [], refreshWindowList: true)
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
