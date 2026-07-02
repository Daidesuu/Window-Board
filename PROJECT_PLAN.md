# Window Board Project Plan

## Current Status

The original MVP is complete:

- A Window Board window can act as a board.
- A selected external window can be attached.
- Attached windows can follow board movement depending on Follow Mode.

The project is now in the post-MVP workspace/session manager phase. The app manages multiple external windows as reusable workspaces, with saved layout, Status Item switching, recovery, minimize/restore, and a card-board UI.

## Current Product Direction

Window Board is a macOS utility for grouping independent external application windows into a reusable working board.

It does not embed other apps' windows. External windows remain normal macOS windows and are controlled best-effort through Accessibility APIs.

The current user model is:

```text
Workspace / Board
 ├─ pinned Safari window
 ├─ pinned Terminal window
 ├─ pinned Finder window
 └─ Add Window card
```

The main UI should make the current workspace feel like a board of pinned windows, not a technical list of AX window references.

## Current Implementation

### Main Capabilities

- Multiple attached windows per workspace
- `Attach Window` / frontmost window attach
- Explicit window picker attach path
- Follow Mode: `None`, `Smooth`, `On Release`
- Position Update behavior
- Workspace save, create, rename, overwrite, delete, and switch
- Default workspace fallback
- Position and optional size save/restore
- Closed, stale, or minimized attached windows remain selected as recoverable state
- `Find or Reopen` best-effort recovery
- `Minimize Others` and `Restore Windows`
- `Minimize Unattached On Workspace Switch`
- `Restore Missing Windows On Workspace Switch`
- Status Item workspace switching and common actions
- Per-workspace Status Item display using SF Symbol, emoji, or short text
- Settings window for non-workspace behavior options

### Main UI

The main window uses `NavigationSplitView`:

- Sidebar: workspace list and `New Workspace`
- Detail: board header, pinned window card grid, secondary controls, status footer
- Toolbar: `Refresh`, `Attach Window`, `Focus Board`, `Minimize Others`, `Restore Windows`

Pinned windows are shown as app-tinted vertical cards with state-specific actions:

- `Available`: `Bring Forward`
- `Minimized`: `Restore Window`
- `Unavailable`: `Find or Reopen`
- `Reconnecting`: disabled `Finding...`

The trailing Add card is the primary quick path for adding the frontmost external window.

## Architecture

### `WindowBoardAppState`

Shared app-level state:

- `WorkspaceStore`
- `WorkspaceSessionController`
- shared settings
- main `NSWindow` reference
- Status Item controller wiring

### `WorkspaceSessionController`

The central workspace/session controller.

Responsibilities:

- active and selected workspace state
- attached window list
- unavailable and reconnecting state
- minimized window history
- workspace save/create/overwrite/rename/delete/switch
- layout restoration
- missing window recovery
- minimize/restore operations
- Status Item and main-window workspace switch shared path

Workspace switching must stay centralized here. Main window and Status Item callers should pass context such as board origin and cached windows instead of implementing separate switch logic.

### `ContentView`

Main-window behavior layer:

- Accessibility permission gate
- `NavigationSplitView` composition
- board window observation
- board transparency/chrome setup
- board movement and follow behavior
- frontmost app tracking
- attach actions
- status item commands
- card animation state

### `WindowBoardMainViews`

SwiftUI composition for the card-board UI:

- workspace sidebar
- board summary header
- pinned window card grid
- Add Window card
- workspace settings disclosure controls
- status footer

### `AccessibilityWindowService`

AX service for external windows:

- window discovery
- position and size reads/writes
- minimize and restore
- app activate and window raise
- best-effort open/reconnect from saved references

## Workspace Switch Behavior

Workspace switching is optimized for fast UI feedback first, then background AX work.

1. Save the active workspace state before switching.
2. Show placeholder attached windows immediately.
3. Resolve live windows from cached IDs and available window candidates.
4. Apply found windows back into the attached list as they are resolved.
5. Restore position and size where possible, skipping no-op updates.
6. If `Restore Missing Windows On Workspace Switch` is on, open/activate unresolved windows and poll as a group.
7. If it is off, keep unresolved windows attached as unavailable.
8. If `Minimize Unattached On Workspace Switch` is on, run minimize after the workspace is shown.
9. Automatic switch-time minimize reuses known candidate windows instead of always re-listing all windows.
10. Status Item switching uses the same controller path and should not open the Window Board window.

## Constraints

- macOS public APIs do not provide reliable strict z-order control for other apps' windows.
- Full-screen windows and windows on another Space are not reliable workspace targets.
- Window Board cannot force another app's existing window into the current Space through public APIs.
- System panels, special windows, and permission-limited windows may not be controllable.
- AX resize, move, minimize, restore, or raise may fail depending on the app.
- Closed windows cannot always be restored to the exact same document or internal state.
- `Minimize Others` is conservative to avoid minimizing attached windows by mistake.

## Near-Term Priorities

- Continue reducing AX work on hot paths.
- Keep workspace switching behavior consistent between main window and Status Item.
- Simplify dense `Workspace Settings` UI.
- Validate minimize/recovery behavior with common multi-window apps.
- Keep documentation aligned with the card-board UI and workspace/session architecture.
