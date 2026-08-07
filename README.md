# WindowBoard

WindowBoard is a native macOS utility for organizing ordinary windows from external applications into reusable **Boards**.

It does not embed or replace other applications' windows. WindowBoard uses macOS Accessibility APIs to discover and control them on a best-effort basis: moving, resizing, minimizing, restoring, activating, focusing, and raising them.

The user-facing product term is **Board**. Some implementation types still use the older `Workspace` name.

## What It Does

- Attach multiple external windows to a Board and save their positions and optional sizes.
- Create, rename, overwrite, delete, and switch Boards.
- Build a Current Board from a hierarchy of Boards: a Primary Board, parallel included Boards, and child Boards.
- Keep a non-deletable **Permanent Board** for reusable windows that can be included like any other Board.
- Show attached windows as Board-owned cards, including `Available`, `Resolving`, `Minimized`, `Unavailable`, and `Reconnecting` states.
- Recover minimized or unavailable windows when macOS and the external application expose enough information.
- Move, reorder, or detach a saved window reference without closing the external application window.
- Restore a Board layout, focus its windows, minimize unrelated windows, and restore only windows minimized by WindowBoard.
- Switch Boards from the main window, the menu-bar Status Item, or the Quick Launcher through one shared session path.

## Quick Launcher

Press `Command-Shift-Space`, or choose **Show Quick Launcher** from the Status Item menu.

- Search Boards, attached windows, saved windows, and commands locally and immediately.
- Search ignores case, width, diacritics, and Hiragana/Katakana variation. Japanese Kanji Board names are indexed by Japanese readings, so `じゅ` can find `授業`.
- Add optional comma-separated Board search aliases in Board Settings.
- Use `#` for Boards, `@` for Windows, and `>` for Actions.
- Use Up/Down to select, Return to run, and Escape to dismiss.
- A Window result brings an available window forward, restores a minimized window, or finds/reopens an unavailable window.
- Use the `Detach` control on a live Window result to remove it from its owning Board. This does not close, minimize, move, raise, or reconnect the external window.

## Requirements

- macOS 14 or later
- Xcode
- Accessibility permission for WindowBoard

WindowBoard remains launchable without Accessibility permission, but cannot list or control other apps' windows until permission is granted.

## Build and Run

Build only:

```bash
xcodebuild -project WindowBoard.xcodeproj -scheme WindowBoard -configuration Debug -derivedDataPath build/DerivedData build
```

Build and run:

```bash
./script/build_and_run.sh
```

Build, run, and confirm that the app launched:

```bash
./script/build_and_run.sh --verify
```

The runnable app is staged at `dist/WindowBoard.app`.

## Software Updates

WindowBoard includes Sparkle 2 for in-app updates. Its public update URL and EdDSA public key are already configured in the project:

- `SPARKLE_FEED_URL`: `https://daidesuu.github.io/Window-Board/appcast.xml`
- `SPARKLE_PUBLIC_ED_KEY`: built into the application for verifying update archives.

The matching private key is stored only in the macOS Keychain account `com.local.WindowBoard`; never export or commit it. To prepare a release archive and its signed appcast, run:

```bash
./script/prepare_sparkle_release.sh v1.0
```

Upload the generated ZIP in `release/sparkle/` to that GitHub Release, then commit `docs/appcast.xml` and publish the repository's `docs/` folder through GitHub Pages. The feed contains no updates until the first signed archive is published.

The release script clears Finder metadata, applies and verifies an ad-hoc signature, then creates the ZIP. This makes the archive structurally valid without an Apple Developer certificate; macOS will still require users to approve the first launch in Privacy & Security.

Run the test suite:

```bash
xcodebuild -project WindowBoard.xcodeproj -scheme WindowBoard -configuration Debug -derivedDataPath build/DerivedData test
```

## Basic Use

1. Launch WindowBoard and grant Accessibility permission.
2. Create or select a Board from the sidebar.
3. Use **Attach Window** or the Add Window card to attach the frontmost eligible external window. Refresh the window list and choose a candidate when needed.
4. Arrange the external windows, then use **Save Layout** to preserve one card or save/overwrite the Board from Board Settings.
5. Drag a Board onto another Board to create a child relationship, or onto its upper/lower edge to add it as a parallel root.
6. Use **Restore Layout**, **Focus Board**, **Minimize Others**, or **Restore Windows** when needed.
7. Use **Find or Reopen** for an unavailable or minimized saved window. Use **Detach from Board** to remove only its saved Board membership.

## Main UI

- **Sidebar:** saved Boards, Current Board groups, Board contextual actions, and Board drag-and-drop.
- **Current Board:** an explicit hierarchy of Board lanes and their owned window cards. Parallel roots and child Boards remain visually distinct.
- **Window cards:** application identity, title, status, card actions, layout save, recovery, move/reorder, and detach affordances.
- **Toolbar:** Board navigation/creation plus attach, focus, recover, minimize, restore, and More actions. Actions are disabled when their state or Accessibility permission makes them unsafe.
- **Board Settings:** save, overwrite, rename, delete, search aliases, Status Item display, switch behavior, on-top behavior, and remove-all-windows.
- **Status Item:** show WindowBoard, open Quick Launcher, switch Boards, focus Board windows, minimize others, restore WindowBoard-minimized windows, open Settings, or quit.

## Board Switching and Recovery

Board switching is staged for responsiveness:

1. Save the outgoing Board state when possible.
2. Show target placeholder cards promptly.
3. Resolve live windows and apply their saved layout in the background.
4. Keep unresolved references as recoverable `Unavailable` cards.
5. Optionally recover missing windows and minimize unrelated windows after the target Board is visible.

`Minimize Others When Switching Boards` and `Restore Missing Windows When Switching Boards` are optional Board settings. Minimize and recovery work are best-effort and never remove a saved reference merely because a macOS Accessibility operation failed.

## Architecture

- `WorkspaceSessionController`: central Board/session state, persistence updates, switching, layout restoration, recovery, and minimize/restore coordination.
- `WorkspaceStore` and `BoardCompositionStore`: saved Board data and Current Board hierarchy.
- `ContentView` and `Board*Views`: main SwiftUI composition and card-board presentation.
- `AccessibilityWindowService`: the narrow Accessibility API boundary for external-window operations.
- `ApplicationWindowCatalog`: external-window listing and cache merging.
- `AttachedWindowRecoveryCoordinator`: explicit recover/reconnect work.
- `BoardFollowCoordinator` and `BoardFrontingCoordinator`: follow and fronting policies.
- `AttachedWindowSnapshotCoordinator` and `AttachedWindowSnapshotReducer`: low-frequency off-main window snapshots.
- `WindowBoardStatusItemController`: menu-bar Status Item.
- `QuickLauncherWindowController`: global launcher panel and shortcut handling.

`WindowBoardTree` is an experimental target. The supported WindowBoard product and its Quick Launcher are built from the `WindowBoard` target.

## Limitations

WindowBoard relies on public macOS Accessibility APIs. Therefore all external-window control is best-effort.

- Exact external-window z-order is not guaranteed.
- Full-screen windows and windows on another Space are not reliable Board targets.
- WindowBoard cannot move an existing external window into the current Space through public APIs.
- System panels, special windows, and permission-limited windows may not be controllable.
- Some applications do not allow move, resize, minimize, restore, focus, or raise operations.
- A closed window cannot always be restored to its exact document, tab, folder, or internal application state.
- Matching similar windows after reopening is necessarily best-effort.

## Further Documentation

- [APP_REQUIREMENTS.md](APP_REQUIREMENTS.md): consolidated, user-facing requirements and behavior contracts.
- [PROJECT_PLAN.md](PROJECT_PLAN.md): implementation direction and architecture context.
- [AGENTS.md](AGENTS.md): repository-specific development and verification guidance.
