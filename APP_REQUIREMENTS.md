# WindowBoard Application Requirements

2026/8/4

## 1. Purpose

WindowBoard is a macOS utility for arranging ordinary windows from external applications into reusable **Boards**.

It does not embed, reparent, or replace external application windows. Each target remains a normal macOS window. WindowBoard uses the public macOS Accessibility APIs to discover, move, resize, minimize, restore, activate, focus, and raise those windows on a best-effort basis.

The user-facing concept is **Board**. Some persistence and implementation types retain the older `Workspace` name; this is an implementation detail and does not change the product terminology.

## 2. Platform and Prerequisites

- The product is a native macOS application built with SwiftUI and AppKit bridges.
- It remains a normal Dock application and also provides a menu bar Status Item.
- Accessibility permission is required to read and control external windows.
- Without Accessibility permission, the app must remain launchable and show a permission-oriented UI, but it cannot list, move, resize, minimize, restore, focus, or raise external windows.
- The application must not require App Sandbox support for the current development build, because it controls external application windows through Accessibility APIs.

## 3. Concepts and Terms

| Term             | Meaning                                                                                                             |
| ---------------- | ------------------------------------------------------------------------------------------------------------------- |
| Board            | A saved collection of external-window references and their layout metadata.                                         |
| Current Board    | The resolved board composition currently displayed and operated on by the main window.                              |
| Primary Board    | The saved Board whose composition is being loaded. It is implicitly the first root of its Current Board.            |
| Included Board   | A Board included as an additional root or child in a Current Board composition.                                     |
| Permanent Board  | The non-deletable, non-renamable default Board. It is a reusable normal Board, not an unconditional global overlay. |
| Attached Window  | A live or placeholder runtime representation of a saved window reference.                                           |
| Window Reference | Persisted metadata used to rediscover a window and restore its position and optional size.                          |

## 4. Board Persistence

### 4.1 Saved Boards

- A Board has a stable identifier, name, creation/update timestamps, a list of saved window references, and an optional Status Item display value.
- A Board saves enough metadata to identify a window best-effort: application name, title, bundle identifier, bundle URL, document URL when available, saved position, Board-relative offset, and optional size.
- A Board can be created, saved, overwritten, renamed, deleted, selected, and switched.
- New Board creation saves the current Board state when possible, creates and selects an empty Board, and retains the Current Board's global composition rules.
- Saving or overwriting persists current window position and, when readable, size.
- `Save Layout` on an individual card persists the position and size of only that card in its owning Board.
- Closed, stale, minimized, or temporarily unavailable windows must remain represented in their Board rather than being silently removed.

### 4.2 Default and Permanent Board

- A `Default` Board must always exist.
- The Default Board is the Permanent Board.
- The Permanent Board cannot be renamed or deleted.
- It can contain windows, be selected from the sidebar, be saved/overwritten, and be included in Current Board compositions like other Boards.
- Permanent Board windows are part of a Current Board only when the Permanent Board is included through the board-composition rules.
- Legacy `Never Minimize Windows` registrations are migrated into the Permanent Board once when legacy data exists.

### 4.3 Status Item Display Metadata

- Each Board may define its own Status Item display.
- Supported values are SF Symbols, emoji, or short text.
- The setting is persisted with the Board and used when that Board is the selected member of the active Current Board.

## 5. Current Board Composition

### 5.1 Hierarchical Composition

- A Current Board is a directed acyclic graph (DAG) of Boards, shown as a hierarchy.
- The Primary Board is the first root automatically.
- Additional Boards may be included as parallel roots.
- A Board may include child Boards.
- Board insertion order is the display order.
- A Board may be referenced by more than one parent, but a parent cannot include the same child twice.
- A Board cannot include itself, directly or indirectly. Cycles must be rejected with an explanatory message.
- Removing an included Board removes only the parent/child or primary/root relationship. It must not delete the Board itself or its saved windows.
- Deleting a Board removes all composition references to it from every Board composition.

### 5.2 Global Roots

- The composition store supports globally included root Boards.
- A global root is resolved into every Current Board, in addition to the active Primary Board and that Primary Board's explicit roots.
- The Permanent Board may be a global root when migrated from prior inclusion behavior.

### 5.3 Resolution Rules

- Current Board resolution traverses roots and children depth-first.
- The UI may display the same Board through multiple valid paths.
- The same live external window must be acted on only once for AX operations even if it appears through multiple composition paths.
- Each resolved window keeps its owning Board identity so `Save Layout` and removal update the correct saved Board rather than copying the window to the Primary Board.
- The title bar represents the active Current Board. For a multi-root group it shows root Board names in insertion order, joined with `/`; child Board names are not included in that title.

### 5.4 Ordering

- Additional root Boards and child Boards retain an explicit insertion order.
- A root Board inserted before or after another root appears before or after that Board in the sidebar tab group and Current Board hierarchy.
- A child Board inserted into a parent appears after the parent's existing children unless a later explicit reordering interaction changes it.
- Window references in a Board retain an explicit card order independent of their current external-window z-order.

## 6. Sidebar Requirements

- The main window uses a macOS `NavigationSplitView` sidebar for Boards.
- The sidebar lists saved Boards and supports board selection, contextual actions, and dragging Boards into Current Board drop targets.
- A normal selected Board row must have a clear selected appearance.
- A multi-root Current Board is represented as a group of parallel Board tabs in the sidebar.
- Clicking any tab in that group selects the group as the Current Board, not merely one member window set.
- The selection indication for a group belongs to the group container, not an individual tab.
- A Board that is a child of another Board must remain visible in the sidebar as an individual Board; child relationships do not cause it to disappear.
- Boards joined as parallel roots may be shown as a group. A child Board is not required to appear as a parallel tab solely because it belongs to a hierarchy.
- Selecting an unrelated Board must not mutate, dissolve, or delete other saved Current Board groups.
- A Board's contextual menu must support the applicable board operations, including opening Board Settings, restoring its layout, removing its windows, and deleting it when allowed.
- The sidebar must support drag-and-drop for individual Board tabs/rows even when they belong to a displayed group.
- The sidebar must remain usable when the window is resized; it must not overlap the window traffic-light controls.

### 6.2 Sidebar Board Removal and Deletion

- A parallel-root tab exposes a nearby `Remove from Current Board` drop zone while it is dragged over its own sidebar group. Dropping there removes only that root relationship and leaves the Board and its saved windows intact.
- The Primary Board, child Boards, and Permanent Board cannot be removed through that drop zone. Child relationships continue to be removed from the Current Board detail hierarchy.
- The sidebar has a separate lower `Delete Board` drop zone that remains visually hidden until a Board is dragged over it. It deletes the saved Board, its saved window references, and every composition reference to it, but never closes or otherwise manipulates external macOS windows.
- Deleting an empty Board is immediate. Deleting a Board with saved window references requires confirmation. The Permanent Board cannot be deleted.

### 6.1 Sidebar Board Drop Semantics

- A dragged sidebar Board dropped on the **center** of another sidebar Board becomes a child of that target Board.
- A dragged sidebar Board dropped on the **upper or lower edge** of another sidebar Board becomes a parallel root beside that target Board.
- An upper-edge drop inserts the source immediately before the target; a lower-edge drop inserts it immediately after the target.
- For a target displayed as a tab in a multi-root group, edge drops update that group's Primary Board composition and insert beside the targeted root tab.
- For a standalone target Board, an edge drop creates or updates the Current Board group whose Primary Board is the target Board. It does not alter any unrelated parent relation in which that target may already appear.
- The center and edge zones must have distinct visual affordances and labels: `Add as child` for the center and `Add beside board` for the upper/lower edges.
- A Board drop that would be a self-reference, duplicate edge, missing Board, or cycle is rejected without changing the composition.

## 7. Main Board UI Requirements

- The main content area is a card-board UI, not an embedded-window canvas.
- It displays the resolved Current Board hierarchy with Board nodes and their owned window cards.
- Parallel root Boards are displayed as separate vertical lanes with compact material-backed headers and generous spacing between lanes. Nested child Boards are connected to their parent by a branch guide and a bounded visual indentation; roots and children must not look equivalent.
- Root headers show Board identity and metadata as the lane boundary. Child headers remain compact, and repeated `Root Board` / `Child Board` labels are not required when hierarchy is otherwise clear. Board nodes show identity, window count, child count, and hierarchy context, and may be collapsed/expanded.
- Window cards distinguish their owning Board and the full Board path when applicable.
- The Current Board area accepts a dropped Board as an additional root.
- A Board node accepts a dropped Board as a child.
- A dedicated Current Board drop zone accepts Board drops as new parallel roots. It remains compact outside an active Board drag and expands with a clear drop affordance when targeted. It does not accept window-card moves because it does not identify an owning Board.
- Invalid drops, including missing Board, duplicate relation, self-reference, or cycle, must not mutate the composition and must provide temporary feedback.
- The main content includes an Add Window affordance for attaching the frontmost eligible external window.
- The app must reflect newly attached windows in the Current Board without requiring a manual Board reload.
- Processing such as loading, minimize, and restore is shown only while active as a compact overlay; the app must not keep a permanent status bar solely for completed operation messages.

## 8. Window Discovery and Attach Requirements

- When accessibility is trusted, WindowBoard lists ordinary windows from running applications.
- WindowBoard's own windows must be excluded from external-window candidates.
- A candidate display name is based on application name and window title, with application name used when a title is unavailable.
- The user can refresh the external window list and attach a selected candidate.
- The toolbar and Add Window card attach the frontmost eligible external window.
- The frontmost selection should prefer the most recently active external application window when available, then use a visible external-window fallback.
- The same live external window must not be attached repeatedly to the same owning Board.
- Attaching a window records its current position, Board-relative offset, and available size information.
- An attachment's stable identifier must remain aligned with the persisted saved-window-reference identifier so the UI updates immediately after attachment.

## 9. Card Interaction Requirements

### 9.1 General Card Behavior

- Cards show the application name, window title when available, application icon, state, and actions appropriate to that state.
- Application icons and card tinting are cached to avoid repeated expensive icon lookup during scrolling or Board switching.
- Cards support restrained hover and insertion/removal animation without causing excessive continuous rendering.
- Dragging an eligible attached window card to the Permanent Board moves the window reference there and removes it from the original owning Board.
- Dragging a Permanent Board card to a Main Board adds it to that Board according to the current Board composition rules.

### 9.2 Focus and Placement

- Single-clicking a live card's icon area brings its external window forward.
- Double-clicking a live card's icon area brings the window forward and moves it below the current cursor position.
- The requested placement is best-effort, clamped to the usable display area when target window size is available.
- If a card is unavailable, reconnecting, resolving, minimized, in another Space, full-screen, or otherwise unsafe to move, the placement operation must fail safely without detaching the card.

### 9.3 Per-Window Actions

- `Save Layout` saves the current external-window position and optional size to the owning Board.
- `Find or Reopen` attempts to find, restore, open, or activate an unavailable/minimized saved window.
- `Use Front Window` is shown only when automatic recovery activated/opened the matching application but could not identify the saved window.
- `Use Front Window` may reconnect only to a currently frontmost window that belongs to the same application as the saved reference; it must not silently substitute a window from a different application.
- `Detach from Board` removes the card from its owning Board. It does not close the external application window.
- `Remove All Windows` removes saved windows from the target Board without closing external application windows.

### 9.4 Window Card Drag and Drop

- Dragging a window card to another Board is a **move**, not a copy.
- A successful move removes the saved window reference from its source/owning Board and inserts it into the destination Board while preserving the same reference identity and saved layout metadata.
- The external macOS window is not closed, reopened, minimized, raised, or otherwise manipulated merely because its card is moved between Boards.
- A window card may be dropped onto a Board in the Current Board hierarchy or directly onto a Board in the sidebar. Sidebar dropping allows moving a window to a Board that is not currently displayed.
- The blank Current Board area is not a valid destination for a window-card move, because it has no unambiguous owning Board. A destination must be an explicit Board node, tab, or sidebar Board row.
- If the destination already contains the same saved reference or an equivalent matching window reference, the move is rejected without removing it from the source Board.
- Moving a window card is allowed for `Available`, `Minimized`, and `Unavailable` references because it is a persistence operation. A reconnecting card may reject movement while its recovery task is active to avoid conflicting state changes.
- Dragging a card to the Permanent Board moves ownership to the Permanent Board. It does not create a duplicate. A future copy operation, if added, must be explicit and separate from drag-and-drop.
- Cards within the same owning Board should support drag reordering. This reorders the persisted Board window-reference array only and must not issue AX operations. It is a bounded UI/persistence feature, not a new window-management mechanism.
- Window-card drop targets must visibly distinguish `Move to <Board name>`, invalid destinations, and same-Board reordering insertion positions.
- Board and window-card drags use distinct internal drag types. A drop target must react only to compatible items, so Board composition drops never activate the window-only `Remove from Board` zone.

### 9.5 Drag Detach

- A window card may be removed by dropping it onto WindowBoard's dedicated in-app `Remove from Board` drop zone at the bottom of the Current Board detail.
- Dropping outside the WindowBoard app, cancelling a drag, or dropping onto an unsupported target must not detach a window. Only a successful drop on the dedicated zone confirms removal.
- `Available`, `Minimized`, and `Unavailable` cards may be removed. `Reconnecting`, `Resolving`, and already-removing cards must be rejected until their operation completes.
- Drag detach uses the same removal path and exit animation as `Detach from Board`; it removes the saved reference from its owning Board, including an included or Permanent Board owner, without closing, moving, minimizing, raising, or reconnecting the external macOS window.
- Drag detach has no Undo. A removed window can be added again with the existing Add Window flow.

## 10. Attached Window States and Recovery

The UI must use these states:

| State        | Requirement                                                                              |
| ------------ | ---------------------------------------------------------------------------------------- |
| Available    | A live AX window is accessible.                                                          |
| Resolving    | A saved reference is being matched during Board loading.                                 |
| Minimized    | The window is known to be minimized and can be restored.                                 |
| Unavailable  | No matching accessible live window has been found. The saved reference remains attached. |
| Reconnecting | An explicit or deferred recovery operation is in progress.                               |

- `Unavailable` must mean that the window cannot currently be found or safely accessed, not merely that a position/size write failed.
- A temporary AX read/write failure on a known live window must not immediately turn it into `Unavailable`.
- A recovery task must clear `Reconnecting` in every success, failure, cancellation, and stale-row path.
- Failed recovery returns the card to `Unavailable` and allows retry.
- Recovery is best-effort. A successful application activation is not enough to claim a saved window was reconnected.
- Automatic missing-window recovery during Board switching is controlled by a user setting. When disabled, missing windows remain unavailable until an explicit recovery operation.
- Deferred switch-time recovery, when enabled, must run after the main Board switch rather than blocking visible Board changes.
- Recovery may use app identity, bundle identifier, document URL, window title, process identity, cached window identifiers, and window number in a best-effort order.

## 11. Layout, Follow, and Fronting

### 11.1 Layout Restoration

- Board switching restores saved window position and optional size best-effort.
- `Restore Layout` reruns layout restoration for the active Current Board.
- No-op position and size updates should be skipped when current values are already sufficiently close to saved values.
- A layout-application failure must not detach a window or erase its saved reference.
- With Follow Mode `None`, layout restoration should prefer a saved absolute origin when appropriate, including Status Item initiated switching.

### 11.2 Follow Modes

- `None`: attached windows remain attached but do not follow WindowBoard movement.
- `Smooth`: attached windows follow WindowBoard movement during motion.
- `On Release`: attached windows are moved after WindowBoard motion ends, with a short release animation where applicable.
- Follow movement operates only on eligible live attached windows.
- Board-window movement observation should use AppKit notifications as the normal path and avoid a permanent high-frequency polling loop.
- AX move operations must run off the main thread and use scheduling/debouncing to reduce beachballing and energy impact.

### 11.3 Fronting

- `Focus Board` brings the resolved Current Board's live windows forward best-effort.
- WindowBoard uses application activation, AX focus, and AX raise where applicable; strict macOS z-order cannot be guaranteed.
- Auto-front may bring attached windows forward after Board movement according to its selected mode.
- Board click action may bring Board windows forward according to its selected mode.
- During Board switching, WindowBoard may temporarily use a floating level so the user can continue seeing the Board while external windows are fronted, then restore its configured window level.
- `Keep Window Board On Top` controls WindowBoard's normal persistent level.

## 12. Minimize and Restore

- `Minimize Others` minimizes accessible ordinary windows that are not part of the resolved Current Board.
- Attached windows and windows included through the Current Board hierarchy must be protected from minimization.
- `Minimize Others When Switching Boards` performs this action after the target Board is shown; Board loading must not wait for all minimization to finish.
- Minimize selection should reuse known candidates from Board switching where possible; manual minimize may perform a complete fresh enumeration for accuracy.
- WindowBoard records windows it minimized so `Restore Windows` restores only its own minimize history.
- Successfully restored windows are removed from that history; failed restores remain available for later retry.
- Minimize and restore remain conservative and best-effort to avoid minimizing protected windows incorrectly.

## 13. Main Window Toolbar and Board Settings

### 13.1 Toolbar

- The toolbar presents Board navigation/creation controls on the left and window/Board operations on the right.
- It includes a sidebar toggle, New Board, attach-frontmost, focus, recover missing windows, minimize others, restore minimized windows, and a More menu.
- Tooltips must explain icon-only toolbar controls.
- `Refresh Window List`, `Restore Layout`, and Board Settings are available from the More menu when not surfaced as primary controls.
- Board Settings is a low-frequency action and may choose among member Boards when the active Current Board is a group.
- Toolbar state must correctly disable actions when accessibility is unavailable, a required Board/window does not exist, or an incompatible operation is already running.

### 13.2 Board Settings

- Board Settings supports save, overwrite, rename, delete, Status Item display selection, Status Item text, switch behavior settings, persistent-on-top setting, and remove-all-windows action.
- Default/Permanent Board rename and deletion controls are disabled.
- Board settings act on their explicit target Board. Opening settings for an included Board must not change the active Current Board selection or attach destination.

## 14. Application Settings

The macOS Settings scene provides persistent behavior settings:

- `Board Click Action`
- `Follow Mode`
- `Position Update`
- `Auto Front`

These settings must apply immediately to the main window behavior and persist across app launches.

### 14.1 Software Updates

- WindowBoard uses Sparkle 2 for in-app software updates with its configured HTTPS update feed and Sparkle EdDSA public key.
- The user can choose `Check for Updates…` from the application menu or the Status Item menu.
- If a development build has no feed URL or public key configured, WindowBoard must not begin update checks or make update-network requests. The update action must explain that the distribution feed has not yet been configured.
- Update archives and appcasts are signed outside the application with the corresponding private EdDSA key. The private key must never be shipped in the application bundle or committed to the repository.

## 15. Status Item Requirements

- WindowBoard provides a Status Item while remaining visible in the Dock as a normal app.
- The Status Item shows the active/selected Board's configured symbol, emoji, text, or default glyph.
- The menu can show the main WindowBoard window, switch Boards, focus Board windows, minimize others, restore minimized windows, open Settings, and quit.
- Saved Boards and Current Board groups are represented in the Status Item menu.
- Selecting a member of a Current Board group loads that group's Primary Board while preserving the selected member display state.
- The active selected Board in the active group is checkmarked.
- Status Item Board switching must use the same `WorkspaceSessionController` switching path as the main window.
- Status Item Board switching must save the previous active Board state without creating or showing a new WindowBoard main window.

## 16. Switching Requirements

Board switching must be a staged, responsive operation:

1. Save the outgoing Board state using the most recently observed snapshot when speed is more important than a fresh AX read.
2. Resolve the target Current Board hierarchy and show placeholder cards promptly.
3. Use cached/live windows to replace placeholders and apply saved layouts in the background.
4. Mark unresolved references as unavailable without removing them.
5. Optionally begin deferred missing-window recovery after the visible switch.
6. Optionally minimize non-Current-Board windows after the target Board is shown.
7. Ignore stale async completions from an older switch once a newer Board becomes active.

- Main-window and Status Item Board switching share this single session path.
- Consecutive switches must not allow an older task to overwrite the active Current Board, attached windows, recovery state, or minimization state.
- Attached snapshot polling must pause while loading, applying layouts, minimizing, or restoring to avoid AX contention.

## 16.1 Quick Launcher Requirements

- The Quick Launcher is a feature of the main **WindowBoard** application target. It is not a separate application and is not added to the experimental `WindowBoardTree` target.
- The launcher opens from anywhere with `Command-Shift-Space`, and from `Show Quick Launcher` in the Status Item menu.
- It appears as a centered, transient floating panel near the screen containing the pointer. Closing the panel must not terminate or hide the main application.
- Opening the launcher repeatedly reuses one panel/controller and returns keyboard focus to the search field. Pressing the global shortcut while it is open toggles it closed.
- Results are grouped as `Boards`, `Windows`, and `Actions`, with bounded result counts so ordinary typing does not trigger an unbounded list render.
- Search is local and immediate. It matches Board name, saved Board search aliases, application name, window title, owning Board, and action terms while ignoring case, width, diacritics, and Hiragana/Katakana variation. Japanese text containing Kanji is also indexed with a local `ja_JP` tokenized reading, so a reading prefix such as `じゅ` can find `授業`. Multiple terms must all match; exact and prefix matches rank above substring, typo-tolerant, and fuzzy matches; recent successful use may refine ties without overriding clearly stronger text matches. Matching text is visually emphasized in result titles when possible.
- A Board's optional comma-separated search aliases are saved in Board Settings. `>` limits a query to Actions, `@` limits it to Windows, and `#` limits it to Boards.
- The launcher always shows the current selected Board directly below its search field. The matching Board row also has a `Current` badge and checkmark; this indication is independent of the keyboard-selected result that Return will execute.
- Keyboard operation supports Up/Down selection, Return execution, and Escape dismissal. Disabled items cannot be executed, and selection remains stable across live result refreshes when the selected item still exists.
- Board results use the same `WorkspaceSessionController` switch path as the sidebar and Status Item. A result may identify a selected member Board while switching through its Primary Board.
- Current Board window results expose state-appropriate behavior: bring forward when available, restore when minimized, and find or reopen when unavailable. They also provide a `Detach` control that removes the saved reference from its owning Board without closing, minimizing, moving, raising, or reconnecting the external window. Resolving or reconnecting entries remain visible but cannot start a conflicting duplicate operation.
- Saved window references belonging to inactive Boards remain searchable and are marked `Saved`. Selecting one switches to its owning Board; it does not pretend that an inactive saved reference is already a controllable live window.
- Action results include showing the main window, focusing Current Board windows, restoring layout, attaching the frontmost eligible window, recovering missing windows, minimizing others, restoring windows minimized by WindowBoard, and refreshing the main-window candidate list. Each action uses the same session/application operation path as its existing UI equivalent.
- Launcher-triggered Board switching and layout restoration must save outgoing Board state appropriately, preserve unavailable references, reject stale asynchronous completions, and keep Accessibility work off the main thread.
- Accessibility-dependent results are disabled when permission or required runtime state is unavailable. Failures produce a concise status message and leave saved Board/window state recoverable.
- Only one launcher-triggered operation of the same logical target may run at a time. Completion from an older recovery attempt must not overwrite a newer attachment or Board state.

## 17. Performance and Reliability Requirements

- Accessibility reads, writes, app activation, focus, raise, minimize, restore, and recovery polling must not block the main thread.
- Idle behavior must avoid permanent high-frequency polling.
- Window snapshots run at low frequency and update persistence only for meaningful changes.
- Routine snapshots should avoid reading window size; size is read for explicit layout saves and layout restoration as needed.
- Application activation/launch-triggered refreshes are debounced and limited to relevant applications where possible.
- UI updates during Board switching are batched where possible to avoid repeated full card-grid rendering.
- Card icon lookup and tint computation are cached.
- Animations must be reduced or omitted for large card sets when they impair switching responsiveness.
- Debug builds may emit low-noise timing/counter logs; these diagnostics must not be user-facing.

## 18. macOS and Accessibility Limitations

WindowBoard must communicate and behave as best-effort because public macOS APIs do not provide full control of all windows.

- Exact external-window z-order cannot be guaranteed.
- Existing windows on another Space cannot reliably be moved into the current Space.
- Full-screen windows and windows on another Space are not reliable Board targets.
- System panels, special windows, and permission-limited windows may not be controllable.
- Some applications do not permit move, resize, minimize, restore, focus, or raise through Accessibility APIs.
- Closed windows cannot always be reopened to the same document, folder, tab, or internal application state.
- Applications with multiple similar windows may not expose enough metadata to distinguish the original saved window perfectly.
- A failed AX operation must leave the Board reference recoverable whenever possible; it must not silently remove the user's saved intent.

## 19. Non-Goals

The current product does not guarantee or require:

- embedding third-party windows inside WindowBoard;
- strict global z-order control over macOS windows;
- reliable control of full-screen or cross-Space windows;
- exact restoration of all closed-window document/tab/application state;
- automatic resolution of all ambiguous windows from the same application;
- arbitrary window management outside the user's saved Boards.

## 20. Acceptance Checklist

- A user can grant accessibility permission, attach a frontmost or selected window, and see it appear immediately in the Current Board.
- A user can create, save, rename, overwrite, delete, and switch Boards, subject to Default/Permanent Board restrictions.
- A user can compose Current Boards with parallel and child Boards, while invalid cycles and duplicate edges are rejected.
- A user can create Board-child relations by dropping on a sidebar Board center and can create ordered parallel roots by dropping on a sidebar Board edge.
- A user can move a window card to an explicit Board in the Current Board or sidebar without changing the external window itself.
- A user can operate Board switching from either the sidebar or Status Item without diverging behavior.
- A user can see and recover unavailable/minimized saved windows without losing their saved Board membership.
- A user can restore layout, focus Board windows, minimize other windows, and restore only windows minimized by WindowBoard.
- A user can configure follow/fronting behavior and Status Item display values.
- Board switching, card scrolling, and idle operation remain responsive and do not perform unnecessary high-frequency Accessibility work.
- The app behaves safely when macOS or an external app denies a requested window operation.
- A user can open the Quick Launcher globally, search Boards/windows/actions, switch Boards through the shared session path, and execute only state-valid operations without opening a second application.
