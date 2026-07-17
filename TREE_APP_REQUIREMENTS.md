# WindowBoard Tree Requirements

## Status

WindowBoard Tree is an experimental macOS application built as a separate target in `WindowBoard.xcodeproj`. It validates a strict, single-parent Board tree without changing the existing WindowBoard application.

The current implementation is Stage 6. It provides an independent hierarchical Board manager with Board-owned external window references, explicit window actions, a Finder-style Board browser, in-app Board/window drag and drop, and persistent Favorite Board shortcuts.

## Application Isolation

- The product is `WindowBoard Tree.app`.
- Its bundle identifier is `com.local.WindowBoard.TreeExperimental`.
- It uses its own `UserDefaults.standard` domain because it is a separate app bundle.
- Existing WindowBoard Boards are not imported, migrated, copied, or displayed.
- WindowBoard Tree data must not alter or delete data owned by the existing WindowBoard app.

## Board Hierarchy

- The first launch creates one immutable root Board named `Root Board`.
- The root Board and `BoardTreeStore` data persist between WindowBoard Tree launches.
- The main window uses `NavigationSplitView`.
- The Sidebar displays the strict, single-parent Board hierarchy.
- Boards can be expanded and collapsed. Expansion state persists between launches.
- Selecting a Board displays that Board's detail view. The selected Board persists between launches and falls back to the nearest valid ancestor or Root Board when necessary.
- A child Board can be created under the selected Board from the toolbar, detail view, or context menu.
- Newly created Boards are selected immediately and their parent is expanded.
- Non-root Boards can be renamed or deleted. Root Board cannot be renamed, moved, or deleted.
- Deleting a Board requires confirmation and removes its complete child subtree from Tree storage. Saved external window references are removed, but external application windows are not closed.
- The detail view shows a compact clickable Board path followed by one Finder-style table.
- Direct child Boards and the selected Board's saved window references appear together in the table.
- The table uses `Name`, `Kind`, and `Status` columns. Boards use folder icons and windows use window icons.
- A single click selects a row without opening it. Double-clicking or pressing Return opens a child Board or shows/restores a saved window.
- Board and window row context menus expose the same existing create, rename, delete, show, and remove actions.
- Pressing Delete applies the existing delete flow to the selected Board or removes the selected window reference from its Board.
- When a Board contains no child Boards or saved windows, the detail displays a compact empty state with a New Child Board action.
- Board creation and editing remain available without Accessibility permission. Window actions show a compact permission banner until access is granted.
- The Tree toolbar contains New Child Board, Add Window, Attach Frontmost Window, Refresh Windows, and a Board actions menu.
- Settings identifies the Tree app's Board library as separate from WindowBoard.

## Favorite Boards

- The Sidebar displays a `Favorites` section above the full Board hierarchy.
- A Favorite is a shortcut to an existing Board. Adding, removing, or reordering a Favorite does not copy or move the Board and does not change its parent.
- A Board can be added to or removed from Favorites from Sidebar rows, child Board rows in the Finder-style table, and the current Board actions menu.
- Dropping a normal Board onto the empty Favorites area or an existing Favorite adds it as a shortcut.
- Favorite rows use a dedicated drag payload and can be reordered independently from the Board hierarchy.
- Selecting a Favorite opens the same Board through the normal selection path. `Show in Board Tree` selects its location in the hierarchy.
- Removing a Favorite leaves the Board and all saved window references unchanged.
- Deleting a Board also removes any Favorite shortcut that points to it.
- Window payloads are not accepted by the Favorites section.

## Board Windows

- Each Board owns only the external window references saved directly on that Board.
- Selecting another Board replaces the Detail window list with that Board's references. Parent and child Board windows are not copied into one another.
- `Add Window` attaches a currently discovered external window to the selected Board.
- `Attach Frontmost Window` attaches the frontmost external application window to the selected Board.
- The same identifiable external window cannot be added to the same Board twice.
- Saved references are matched best-effort using the existing bundle identifier, document URL, title, and application identity rules.
- A matching live window is shown as `Available` or `Minimized`. A saved reference without a matching live window remains on the Board as `Unavailable`.
- `Show Window` raises an available window. For a minimized window, it first attempts to restore it and then raises it.
- `Remove from Board` removes only the saved reference from the selected Board. It does not close, minimize, move, or otherwise modify the external application window.
- Window enumeration and Accessibility operations run outside the main actor. Results from an older Board selection must not overwrite the currently selected Board.
- Window listing and focus require Accessibility permission for the separate `WindowBoard Tree` application.

## Board Drag And Drop

- Non-root Boards can be dragged within the Sidebar.
- Child Board rows in the Finder-style Detail table can also be dragged.
- Dropping a Board onto another Board makes it the last child of that Board.
- Dropping a Board on an insertion line moves or reorders it before the adjacent sibling.
- Dropping a Board on blank space in the Detail table moves it into the currently open Board.
- Root Board cannot be dragged.
- Self drops and moves into a descendant are rejected so the hierarchy cannot contain cycles.
- Drag and drop changes only Tree hierarchy metadata. It does not perform Accessibility or external-window operations.

## Window Drag And Drop

- Window rows in the Finder-style Detail table can be dragged within WindowBoard Tree.
- Dropping a window onto a Sidebar Board or a child Board row moves its saved reference to that destination Board.
- Dropping a window on blank space in the Detail table moves it to the currently open Board when it comes from another Board.
- A move removes the saved reference from its source Board and appends the same reference to the destination Board.
- Available, minimized, and unavailable saved windows can be moved because the operation changes only Board ownership metadata.
- A destination Board rejects a window that already matches one of its saved references. The source reference remains unchanged when a move is rejected.
- Moving a saved window does not raise, minimize, move, close, reopen, or reconnect the external application window.
- Reordering window rows inside the same Board is not implemented in Stage 5.

## Not Implemented Yet

- Automatically opening or reconnecting unavailable windows
- Restoring saved window position or size when selecting a Board
- Following Board movement, minimizing unrelated windows, or composing multiple Boards into one runtime session
- Status Item controls
- Data sharing or migration between WindowBoard and WindowBoard Tree

## Build And Run

Build the target with:

```bash
xcodebuild -project WindowBoard.xcodeproj -scheme WindowBoardTree -configuration Debug -derivedDataPath build/DerivedData build
```

Build, launch, and verify the app with:

```bash
./script/build_and_run_tree.sh --verify
```

The existing WindowBoard app continues to use:

```bash
./script/build_and_run.sh --verify
```
