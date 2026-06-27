# Window Board

Window Board is a macOS utility app for grouping external application windows into reusable workspaces.

Instead of embedding other apps' windows, Window Board keeps normal macOS windows independent and controls them through Accessibility APIs. A Window Board window acts as the reference point for attached windows, and saved workspaces can restore attached windows, positions, and sizes as a working session.

## Features

- Attach multiple external app windows
- Attach the frontmost external window
- Move attached windows with the Window Board window
- Follow modes: `None`, `Smooth`, and `On Release`
- Save, rename, overwrite, delete, and switch workspaces
- Restore saved window positions and sizes
- Reconnect closed, minimized, or stale attached windows where possible
- Bring attached windows to front
- Minimize unattached windows and restore minimized windows
- Optional minimize-unattached behavior on workspace switch
- macOS Status Item for workspace switching and common actions
- Settings window for behavior options

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
3. Select a window from the list or use `Attach Frontmost Window`.
4. Move the Window Board window to move attached windows, depending on Follow Mode.
5. Save the attached set as a workspace.
6. Switch workspaces from the main window or the macOS menu bar Status Item.

## Workspace Behavior

Workspace switching is designed to show the target workspace quickly and then finish heavier window operations in the background.

- Attached windows are shown as placeholders first.
- Live windows are matched from cache, fresh window lists, and best-effort reconnect polling.
- Closed or stale windows stay attached as recoverable/unavailable instead of being silently removed.
- Minimized windows are included in matching and restored where possible.
- Position and size restoration skip no-op updates when values are already close enough.
- `Minimize Unattached On Workspace Switch` runs after the workspace is shown.

## Architecture

- `WindowBoardAppState`: app-wide shared state and settings
- `WorkspaceSessionController`: workspace/session state, switching, reconnect, minimize/restore
- `ContentView`: main Window Board UI and board-window-dependent behavior
- `AccessibilityWindowService`: AX window discovery and operations
- `WorkspaceStore`: saved workspace persistence
- `WindowBoardStatusItemController`: macOS menu bar Status Item

## Limitations

Window Board depends on public macOS Accessibility APIs, so behavior is best-effort.

- Exact z-order cannot be fully guaranteed.
- Full-screen windows, windows on another Space, system panels, and special app windows may not be controllable.
- Some apps do not allow AX resize, move, minimize, restore, or raise.
- Closed windows cannot always be restored to the exact same document or internal app state.
- `Minimize Unattached` is conservative to avoid minimizing an attached window by mistake.

## Project Notes

The original MVP was a single selected window following the board window. That MVP is complete. The current app is a post-MVP workspace/session manager for multiple external windows.

See [PROJECT_PLAN.md](PROJECT_PLAN.md) for current behavior, architecture, constraints, and near-term priorities.
