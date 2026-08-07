import AppKit
import Combine
import SwiftUI

private final class QuickLauncherPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class QuickLauncherWindowController: NSObject, NSWindowDelegate {
    private let appState: WindowBoardAppState
    private let projector: QuickLauncherItemProjector
    private let executor: QuickLauncherActionExecutor
    private let panel: QuickLauncherPanel
    private var viewModel: QuickLauncherViewModel!
    private var hotKeyController: GlobalHotKeyController!
    private var cancellables: Set<AnyCancellable> = []

    init(appState: WindowBoardAppState) {
        self.appState = appState
        projector = QuickLauncherItemProjector(
            appState: appState,
            isAccessibilityTrusted: { AccessibilityWindowService().isTrusted() }
        )
        executor = QuickLauncherActionExecutor(appState: appState)
        panel = QuickLauncherPanel(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 430),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        super.init()

        viewModel = QuickLauncherViewModel(
            executeTarget: { [weak self] target in
                guard let self else {
                    throw QuickLauncherExecutionError.actionUnavailable("Quick Launcher is not available.")
                }
                try executor.execute(target)
            },
            onDismiss: { [weak self] in
                self?.orderOut()
            }
        )
        hotKeyController = GlobalHotKeyController { [weak self] in
            self?.toggle()
        }

        configurePanel()
        observeSourceChanges()
    }

    func start() {
        guard hotKeyController.registerDefaultShortcut() else {
            appState.session.statusMessage = "Command-Shift-Space is unavailable. Use Show Quick Launcher in the Status Item menu."
            return
        }
    }

    func toggle() {
        panel.isVisible ? dismiss() : show()
    }

    func show() {
        viewModel.present(items: projector.makeItems())
        positionPanel()
        panel.orderFrontRegardless()
        panel.makeKey()
        viewModel.requestSearchFocus()
    }

    func dismiss() {
        viewModel.dismiss()
    }

    func windowDidResignKey(_ notification: Notification) {
        guard panel.isVisible, !viewModel.isExecuting else { return }
        dismiss()
    }

    private func configurePanel() {
        panel.title = "WindowBoard Quick Launcher"
        panel.titleVisibility = .hidden
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false
        panel.worksWhenModal = true
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.animationBehavior = .utilityWindow
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: QuickLauncherView(viewModel: viewModel))
    }

    private func observeSourceChanges() {
        let refresh: () -> Void = { [weak self] in
            guard let self, panel.isVisible else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, panel.isVisible else { return }
                viewModel.updateItems(projector.makeItems())
            }
        }

        appState.workspaceStore.objectWillChange
            .sink(receiveValue: refresh)
            .store(in: &cancellables)
        appState.boardCompositionStore.objectWillChange
            .sink(receiveValue: refresh)
            .store(in: &cancellables)
        appState.session.objectWillChange
            .sink(receiveValue: refresh)
            .store(in: &cancellables)
        appState.objectWillChange
            .sink(receiveValue: refresh)
            .store(in: &cancellables)
    }

    private func positionPanel() {
        let mouseLocation = NSEvent.mouseLocation
        let targetScreen = NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let visibleFrame = targetScreen?.visibleFrame else { return }

        let panelSize = panel.frame.size
        let origin = NSPoint(
            x: visibleFrame.midX - (panelSize.width / 2),
            y: visibleFrame.midY - (panelSize.height / 2) + min(60, visibleFrame.height * 0.08)
        )
        panel.setFrameOrigin(origin)
    }

    private func orderOut() {
        panel.orderOut(nil)
    }
}
