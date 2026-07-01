# WindowBoard Current UI Layout Summary

WindowBoard is a macOS SwiftUI app. The current main window uses a `NavigationSplitView`.

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
    Show Attached
    Minimize Others
    Restore Windows
}
```

## Sidebar: `WorkspaceSidebarView`

Purpose:

- Shows saved workspaces.
- Shows which workspace is active.
- Displays each workspace's Status Item glyph/icon and window count.

Structure:

```swift
List(selection: $selectedWorkspaceID) {
    Section("Workspaces") {
        ForEach(workspaces) { workspace in
            WorkspaceSidebarRow(
                workspace: workspace,
                isActive: workspace.id == activeWorkspaceID
            )
            .tag(workspace.id)
        }
    }
}
.listStyle(.sidebar)
.navigationTitle("Window Board")
```

Each row shows:

- Status item glyph/icon
- Workspace name
- Active checkmark
- Window count

## Detail: `WorkspaceDetailView`

The detail area is vertically stacked.

```swift
VStack(spacing: 0) {
    WorkspaceSummaryHeader(...)
    Divider()

    AttachedWindowsHeader(...)
    AttachedWindowsListView(...)
        .frame(maxHeight: .infinity)

    Divider()

    secondaryControls
        .frame(maxHeight: 300)

    Divider()

    StatusFeedbackView(...)
}
```

## Detail Header: `WorkspaceSummaryHeader`

Purpose:

- Shows current selected workspace summary.
- Shows workspace status item preview.
- Shows attached window count.
- Provides `Reload`.

Contains:

- `StatusItemPreview`
- Workspace display name
- Attached count
- `Reload` button

## Main List: `AttachedWindowsListView`

Purpose:

- Shows attached windows for the selected workspace.
- Uses `List`.

Empty state:

- Shows `No windows attached`
- Shows `Attach Window` button

Row layout:

```swift
HStack {
    Image(systemName: "macwindow")

    VStack {
        Text(appName)
        Text(windowTitle)
    }

    Spacer()

    StatusBadge(...)
    recoveryButtonIfNeeded
    Menu("...") {
        Save Layout
        Find Window Again
        Remove from Workspace
    }
}
```

States:

- `Available`
- `Minimized`
- `Unavailable`
- `Reconnecting`

Recovery button:

- `Minimized` -> `Restore Window`
- `Unavailable` -> `Find or Reopen`
- `Reconnecting` -> disabled `Finding...`
- `Available` -> no recovery button

## Secondary Controls

The lower detail area is a `Form` with disclosure groups.

```swift
Form {
    Section {
        DisclosureGroup("Add Window") {
            WindowSelectionView(...)
        }
    }

    Section {
        DisclosureGroup("Workspace Settings") {
            WorkspaceSettingsControls(...)
        }
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

```swift
Picker("Window", selection: $selectedWindowID) {
    Text("Choose a window")
    ForEach(windows) { window in
        Text(window.displayName)
    }
}

Button("Refresh")
Button("Attach Selected")
Button("Attach Window")
```

### Workspace Settings

Currently contains several different concerns in one area:

1. Workspace
   - Workspace name text field
   - `Save`
   - `Overwrite`
   - `Rename`
2. Status Item Display
   - Status item preview
   - Text field for custom status item text
   - `Set Text`
   - icon menu for SF Symbols / emoji
3. Switch Behavior
   - `Minimize Unattached On Workspace Switch`
   - `Restore Missing Windows On Workspace Switch`
   - `Keep Window Board On Top`
4. Danger Zone
   - `Delete Workspace`
   - `Remove All Windows`

## Status Footer

Always visible at bottom of detail.

Shows:

- Progress state when loading/minimizing/restoring
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
  - help: `Attach the frontmost window to this workspace`
- `Show Attached`
  - icon: `rectangle.on.rectangle`
  - help: `Bring attached windows to the front`
- `Minimize Others`
  - icon: `minus.square`
  - help: `Minimize windows not in this workspace`
- `Restore Windows`
  - icon: `arrow.up.square`
  - help: `Restore windows minimized by WindowBoard`

## Settings Window

The macOS Settings scene currently contains behavior settings such as:

- Follow Mode
- Position Update
- Auto Front
- Board Click Action

Some behavior options are still in the main window:

- Keep Window Board On Top
- Minimize Unattached On Workspace Switch
- Restore Missing Windows On Workspace Switch

## Current UI Issues

The current UI is functional but still has some information architecture issues:

1. `Workspace Settings` contains too many unrelated concerns.
2. Frequent actions and low-frequency behavior settings are close together.
3. Toolbar actions and detail actions partially overlap.
4. `Switch Behavior` options are probably closer to Settings than day-to-day workspace editing.
5. Dangerous actions like `Delete Workspace` and `Remove All Windows` are inside the same disclosure group as normal workspace editing.
6. The lower `secondaryControls` area can feel dense when expanded.
