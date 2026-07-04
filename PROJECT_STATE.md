# WindowBoard Project State

Last checked: 2026-07-03 00:23 JST

## Summary

WindowBoard is currently a macOS SwiftUI window session manager built around the idea of a board that groups external app windows. The original single-window follow MVP has evolved into a workspace-based app that can pin multiple external windows, save their layout, restore them, reconnect missing windows where possible, and switch workspaces from the main window or status item.

The current active UI direction is no longer the old table/list inspector layout. It is a card-board UI:

- Workspaces are selected from a left sidebar.
- The main board shows pinned windows as app-tinted vertical cards.
- Missing, minimized, reconnecting, and available windows are represented as state variants of the same card type.
- Add Window is represented as a trailing card in the grid.
- The old always-visible right inspector, separate status summary, needs recovery section, and snapshot comparison section are no longer the primary design direction.

## Verification

Current verification command:

```bash
./script/build_and_run.sh --verify
```

Result:

- Build succeeded.
- App was copied to `dist/WindowBoard.app`.
- Launch verification reported: `WindowBoard is running.`

There were no compile errors in the current source state.

The current documentation has been synced against this state in:

- `README.md`
- `PROJECT_PLAN.md`
- `CurrentUILayout.md`
- `AGENTS.md`

## Working Tree

At the time of this investigation, the working tree already had uncommitted code changes in:

```text
WindowBoard/App/WorkspaceSessionController.swift
WindowBoard/Views/ContentView.swift
WindowBoard/Views/WindowBoardMainViews.swift
```

Diff size before adding this document:

```text
3 files changed, 838 insertions(+), 93 deletions(-)
```

These changes are implementation work, not just formatting. They include workspace creation, UI card-board redesign, transparency changes, card animations, and workspace-switch minimize path optimization.

## Current Architecture

### `WindowBoardAppState`

App-wide state holder. It owns or connects:

- `WorkspaceStore`
- `WorkspaceSessionController`
- shared settings
- main `NSWindow` reference
- status item controller wiring

### `WorkspaceSessionController`

The central workspace/session state controller.

Current responsibilities:

- selected and active workspace state
- attached window list
- unavailable and reconnecting attachment state
- minimized window history
- workspace save, overwrite, rename, delete, create, and switch
- saved layout restoration
- missing window recovery
- minimize unattached / restore minimized
- status messages

Recent implementation additions in this file:

- `createWorkspace(boardOrigin:)`
- generated names like `Workspace 2`, `Workspace 3`, etc.
- DEBUG `OSLog` duration logging for expensive workspace operations
- workspace switch minimize flow now reuses candidate windows instead of always calling `listWindows()` again
- unavailable attachments are excluded from broad same-application minimize protection
- deferred recovery is gated by `Restore Missing Windows On Workspace Switch`

### `ContentView`

Main window controller/view layer. It owns UI state that depends on the actual WindowBoard window.

Current responsibilities:

- Accessibility permission gate
- main `NavigationSplitView`
- board window observation
- board window transparency/chrome configuration
- board movement and follow behavior
- frontmost app tracking
- attach/detach actions
- workspace loading from UI selection
- card animation state
- status item command handling

Recent implementation additions in this file:

- `AttachedWindowInsertion.start/end`
- `recentlyAddedAttachedWindowID`
- `workspaceCardTransitionToken`
- `detachingAttachedWindowIDs`
- delayed detach animation tasks
- Add Window card path appends new windows at the end of the grid
- Add Window failure clears pending recently-added animation state
- workspace switch cancels Add/Detach animation overlap
- `configureBoardWindowTransparency` currently sets the NSWindow background alpha to `0.74` and uses a transparent titlebar

### `WindowBoardMainViews`

Main SwiftUI view composition file for the card-board UI.

Current responsibilities:

- sidebar workspace list
- detail board header
- pinned window card grid
- Add Window card
- card styling
- app icon lookup/tinting
- card motion modifiers
- lower secondary controls
- status footer

Recent implementation additions in this file:

- sidebar bottom `New Workspace` button
- `PinnedWindowCardGrid`
- `PinnedWindowCard`
- `AddPinnedWindowCard`
- `InteractiveCardMotion`
- `WorkspaceCardEntranceModifier`
- `CardDetachExitModifier`
- `CardPinInModifier`
- app-icon-based card tinting
- elevated app icon rendering
- responsive card scaling based on a `220 x 308` base card size

## Current UI Structure

### Root

The app uses:

```swift
NavigationSplitView {
    WorkspaceSidebarView(...)
} detail: {
    WorkspaceDetailView(...)
}
```

The toolbar currently contains:

- Refresh
- Attach Window
- Focus Board
- Minimize Others
- Restore Windows

### Sidebar

`WorkspaceSidebarView` shows saved workspaces.

Each row shows:

- workspace status glyph
- workspace name
- active checkmark
- window count

The sidebar now also has a bottom `New Workspace` button. This calls `WorkspaceSessionController.createWorkspace(boardOrigin:)` through `ContentView`.

### Board Header

`BoardSummaryHeader` shows:

- selected workspace symbol
- selected workspace name
- summary text like `5 pinned · 3 need attention · saved 2:34 PM`
- `Recover Missing`
- `Restore Layout`

The board header background is currently a semi-opaque `windowBackgroundColor` overlay, not a fully material-based title/header surface.

### Main Board

The main board content is a scroll view containing:

- `PinnedWindowCardGrid`
- secondary controls below the grid

The grid uses an adaptive layout:

```swift
GridItem(.adaptive(minimum: 200, maximum: 240), spacing: 18, alignment: .top)
```

This means the card count per row changes with window width, and cards should drop down to fewer columns on narrow windows.

### Pinned Window Cards

Each pinned window is a vertical card with a fixed design base ratio:

```text
220 width x 308 height
```

Current card information hierarchy:

- top: app name and menu
- upper body: large app icon in an app-tinted field
- lower body:
  - window title
  - status badge
  - state text
  - primary action

Primary action by state:

- available: `Bring Forward`
- minimized: `Restore Window`
- unavailable: `Find or Reopen`
- reconnecting: disabled `Finding...`

Secondary card actions are in the menu:

- Save Layout
- Find Window Again
- Detach from Board

### Add Window Card

The Add Window card is the final grid item.

Behavior:

- Uses the same card ratio as pinned cards.
- Calls the special Add-card attach path.
- Appends the new card to the end of the attached window list.
- If the workspace is empty, it reads as `Pin Frontmost Window`.
- When a new window is added, the next Add Window card quietly appears with fade/scale/slide.

### Secondary Controls

Below the board grid, there is still a grouped form containing:

- `Add Window`
- `Workspace Settings`

This means the app currently has both the card-based Add Window path and the older disclosure-based Add Window controls.

This is functional, but it is a design area that likely needs cleanup once the card-board direction is finalized.

### Status Footer

The bottom status feedback area remains visible and shows:

- loading workspace state
- minimizing/restoring state
- `session.statusMessage`

## Motion And Animation State

Current animation model:

- Add Window:
  - new card uses pin-in animation
  - opacity `0 -> 1`
  - scale `0.96 -> 1`
  - y offset `-8 -> 0`
  - rotation `1.5deg -> 0`
- Detach:
  - target card fades out, scales down slightly, moves up, and rotates slightly
  - actual detach is delayed about 260 ms so the exit animation can play
- Workspace switch:
  - cards enter with crossfade, slight slide, slight scale, and subtle stagger
- Hover:
  - cards use 3D tilt, slight scale-up, specular highlight, and dynamic shadow
- Reduce Motion:
  - modifiers reduce motion to fade-oriented behavior where implemented

Priority rules in the current code:

- detaching takes priority over pin-in and hover
- pin-in disables hover and workspace entrance
- workspace switch cancels pending Add/Detach animation state from the previous workspace

## Transparency / Visual Surface State

Current visual direction is a translucent board window.

Current implementation notes:

- `NSWindow.isOpaque = false`
- `NSWindow.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.74)`
- `titlebarAppearsTransparent = true`
- title is hidden
- sidebar uses `.thinMaterial` plus a light background overlay
- status footer uses `.thinMaterial` plus a light background overlay
- board content background is `Color.clear`
- board header currently uses `Color(nsColor: .windowBackgroundColor).opacity(0.22)`

The transparency work is still visually sensitive. The board header and titlebar may still need tuning because AppKit titlebar material behavior and SwiftUI header backgrounds do not behave as one continuous surface by default.

## Persistence And Workspace Behavior

Workspace switching is still designed as a staged, non-blocking workflow:

1. save the active workspace state where appropriate
2. show placeholder attached windows quickly
3. resolve live windows from cached/fresh candidates
4. optionally try recovery depending on `Restore Missing Windows On Workspace Switch`
5. apply saved positions and sizes best-effort
6. minimize unattached windows after the workspace is visible if enabled

Important current behavior expectations:

- attached windows should stay selected even when missing, minimized, or stale
- closed windows should become unavailable, not silently detach
- public macOS APIs cannot reliably restore full-screen windows or windows on another Space
- exact z-order is best-effort
- AX operations should stay off the main thread where possible

## Existing Documentation State

Current docs:

- `README.md`: updated for the card-board UI, current usage flow, workspace behavior, and architecture.
- `PROJECT_PLAN.md`: updated to describe the post-MVP workspace/session manager phase; the old MVP is treated as completed background.
- `CurrentUILayout.md`: updated to describe the current card-board `NavigationSplitView`, pinned cards, Add Window card, toolbar, and secondary controls.
- `AGENTS.md`: updated with current UI direction and workspace-switch minimize/recovery expectations.
- `PROJECT_STATE.md`: this file, intended to be the current snapshot

## Known Gaps / Risks

- The card-board UI is mostly concentrated in `WindowBoardMainViews.swift`, which is becoming large and may need component splitting.
- The lower `Add Window` disclosure duplicates the Add Window card concept.
- The lower `Workspace Settings` form still carries many responsibilities and may need a clearer destination.
- Visual polish of transparency/header/titlebar is not fully settled.
- Unresolved bug: `Find or Reopen` can bring the intended app/window to the front while the attached card still returns to or remains `Unavailable`.
  - `Use Front Window` may appear late or fail to reconnect the currently visible window.
  - Recent attempted fixes added recovery issue state, guarded stale recovery tasks, relaxed app-name matching, and tried CGWindow frontmost-window matching, but the user still reports the issue is not fixed.
  - Treat this as an open investigation item. The next debugging pass should instrument the card action path and show per-card diagnostics for: button clicked, recovery revision, expected bundle/app, candidate window count, chosen candidate, AX position result, and final state update.
  - Avoid adding more heuristic reconnect logic until the actual failing branch is observable.
- Motion has compile verification, but still needs manual visual review for:
  - pin-in timing
  - hover strength
  - narrow window layout
  - Reduce Motion behavior
- The working tree is not clean, so any next implementation should avoid broad refactors unless the current diff is intentionally accepted.

## Recommended Next Steps

1. Manually review the running app after the latest pin-in animation change.
2. Split `WindowBoardMainViews.swift` into smaller view files once the UI direction is stable.
3. Remove or simplify duplicated Add Window controls if the card path is the primary interaction.
4. Continue tuning transparency only after the main board/card interaction feels stable.
5. Re-run `./script/build_and_run.sh --verify` after the next code change that affects runtime behavior.
