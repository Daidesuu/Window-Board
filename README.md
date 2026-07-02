# Window Board

Window Board is a macOS utility app for grouping external application windows into reusable workspaces.

Instead of embedding other apps' windows, Window Board keeps normal macOS windows independent and controls them through Accessibility APIs. A Window Board window acts as the reference point for attached windows, and saved workspaces can restore attached windows, positions, and sizes as a working session.

## Features

- Attach multiple external app windows
- Attach the frontmost external window from the toolbar or Add Window card
- Move attached windows with the Window Board window
- Follow modes: `None`, `Smooth`, and `On Release`
- Default workspace plus saved workspace creation, rename, overwrite, delete, and switch
- Restore saved window positions and sizes
- Reconnect closed, minimized, or stale attached windows where possible
- Bring pinned windows forward with `Focus Board`
- Minimize other windows and restore windows minimized by WindowBoard
- Optional minimize-unattached behavior on workspace switch
- Optional restore-missing behavior on workspace switch
- macOS Status Item for workspace switching and common actions
- Per-workspace Status Item display using an SF Symbol, emoji, or short text
- Settings window for behavior options
- Card-board UI with app-tinted pinned window cards

## Requirements

- macOS
- Xcode
- Accessibility permission for Window Board

Window Board needs Accessibility permission to read, move, resize, minimize, restore, and raise other apps' windows.

## Build And Run

Build with Xcode:

```bash
xcodebuild -project WindowBoard.xcodeproj -scheme WindowBoard -configuration Debug -derivedDataPath build/DerivedData build
```

Build and run with the project script:

```bash
./script/build_and_run.sh
```

Verify that the app launches:

```bash
./script/build_and_run.sh --verify
```

The built app is placed under:

```text
dist/WindowBoard.app
```

## Usage

1. Launch Window Board.
2. Grant Accessibility permission when prompted.
3. Use the Add Window card or toolbar `Attach Window` to pin the frontmost external window.
4. Use the explicit window picker in `Add Window` when you need to choose from a list.
5. Move the Window Board window to move attached windows, depending on Follow Mode.
6. Save or overwrite the current board as a workspace.
7. Switch workspaces from the main window sidebar or the macOS menu bar Status Item.

## Main UI

The main window is a workspace board:

- Sidebar: workspace list, active workspace indicator, Status Item glyph, and `New Workspace`.
- Board header: current workspace name, pinned count, attention count, `Recover Missing`, and `Restore Layout`.
- Board grid: pinned windows as app-tinted cards plus a trailing Add Window card.
- Status footer: current loading/minimize/restore feedback.

Pinned window card states:

- `Available`: `Bring Forward`
- `Minimized`: `Restore Window`
- `Unavailable`: `Find or Reopen`
- `Reconnecting`: disabled `Finding...`

## Workspace Behavior

Workspace switching is designed to show the target workspace quickly and then finish heavier window operations in the background.

- Attached windows are shown as placeholders first.
- Live windows are matched from cache, fresh window lists, and best-effort reconnect polling.
- Closed or stale windows stay attached as recoverable/unavailable instead of being silently removed.
- Minimized windows are included in matching and restored where possible.
- Position and size restoration skip no-op updates when values are already close enough.
- `Minimize Unattached On Workspace Switch` runs after the workspace is shown.
- Switch-time minimize reuses known candidate windows where possible instead of always re-listing all windows.
- `Restore Missing Windows On Workspace Switch` controls whether missing windows are automatically opened/activated during switching. When off, missing windows stay attached as unavailable until `Find or Reopen` is used.
- Status Item workspace switches save the previous workspace without opening the Window Board window.
- Attached window positions are snapshotted at low frequency so recently moved windows can be restored after close/reconnect where possible.

## Architecture

- `WindowBoardAppState`: app-wide shared state and settings
- `WorkspaceSessionController`: workspace/session state, switching, reconnect, minimize/restore
- `ContentView`: main window composition, board-window-dependent behavior, and command routing
- `WindowBoardMainViews`: card-board UI views and workspace controls
- `AccessibilityWindowService`: AX window discovery and operations
- `WorkspaceStore`: saved workspace persistence
- `WindowBoardStatusItemController`: macOS menu bar Status Item

## Limitations

Window Board depends on public macOS Accessibility APIs, so behavior is best-effort.

- Exact z-order cannot be fully guaranteed.
- Full-screen windows and windows on another Space are not supported as reliable workspace targets. Window Board cannot move another app's existing window into the current Space or control full-screen app Spaces through public macOS APIs.
- System panels and special app windows may not be controllable.
- Some apps do not allow AX resize, move, minimize, restore, or raise.
- Closed windows cannot always be restored to the exact same document or internal app state.
- `Minimize Unattached` is conservative to avoid minimizing an attached window by mistake.

## Project Notes

The original MVP was a single selected window following the board window. That MVP is complete. The current app is a post-MVP workspace/session manager for multiple external windows.

See [PROJECT_PLAN.md](PROJECT_PLAN.md) for current behavior, architecture, constraints, and near-term priorities.
