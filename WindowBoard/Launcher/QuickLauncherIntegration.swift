import AppKit
import Foundation

enum QuickLauncherExecutionError: LocalizedError {
    case boardNotFound
    case windowNotFound
    case actionUnavailable(String)
    case operationInProgress

    var errorDescription: String? {
        switch self {
        case .boardNotFound:
            "Board not found."
        case .windowNotFound:
            "Saved window is no longer available."
        case let .actionUnavailable(message):
            message
        case .operationInProgress:
            "That action is already in progress."
        }
    }
}

@MainActor
struct QuickLauncherItemProjector {
    let appState: WindowBoardAppState
    let isAccessibilityTrusted: () -> Bool

    func makeItems() -> [QuickLauncherItem] {
        boardItems() + windowItems() + actionItems()
    }

    private func boardItems() -> [QuickLauncherItem] {
        let session = appState.session
        return session.boardSwitchTargets.enumerated().map { index, target in
            let isCurrent = target.primaryBoardID == session.activeWorkspaceID
            let isSelected = isCurrent && target.selectedBoardID == session.selectedWorkspaceID
            let badge: String
            if target.board.isDefault {
                badge = "Permanent"
            } else if isSelected {
                badge = "Current"
            } else if isCurrent && target.board.id == target.primaryBoardID {
                badge = "Primary"
            } else if isCurrent {
                badge = "Included"
            } else {
                badge = "Board"
            }
            let count = target.board.windows.count
            return QuickLauncherItem(
                id: "board:\(target.id)",
                kind: .board,
                title: target.board.name,
                subtitle: "\(count) \(count == 1 ? "window" : "windows")",
                keywords: [badge, "switch board"] + target.board.searchAliases,
                badge: badge,
                icon: .system(target.board.isDefault ? "pin.fill" : "rectangle.stack.fill"),
                target: .switchBoard(
                    primaryBoardID: target.primaryBoardID,
                    selectedMemberBoardID: target.selectedBoardID
                ),
                isCurrentBoardRelated: isCurrent,
                isSelectedBoardRelated: isSelected,
                fallbackOrder: index
            )
        }
    }

    private func windowItems() -> [QuickLauncherItem] {
        let session = appState.session
        let runtimeSnapshots = session.attachedWindowSessionSnapshots
        let runtimeReferenceIDs = Set(runtimeSnapshots.map(\.id))
        let runtimeItems = runtimeSnapshots.enumerated().compactMap { index, snapshot -> QuickLauncherItem? in
            guard let ownerBoardID = snapshot.ownerBoardID else { return nil }
            let action: QuickLauncherWindowAction
            let isEnabled: Bool
            switch snapshot.state {
            case .available:
                action = .bringForward
                isEnabled = true
            case .minimized:
                action = .restoreWindow
                isEnabled = true
            case .unavailable:
                action = .findOrReopen
                isEnabled = true
            case .resolving:
                action = .bringForward
                isEnabled = false
            case .reconnecting:
                action = .findOrReopen
                isEnabled = false
            }
            let attachment = session.attachedWindows.first { $0.id == snapshot.id }
            let title = snapshot.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return QuickLauncherItem(
                id: "window:\(snapshot.id.uuidString)",
                kind: .window,
                title: title.isEmpty ? snapshot.displayName : title,
                subtitle: [snapshot.appName, snapshot.ownerBoardName].compactMap { $0 }.joined(separator: " · "),
                keywords: [snapshot.appName, snapshot.ownerBoardName, snapshot.displayName].compactMap { $0 },
                badge: displayName(for: snapshot.state),
                icon: .application(
                    appName: snapshot.appName,
                    bundleURL: attachment?.window.bundleURL ?? attachment?.savedReference?.bundleURL,
                    bundleIdentifier: snapshot.bundleIdentifier
                ),
                target: .window(
                    windowReferenceID: snapshot.id,
                    ownerBoardID: ownerBoardID,
                    action: action
                ),
                secondaryAction: isEnabled ? QuickLauncherSecondaryAction(
                    title: "Detach",
                    systemImage: "rectangle.portrait.and.arrow.right",
                    target: .window(
                        windowReferenceID: snapshot.id,
                        ownerBoardID: ownerBoardID,
                        action: .detachFromBoard
                    )
                ) : nil,
                isEnabled: isEnabled,
                isCurrentBoardRelated: true,
                isSelectedBoardRelated: ownerBoardID == session.selectedWorkspaceID,
                fallbackOrder: index
            )
        }

        var inactiveItems: [QuickLauncherItem] = []
        var fallbackOrder = runtimeItems.count
        for board in appState.workspaceStore.workspaces {
            let boardTarget = session.boardSwitchTargets.first { $0.selectedBoardID == board.id }
                ?? BoardSwitchTarget(primaryBoardID: board.id, selectedBoardID: board.id, board: board)
            for reference in board.windows where !runtimeReferenceIDs.contains(reference.id) {
                let title = reference.title.trimmingCharacters(in: .whitespacesAndNewlines)
                inactiveItems.append(
                    QuickLauncherItem(
                        id: "saved-window:\(board.id.uuidString):\(reference.id.uuidString)",
                        kind: .window,
                        title: title.isEmpty ? reference.displayName : title,
                        subtitle: "\(reference.appName) · \(board.name)",
                        keywords: [reference.appName, reference.displayName, board.name],
                        badge: QuickLauncherWindowState.saved.rawValue,
                        icon: .application(
                            appName: reference.appName,
                            bundleURL: reference.bundleURL,
                            bundleIdentifier: reference.bundleIdentifier
                        ),
                        target: .switchBoard(
                            primaryBoardID: boardTarget.primaryBoardID,
                            selectedMemberBoardID: boardTarget.selectedBoardID
                        ),
                        isCurrentBoardRelated: false,
                        isSelectedBoardRelated: false,
                        fallbackOrder: fallbackOrder
                    )
                )
                fallbackOrder += 1
            }
        }
        return runtimeItems + inactiveItems
    }

    private func actionItems() -> [QuickLauncherItem] {
        let session = appState.session
        let trusted = isAccessibilityTrusted()
        let snapshots = session.attachedWindowSessionSnapshots
        let hasFocusTarget = snapshots.contains { $0.state == .available || $0.state == .minimized }
        let hasRecoverable = snapshots.contains { $0.state == .minimized || $0.state == .unavailable }

        let definitions: [(QuickLauncherActionID, String, String, String, Bool)] = [
            (.showWindow, "Show Window", "Open the main WindowBoard window", "macwindow", true),
            (.focusBoard, "Focus Board", "Bring Current Board windows forward", "scope", trusted && hasFocusTarget),
            (.restoreLayout, "Restore Layout", "Reapply the Current Board saved layout", "arrow.counterclockwise", trusted && session.activeWorkspaceID != nil && !session.isLoadingWorkspace && !session.isApplyingWorkspaceWindows),
            (.attachWindow, "Attach Window", "Attach the frontmost eligible window", "plus.rectangle.on.rectangle", trusted && session.activeWorkspaceID != nil && !session.isLoadingWorkspace),
            (.recoverMissing, "Recover Missing", "Find or reopen missing Current Board windows", "arrow.triangle.2.circlepath", trusted && hasRecoverable),
            (.minimizeOthers, "Minimize Others", "Minimize windows outside the Current Board", "minus.square", trusted && session.canMinimizeUnattached),
            (.restoreWindows, "Restore Windows", "Restore windows minimized by WindowBoard", "arrow.uturn.backward.square", trusted && session.canRestoreMinimized),
            (.refreshWindowList, "Refresh Window List", "Refresh external window candidates in the main window", "arrow.clockwise", trusted && appState.hasMainWindow)
        ]

        return definitions.enumerated().map { index, definition in
            QuickLauncherItem(
                id: "action:\(definition.0.rawValue)",
                kind: .action,
                title: definition.1,
                subtitle: definition.2,
                keywords: actionKeywords(for: definition.0),
                badge: "Action",
                icon: .system(definition.3),
                target: .action(definition.0),
                isEnabled: definition.4,
                isCurrentBoardRelated: definition.0 != .showWindow,
                fallbackOrder: index
            )
        }
    }

    private func displayName(for state: AttachedWindowSessionState) -> String {
        switch state {
        case .available: QuickLauncherWindowState.available.rawValue
        case .resolving: QuickLauncherWindowState.resolving.rawValue
        case .minimized: QuickLauncherWindowState.minimized.rawValue
        case .unavailable: QuickLauncherWindowState.unavailable.rawValue
        case .reconnecting: QuickLauncherWindowState.reconnecting.rawValue
        }
    }

    private func actionKeywords(for action: QuickLauncherActionID) -> [String] {
        switch action {
        case .showWindow: ["open main window", "WindowBoard"]
        case .focusBoard: ["front", "bring forward", "board windows"]
        case .restoreLayout: ["layout", "position", "size"]
        case .attachWindow: ["frontmost", "add window"]
        case .recoverMissing: ["find", "reopen", "unavailable"]
        case .minimizeOthers: ["hide other windows"]
        case .restoreWindows: ["restore minimized"]
        case .refreshWindowList: ["reload", "external windows"]
        }
    }
}

enum BoardWindowFrontingOperation {
    static func raise(
        _ windows: [AttachedWindow],
        serviceFactory: @escaping @Sendable () -> any ContentWindowOperating
    ) async {
        let service = serviceFactory()
        for attachedWindow in windows where attachedWindow.window.pid != 0 {
            guard !Task.isCancelled else { return }
            service.activateApplication(for: attachedWindow.window)
            await waitForFrontmostApplication(pid: attachedWindow.window.pid, timeout: 0.5)
            guard !Task.isCancelled else { return }
            try? await Task.sleep(for: .milliseconds(45))
            service.focusWindow(attachedWindow.window)
            service.raiseWindowOnly(attachedWindow.window)
            try? await Task.sleep(for: .milliseconds(65))
        }
    }

    private static func waitForFrontmostApplication(pid: pid_t, timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard !Task.isCancelled else { return }
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }
}

@MainActor
final class QuickLauncherActionCoordinator {
    private let appState: WindowBoardAppState
    private let serviceFactory: @Sendable () -> any ContentWindowOperating
    private let recoveryCoordinator: AttachedWindowRecoveryCoordinator
    private let frontingCoordinator = BoardFrontingCoordinator()
    private var inFlightKeys: Set<String> = []
    private var recoveryRevisionByAttachmentID: [AttachedWindow.ID: Int] = [:]

    init(
        appState: WindowBoardAppState,
        serviceFactory: @escaping @Sendable () -> any ContentWindowOperating = { AccessibilityWindowService() }
    ) {
        self.appState = appState
        self.serviceFactory = serviceFactory
        recoveryCoordinator = AttachedWindowRecoveryCoordinator(serviceFactory: serviceFactory)
    }

    func focusBoard() throws {
        let session = appState.session
        let windows = session.attachedWindows.filter {
            let state = session.attachedWindowSessionState(for: $0.id)
            return state == .available || state == .minimized
        }
        guard !windows.isEmpty else {
            throw QuickLauncherExecutionError.actionUnavailable("No available Current Board windows.")
        }
        try front(windows, key: "focus-board")
    }

    func activateWindow(id: AttachedWindow.ID) throws {
        let session = appState.session
        guard let attachedWindow = session.attachedWindows.first(where: { $0.id == id }) else {
            throw QuickLauncherExecutionError.windowNotFound
        }
        switch session.attachedWindowSessionState(for: id) {
        case .available:
            try front([attachedWindow], key: "window:\(id.uuidString)")
        case .minimized, .unavailable:
            try recoverWindow(id: id)
        case .resolving, .reconnecting:
            throw QuickLauncherExecutionError.operationInProgress
        }
    }

    func detachWindow(id: AttachedWindow.ID) throws {
        let session = appState.session
        guard let attachedWindow = session.attachedWindows.first(where: { $0.id == id }) else {
            throw QuickLauncherExecutionError.windowNotFound
        }
        switch session.attachedWindowSessionState(for: id) {
        case .resolving, .reconnecting:
            throw QuickLauncherExecutionError.operationInProgress
        case .available, .minimized, .unavailable:
            session.detachWindow(
                id: id,
                boardOrigin: appState.mainWindow?.frame.origin ?? attachedWindow.lastBoardOrigin
            )
        }
    }

    func recoverMissing() throws {
        let ids = appState.session.attachedWindowSessionSnapshots.compactMap { snapshot in
            snapshot.state == .minimized || snapshot.state == .unavailable ? snapshot.id : nil
        }
        guard !ids.isEmpty else {
            throw QuickLauncherExecutionError.actionUnavailable("No missing Current Board windows.")
        }
        for id in ids {
            try recoverWindow(id: id)
        }
    }

    func attachFrontmostWindow() throws {
        let key = "attach-window"
        try begin(key)
        guard let boardOrigin = appState.mainWindow?.frame.origin
                ?? appState.session.attachedWindows.first?.lastBoardOrigin else {
            end(key)
            throw QuickLauncherExecutionError.actionUnavailable("Show WindowBoard before attaching a window.")
        }

        let serviceFactory = serviceFactory
        let session = appState.session
        Task.detached(priority: .userInitiated) {
            let service = serviceFactory()
            guard service.isTrusted(), var window = service.frontmostVisibleExternalWindow() else {
                await MainActor.run {
                    session.statusMessage = "No attachable frontmost window found."
                    self.end(key)
                }
                return
            }
            if window.position == nil, let position = try? service.position(of: window) {
                window = window.updatingPosition(position)
            }
            let resolvedWindow = window
            let result = await MainActor.run {
                session.attachWindow(resolvedWindow, boardOrigin: boardOrigin)
            }
            if result.didAttach,
               let attachedWindow = await MainActor.run(body: {
                   session.attachedWindows.first { $0.window.id == resolvedWindow.id }
               }) {
                await BoardWindowFrontingOperation.raise([attachedWindow], serviceFactory: serviceFactory)
            }
            await MainActor.run { self.end(key) }
        }
    }

    private func front(_ windows: [AttachedWindow], key: String) throws {
        try begin(key)
        let serviceFactory = serviceFactory
        frontingCoordinator.frontAttachedWindows(
            count: windows.count,
            operation: {
                await BoardWindowFrontingOperation.raise(windows, serviceFactory: serviceFactory)
            },
            completion: {
                self.appState.session.statusMessage = "Brought \(windows.count) window(s) to front."
                self.end(key)
            }
        )
    }

    private func recoverWindow(id: AttachedWindow.ID) throws {
        let key = "recover:\(id.uuidString)"
        try begin(key)
        guard let attachedWindow = appState.session.attachedWindows.first(where: { $0.id == id }) else {
            end(key)
            throw QuickLauncherExecutionError.windowNotFound
        }
        let revision = (recoveryRevisionByAttachmentID[id] ?? 0) + 1
        recoveryRevisionByAttachmentID[id] = revision
        let state = appState.session.attachedWindowSessionState(for: id)
        appState.session.reconnectingAttachedWindowIDs.insert(id)
        appState.session.statusMessage = "Finding \(attachedWindow.window.appName)..."
        let coordinator = recoveryCoordinator
        Task.detached(priority: .userInitiated) {
            let result = await coordinator.recover(
                AttachedWindowRecoveryRequest(
                    originalWindow: attachedWindow.window,
                    savedReference: attachedWindow.savedReference,
                    shouldTryMinimizedRestore: state == .minimized
                )
            )
            await MainActor.run {
                self.applyRecoveryResult(
                    result,
                    attachmentID: id,
                    revision: revision,
                    key: key
                )
            }
        }
    }

    private func applyRecoveryResult(
        _ result: AttachedWindowRecoveryResult,
        attachmentID: AttachedWindow.ID,
        revision: Int,
        key: String
    ) {
        defer { end(key) }
        guard recoveryRevisionByAttachmentID[attachmentID] == revision,
              let index = appState.session.attachedWindows.firstIndex(where: { $0.id == attachmentID }) else {
            return
        }
        let session = appState.session
        var shouldFront = false
        switch result {
        case let .restoredOriginal(position):
            if let position {
                session.attachedWindows[index].lastWindowOrigin = position
                session.attachedWindows[index].lastAppliedOrigin = position
            }
            session.minimizedAttachedWindowIDs.remove(attachmentID)
            session.markAttachedWindowAvailable(attachmentID)
            session.statusMessage = "Restored \(session.attachedWindows[index].window.displayName)."
            shouldFront = true
        case let .alreadyConnected(position):
            session.attachedWindows[index].lastWindowOrigin = position
            session.attachedWindows[index].lastAppliedOrigin = position
            session.minimizedAttachedWindowIDs.remove(attachmentID)
            session.markAttachedWindowAvailable(attachmentID)
            session.statusMessage = "Restored \(session.attachedWindows[index].window.displayName)."
            shouldFront = true
        case let .reconnected(window, _):
            session.attachedWindows[index].window = window
            if let position = window.position {
                session.attachedWindows[index].lastWindowOrigin = position
                session.attachedWindows[index].lastAppliedOrigin = position
            }
            session.minimizedAttachedWindowIDs.remove(attachmentID)
            session.markAttachedWindowAvailable(attachmentID)
            session.statusMessage = "Reconnected \(window.displayName)."
            shouldFront = true
        case let .notMatched(issue, _):
            session.reconnectingAttachedWindowIDs.remove(attachmentID)
            session.markAttachedWindowUnavailable(attachmentID)
            session.statusMessage = issue.failureMessage
        case .cancelled:
            session.reconnectingAttachedWindowIDs.remove(attachmentID)
        }

        if shouldFront {
            _ = session.persistActiveWorkspaceSnapshot()
            let attachedWindow = session.attachedWindows[index]
            Task.detached(priority: .utility) { [serviceFactory] in
                await BoardWindowFrontingOperation.raise([attachedWindow], serviceFactory: serviceFactory)
            }
        }
    }

    private func begin(_ key: String) throws {
        guard inFlightKeys.insert(key).inserted else {
            throw QuickLauncherExecutionError.operationInProgress
        }
    }

    private func end(_ key: String) {
        inFlightKeys.remove(key)
    }

}

@MainActor
final class QuickLauncherActionExecutor {
    private let appState: WindowBoardAppState
    private let actionCoordinator: QuickLauncherActionCoordinator

    init(appState: WindowBoardAppState) {
        self.appState = appState
        actionCoordinator = QuickLauncherActionCoordinator(appState: appState)
    }

    func execute(_ target: QuickLauncherTarget) throws {
        switch target {
        case let .switchBoard(primaryBoardID, selectedMemberBoardID):
            guard let target = appState.session.boardSwitchTargets.first(where: {
                $0.primaryBoardID == primaryBoardID && $0.selectedBoardID == selectedMemberBoardID
            }) else {
                throw QuickLauncherExecutionError.boardNotFound
            }
            guard appState.session.switchWorkspaceFromLauncher(
                target,
                followMode: appState.followMode,
                candidateWindows: appState.freshLauncherWindowCandidates()
            ) else {
                throw QuickLauncherExecutionError.boardNotFound
            }

        case let .window(windowReferenceID, _, action):
            switch action {
            case .detachFromBoard:
                try actionCoordinator.detachWindow(id: windowReferenceID)
            case .bringForward, .restoreWindow, .findOrReopen:
                try actionCoordinator.activateWindow(id: windowReferenceID)
            }

        case let .action(action):
            try execute(action)
        }
    }

    private func execute(_ action: QuickLauncherActionID) throws {
        switch action {
        case .showWindow:
            guard appState.showMainWindow() else {
                throw QuickLauncherExecutionError.actionUnavailable("Could not open the main WindowBoard window.")
            }
        case .focusBoard:
            try actionCoordinator.focusBoard()
        case .restoreLayout:
            guard appState.session.restoreLayoutFromLauncher(
                followMode: appState.followMode,
                candidateWindows: appState.freshLauncherWindowCandidates()
            ) else {
                throw QuickLauncherExecutionError.actionUnavailable("The Current Board layout cannot be restored right now.")
            }
        case .attachWindow:
            try actionCoordinator.attachFrontmostWindow()
        case .recoverMissing:
            try actionCoordinator.recoverMissing()
        case .minimizeOthers:
            appState.session.minimizeUnattachedWindows(knownWindows: [], refreshWindowList: true)
        case .restoreWindows:
            appState.session.restoreMinimizedWindows()
        case .refreshWindowList:
            guard appState.showMainWindow() else {
                throw QuickLauncherExecutionError.actionUnavailable("Open WindowBoard to refresh the window list.")
            }
            DispatchQueue.main.async { self.appState.send(.refreshWindowList) }
        }
    }
}
