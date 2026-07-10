import SwiftUI

struct BoardToolbarState {
    let boardTitle: String
    let isTrusted: Bool
    let hasSelectedBoard: Bool
    let canAttachFrontmost: Bool
    let hasAttachedWindows: Bool
    let hasMinimizedWindows: Bool
    let hasRecoverableWindows: Bool
    let isMinimizing: Bool
    let isRestoring: Bool
    let hasKnownWindows: Bool
    let isLoadingWindows: Bool
    let canRestoreLayout: Bool

}

struct BoardToolbarActions {
    let createBoard: () -> Void
    let attachFrontmost: () -> Void
    let focusBoard: () -> Void
    let recoverMissing: () -> Void
    let minimizeOthers: () -> Void
    let restoreWindows: () -> Void
    let refreshWindowList: () -> Void
    let restoreLayout: () -> Void
    let removeAllWindows: () -> Void

}

struct BoardToolbarControls<SettingsContent: View>: ToolbarContent {
    let state: BoardToolbarState
    let actions: BoardToolbarActions
    @Binding var isSettingsPresented: Bool
    let settingsContent: SettingsContent

    init(
        state: BoardToolbarState,
        actions: BoardToolbarActions,
        isSettingsPresented: Binding<Bool>,
        @ViewBuilder settingsContent: () -> SettingsContent
    ) {
        self.state = state
        self.actions = actions
        _isSettingsPresented = isSettingsPresented
        self.settingsContent = settingsContent()
    }

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button(action: actions.createBoard) {
                Label("New Board", systemImage: "square.and.pencil")
                    .labelStyle(.iconOnly)
            }
            .help("New Board")
            .disabled(!state.isTrusted)

            BoardToolbarTitleBadge(title: state.boardTitle) {
                isSettingsPresented = true
            }
            .disabled(!state.hasSelectedBoard)
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Button(action: actions.attachFrontmost) {
                Label("Attach Window", systemImage: "plus.rectangle.on.rectangle")
                    .labelStyle(.iconOnly)
            }
            .help("Pin the frontmost window to this board")
            .disabled(!state.isTrusted || !state.canAttachFrontmost)

            Button(action: actions.focusBoard) {
                Label("Focus Board", systemImage: "scope")
                    .labelStyle(.iconOnly)
            }
            .help("Bring this board's pinned windows to the front")
            .disabled(!state.isTrusted || !state.hasAttachedWindows)

            if state.hasRecoverableWindows {
                Button(action: actions.recoverMissing) {
                    Label("Recover Missing", systemImage: "arrow.triangle.2.circlepath")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .help("Recover missing windows")
                .disabled(!state.isTrusted)
            }

            Button(action: actions.minimizeOthers) {
                Label("Minimize Others", systemImage: "minus.square")
                    .labelStyle(.iconOnly)
            }
            .help("Minimize windows not on this board")
            .disabled(!state.isTrusted || state.isMinimizing || state.isRestoring || !state.hasKnownWindows)

            Button(action: actions.restoreWindows) {
                Label("Restore Windows", systemImage: "arrow.counterclockwise")
                    .labelStyle(.iconOnly)
            }
            .help("Restore windows minimized by WindowBoard")
            .disabled(!state.isTrusted || state.isMinimizing || state.isRestoring || !state.hasMinimizedWindows)

            Menu {
                Button(action: actions.refreshWindowList) {
                    Label("Refresh Window List", systemImage: "arrow.clockwise")
                }
                .disabled(!state.isTrusted || state.isLoadingWindows)

                Button(action: actions.restoreLayout) {
                    Label("Restore Layout", systemImage: "arrow.counterclockwise")
                }
                .disabled(!state.canRestoreLayout)

                Divider()

                Button {
                    isSettingsPresented = true
                } label: {
                    Label("Board Settings", systemImage: "slider.horizontal.3")
                }
                .disabled(!state.hasSelectedBoard)

                Divider()

                Button(role: .destructive, action: actions.removeAllWindows) {
                    Label("Remove All Windows", systemImage: "xmark.circle")
                }
                .disabled(!state.hasAttachedWindows)
            } label: {
                Label("More", systemImage: "ellipsis.circle")
                    .labelStyle(.iconOnly)
            }
            .help("More board actions")
            .disabled(!state.isTrusted)
            .popover(isPresented: $isSettingsPresented, arrowEdge: .bottom) {
                settingsContent
            }
        }
    }
}

private struct BoardToolbarTitleBadge: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.title3.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .help("Board Settings")
        .accessibilityLabel(title)
    }
}
