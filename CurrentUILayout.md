# WindowBoard Current UI Layout Summary

WindowBoard is a macOS SwiftUI app. The current main window uses a `NavigationSplitView`, but the detail area is no longer a table/list inspector. The active design direction is a card-board UI where pinned external windows are shown as app-tinted vertical cards.

## Root

```swift
NavigationSplitView {
    WorkspaceSidebarView(...)
} detail: {
    WorkspaceDetailView(...)
}
.toolbar {
    Refresh
    Attach Window
    Focus Board
    Minimize Others
    Restore Windows
}
```

When Accessibility permission is missing, the split view is replaced by the permission screen.

## Sidebar: `WorkspaceSidebarView`

Purpose:

- Shows saved workspaces.
- Shows which workspace is active.
- Displays each workspace's Status Item glyph/icon and window count.
- Provides a bottom `New Workspace` action.

Structure:

```swift
VStack {
    List(selection: $selectedWorkspaceID) {
        Section("Workspaces") {
            ForEach(workspaces) { workspace in
                WorkspaceSidebarRow(...)
            }
        }
    }
    .listStyle(.sidebar)

    Divider()

    Button("New Workspace", systemImage: "plus")
}
```

Each row shows:

- Status item glyph/icon
- Workspace name
- Active checkmark
- Window count

## Detail: `WorkspaceDetailView`

The detail area is vertically structured:

```swift
VStack(spacing: 0) {
    BoardSummaryHeader(...)
    Divider()

    ScrollView {
        PinnedWindowCardGrid(...)
        secondaryControls
    }

    Divider()
    StatusFeedbackView(...)
}
```

The board content is constrained to a readable max width and scrolls vertically when the window is small.

## Board Header: `BoardSummaryHeader`

Purpose:

- Shows the selected workspace as the current board.
- Shows the workspace Status Item preview.
- Shows pinned count, attention count, and last saved time.
- Provides board-level recovery and layout restore actions.

Main actions:

- `Recover Missing`
- `Restore Layout`

The title fallback is `No Board Selected`, but normal app state should select `Default` or another workspace.

## Main Board: `PinnedWindowCardGrid`

The main board is a responsive adaptive grid:

```swift
LazyVGrid(
    columns: [GridItem(.adaptive(minimum: 200, maximum: 240), spacing: 18)]
)
```

Behavior:

- Attached windows are rendered as `PinnedWindowCard`.
- A trailing `AddPinnedWindowCard` is always shown.
- If there are no pinned windows, the Add card becomes the empty-state call to action.
- New cards animate in through the Add card path.
- Detached cards animate out before removal.
- Workspace switches can apply staggered card entrance motion.

## Pinned Window Cards

Each card uses a fixed base ratio:

```text
220 width x 308 height
```

The card scales to its grid column width.

Card hierarchy:

- Top: app name and `...` menu
- Upper body: large app icon in an app-tinted field
- Lower body:
  - window title
  - state badge
  - short state explanation
  - primary action button

States:

- `Available`
- `Minimized`
- `Unavailable`
- `Reconnecting`

Primary action by state:

- `Available`: `Bring Forward`
- `Minimized`: `Restore Window`
- `Unavailable`: `Find or Reopen`
- `Reconnecting`: disabled `Finding...`

Secondary card actions are in the menu:

- `Save Layout`
- `Find Window Again`
- `Detach from Board`

## Add Window Card

The Add card is the final grid item.

Behavior:

- Uses the same ratio as pinned cards.
- Calls the Add-card attach path.
- Appends the frontmost external window to the end of the board.
- Empty state label is `Pin Frontmost Window`.
- Non-empty state label is `Add Window`.
- If a new card was just added, the next Add card quietly fades/slides back in.

## Secondary Controls

Below the card grid, a grouped `Form` still provides lower-frequency controls:

```swift
Form {
    DisclosureGroup("Add Window") {
        WindowSelectionView(...)
    }

    DisclosureGroup("Workspace Settings") {
        WorkspaceSettingsControls(...)
    }
}
.formStyle(.grouped)
```

### Add Window

Contains:

- Window picker
- `Refresh`
- `Attach Selected`
- `Attach Window`

This is the explicit-list attach path. The card-based Add Window path is the primary quick path.

### Workspace Settings

Contains:

- Workspace name editing
- `Save`
- `Overwrite`
- `Rename`
- Status Item Display preview, text, and icon menu
- `Minimize Unattached On Workspace Switch`
- `Restore Missing Windows On Workspace Switch`
- `Keep Window Board On Top`
- `Delete Workspace`
- `Remove All Windows`

This area is still dense and remains a likely future UI cleanup target.

## Status Footer

Always visible at the bottom of the detail area.

Shows:

- Progress state while loading, minimizing, or restoring
- `session.statusMessage`

Examples:

- `Restoring windows and reconnecting as needed...`
- `Minimizing unattached windows...`
- `Restoring minimized windows...`

## Toolbar

The main window toolbar contains icon buttons with tooltips.

Items:

- `Refresh`
  - icon: `arrow.clockwise`
  - help: `Refresh window list`
- `Attach Window`
  - icon: `plus.rectangle.on.rectangle`
  - help: `Pin the frontmost window to this board`
- `Focus Board`
  - icon: `scope`
  - help: `Bring this board's pinned windows to the front`
- `Minimize Others`
  - icon: `minus.square`
  - help: `Minimize windows not in this workspace`
- `Restore Windows`
  - icon: `arrow.counterclockwise`

## Settings Window

The macOS Settings scene contains behavior settings that are not workspace-specific:

- Follow Mode
- Position Update
- Auto Front
- Board Click Action

The main window still owns workspace-specific or frequently toggled options:

- Keep Window Board On Top
- Minimize Unattached On Workspace Switch
- Restore Missing Windows On Workspace Switch

## Current UI Notes

- The active UI direction is a card-board layout, not the older `AttachedWindowsListView` list layout.
- Some older list/inspector helper views still exist in source, but they are not the primary main-window composition.
- `Workspace Settings` remains the densest part of the UI.
- The Add-card path and explicit picker path intentionally coexist.
- Card animation should stay modest and respect Reduce Motion.
