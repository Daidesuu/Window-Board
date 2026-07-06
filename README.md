# Window Board

Window Board is a macOS utility app for organizing normal app windows into reusable boards.

It does not embed other apps. External windows remain regular macOS windows, and Window Board controls them through Accessibility APIs for best-effort discovery, movement, resize, minimize, restore, and fronting.

## Features

- Pin multiple external app windows to a board
- Add the frontmost external window from the toolbar or Add Window card
- Save, rename, overwrite, delete, and switch boards
- Restore saved window positions and sizes
- Optional follow modes: `None`, `Smooth`, and `On Release`
- Reconnect closed, minimized, or stale windows where macOS/app behavior allows it
- Main Board for windows that belong only to the selected board
- Permanent Board for windows that should be protected across all boards
- Move cards between Main Board and Permanent Board with drag and drop
- Bring a window forward from its card
- Double-click a card's icon area to bring the window forward and place it below the cursor
- Minimize other windows and restore windows minimized by Window Board
- Optional minimize-other-windows behavior when switching boards
- Optional restore-missing-windows behavior when switching boards
- macOS menu bar Status Item for board switching and common actions
- Per-board Status Item display using an SF Symbol, emoji, or short text
- Settings window for behavior options

## Requirements

- macOS
- Xcode
- Accessibility permission for Window Board

Window Board needs Accessibility permission to read and control other apps' windows. Without that permission, the app can launch but cannot list, move, resize, minimize, restore, or raise external windows.

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
4. Use the board sidebar to switch between saved boards.
5. Use `Board Settings` to save, overwrite, rename, delete, or configure the selected board.
6. Drag a Main Board card to Permanent Board when the window should be protected across all boards.
7. Drag a Permanent Board card back to Main Board when it should belong only to the selected board.

## Main UI

The main window is a card board.

- Sidebar: saved boards, active board indicator, Status Item glyph, and `New Board`.
- Header: selected board name, pinned count, attention count, `Recover Missing`, `Restore Layout`, and `Board Settings`.
- Main Board: windows attached only to the selected board, plus an Add Window card.
- Permanent Board: windows protected across all boards, plus an Add to Permanent Board card.
- Status footer: current loading, minimize, restore, reconnect, and feedback messages.

Card states:

- `Available`: the window is currently accessible.
- `Minimized`: the window is minimized and can be restored.
- `Unavailable`: the saved window is not currently matched.
- `Reconnecting`: Window Board is trying to find or reopen the saved window.

## Board Behavior

Board switching is designed to show the target board quickly, then finish heavier window operations in the background.

- Saved windows may appear as placeholders before every AX operation has finished.
- Live windows are matched from cached windows, fresh window lists, and best-effort reconnect checks.
- Closed or stale windows stay on the board as recoverable/unavailable instead of being silently removed.
- Minimized windows are included in matching and restored where possible.
- Position and size restoration skip no-op updates when values are already close enough.
- `Minimize Others When Switching Boards` runs after the target board is shown.
- Switch-time minimize reuses known candidate windows where possible instead of always re-listing all windows.
- `Restore Missing Windows When Switching Boards` controls whether missing windows are automatically opened or activated during switching.
- When automatic restore is off, missing windows stay unavailable until explicit recovery is used.
- Status Item board switches save the previous board without opening the Window Board window.
- Window positions are snapshotted at low frequency so recently moved windows can be restored after close/reconnect where possible.

## Permanent Board

Permanent Board is global. It is not saved per board.

Windows on Permanent Board are protected from `Minimize Others` and from automatic minimize when switching boards. Permanent Board is window-based rather than app-based, so adding one window should not protect every window from the same app.

Because macOS window identity can change after close/reopen, matching is best-effort using available window metadata such as app identity, title, document URL, process ID, and window number.

## Architecture

- `WindowBoardAppState`: app-wide shared state and settings
- `WorkspaceSessionController`: board/session state, switching, reconnect, minimize/restore
- `ContentView`: main window composition, board-window-dependent behavior, and command routing
- `WindowBoardMainViews`: card-board UI views and board controls
- `AccessibilityWindowService`: AX window discovery and operations
- `WorkspaceStore`: saved board persistence
- `WindowBoardStatusItemController`: macOS menu bar Status Item

Some internal type and file names still use `Workspace` because the app evolved from a workspace-based MVP. The current user-facing concept is `Board`.

## Limitations

Window Board depends on public macOS Accessibility APIs, so behavior is best-effort.

- Exact z-order cannot be fully guaranteed.
- Full-screen windows and windows on another Space are not reliable board targets.
- Window Board cannot move another app's existing window into the current Space through public macOS APIs.
- System panels and special app windows may not be controllable.
- Some apps do not allow AX resize, move, minimize, restore, or raise.
- Closed windows cannot always be restored to the exact same document or internal app state.
- Window matching after reopen is best-effort, especially for apps with multiple similar windows.
- `Minimize Others` is conservative to avoid minimizing a protected or attached window by mistake.

## Project Notes

The original MVP was a single selected window following the Window Board window. That MVP is complete. The current app is a post-MVP board/session manager for multiple external windows.

See [PROJECT_PLAN.md](PROJECT_PLAN.md) for current behavior, architecture, constraints, and near-term priorities.
