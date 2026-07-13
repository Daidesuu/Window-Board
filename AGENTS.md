# WindowBoard Agent Notes

## Project Shape
- This is a macOS Xcode project for WindowBoard.
- The app is SwiftUI with narrow AppKit bridges for `NSWindow` observation and click handling.
- External window discovery, movement, minimization, focus, and raise behavior use Accessibility APIs through `AXUIElement`.
- The original single-window MVP is complete. Current work is in the post-MVP workspace/session manager phase.
- Workspace runtime state is centralized in `WorkspaceSessionController`; keep main-window and Status Item workspace switching on that shared path.
- User-facing UI uses the term **Board**, while internal persistence and session types still use `Workspace...`. Do not perform a global rename without a dedicated migration/refactor plan.
- The current main UI is a card-board layout split across `BoardCardViews`, `BoardDetailViews`, `BoardSidebarViews`, `BoardSupportingViews`, and `BoardToolbarControls`. Pinned windows are app-tinted cards with a trailing Add Window card.
- `ContentView` remains the main SwiftUI composition and routing layer, but asynchronous operation policy is split into focused internal components:
  - `ApplicationWindowCatalog` for external-window listing and cache merging
  - `AttachedWindowRecoveryCoordinator` and `AttachedWindowRecoveryResolver` for explicit recovery and matching
  - `BoardFollowCoordinator` for follow timing and movement planning
  - `BoardFrontingCoordinator` for fronting debounce, cancellation, and revision policy
  - `AttachedWindowSnapshotCoordinator` for low-frequency off-main AX sampling
  - `AttachedWindowSnapshotReducer` for pure snapshot-result state transitions
- Keep these coordinators narrow. They must not independently own workspace/session state or bypass `AccessibilityWindowService` as the AX boundary.

## Build And Run
- Prefer `./script/build_and_run.sh` for normal build/run verification.
- Use `./script/build_and_run.sh --verify` when confirming that the app launches.
- For compile-only checks, use:
  - `xcodebuild -project WindowBoard.xcodeproj -scheme WindowBoard -configuration Debug -derivedDataPath build/DerivedData build`
- For the XCTest suite, use:
  - `xcodebuild -project WindowBoard.xcodeproj -scheme WindowBoard -configuration Debug -derivedDataPath build/DerivedData test`
- The test target covers pure matching/resolution logic, workspace-session transitions with fake window services, recovery, follow/fronting policy, and snapshot coordination/reduction. Add focused tests when changing these areas.
- Launching the macOS GUI app may require elevated execution approval.

## Implementation Guidelines
- Keep changes scoped to the current workspace/session behavior unless the user explicitly asks for broader product work.
- Avoid blocking the main thread with Accessibility calls. Prefer background queues/tasks for AX reads, moves, minimize/restore, and fronting operations.
- Treat closed or stale AX windows as recoverable/unavailable state where possible; do not silently detach user-selected windows unless explicitly requested.
- Do not assume macOS can restore the exact same closed window. Reconnection should be best-effort using bundle, document URL, title, and app identity.
- Preserve the current UI controls and option names unless the user requests wording changes.
- Do not split workspace switching logic between the main window and Status Item. Add behavior to `WorkspaceSessionController` first, then have callers pass UI-specific context such as board origin or cached windows.
- Prefer fast UI updates followed by background AX work. Workspace switches may show placeholder attached windows before every AX operation has finished.

## Sub-Agent Assignment
- Prefer assigning sub-agents by risk area, not by feature surface. WindowBoard bugs often cross UI, session state, and Accessibility behavior, so each sub-agent should have a clear ownership boundary.
- Use a **Session / Workspace Agent** for `WorkspaceSessionController`, `WorkspaceStore`, workspace save/load/switch/recovery, and Status Item workspace switching. This agent should own state consistency and should be the only agent making primary changes to workspace switching logic.
- Use an **AX / Window Operations Agent** for `AccessibilityWindowService`, window movement, minimize/restore, focus/raise, and AppKit/AX limitations. This agent should check that AX calls stay off the main thread and that failures leave windows recoverable rather than detached.
- Use a **UI / UX Agent** for `ContentView`, `BoardCardViews`, `BoardDetailViews`, `BoardSidebarViews`, `BoardSupportingViews`, `BoardToolbarControls`, `SettingsView`, labels, layout, and state presentation. This agent should avoid changing session semantics unless coordinated with the Session / Workspace Agent.
- Use a **Performance / Regression Agent** for timing-sensitive workspace switching, snapshot/minimize/restore contention, Status Item vs main-window path comparisons, and build/run verification. This agent should focus on investigation, measurement, and regression review.
- For workspace switching, save/load, or Status Item behavior, assign **Session / Workspace Agent + Performance / Regression Agent**.
- For minimize, restore, follow, fronting, or external window movement, assign **AX / Window Operations Agent + Performance / Regression Agent**.
- For labels, toolbar, layout, settings, or attached row presentation, assign **UI / UX Agent + Session / Workspace Agent**.
- Do not let multiple agents independently edit `WorkspaceSessionController` for the same task. One Session / Workspace owner should coordinate changes there; other agents should review or propose changes.

## Review Workflow
- Default to a Codex-first development flow:
  - Codex implements the requested change.
  - Codex reviews its own diff against the current codebase before reporting completion.
  - Codex handles clear bugs, compile errors, obvious type errors, and small fixes without Oracle.
  - Do not use Oracle for every task.
- Use **Codex review** for all implemented changes. The primary agent should review the diff directly, focusing on regressions, race conditions, state consistency, missing verification, and adherence to this `AGENTS.md`.

### When To Use Oracle
- Use the local `oracle` skill/CLI as a second-model advisory review only when it is likely to add value, such as:
  - an unexplained bug remains and Codex cannot narrow the likely causes enough on its own
  - the change involves high-impact design decisions around Accessibility API, window management, or SwiftUI state management
  - a large refactor was performed
  - a pre-release review is requested
  - a change spans enough files or subsystems that third-party review is useful
- For unresolved or recurring bugs, include `PROJECT_STATE.md`, the relevant source files, and the exact observed symptom in the Oracle prompt. Ask Oracle to identify likely failing branches and diagnostics before asking for code changes.
- Prefer `--dry-run summary --files-report` before sending a real Oracle browser/API run so the file set and token size are visible.

### When Not To Use Oracle
- Do not use Oracle for:
  - simple syntax errors
  - obvious type errors
  - small UI wording changes
  - lightweight one- or two-file changes
  - problems that local inspection, build output, or a targeted run can resolve directly
  - any task where the user explicitly says not to use Oracle
- Do not use Oracle API mode without explicit user approval because it can incur cost. Browser mode may take time and may control Chrome; mention this when starting a real run.

### Handling Oracle Output
- Treat Oracle output as advisory, not authoritative.
- Verify every Oracle recommendation against the local code, macOS/AX constraints, and build/run results before implementing it.
- Adopt only recommendations that are technically justified and low-risk for the requested scope.
- If rejecting an Oracle recommendation, explain why.
- After implementation, briefly report what was changed and how it was verified.

### Reporting Oracle Reviews
- When Oracle was used, include these points in the final report:
  - what was sent to Oracle for review
  - Oracle's main findings
  - which findings were accepted
  - which findings were rejected or deferred, and why
  - what was implemented or fixed

### WindowBoard Oracle Review Focus
- For this macOS SwiftUI app, Oracle reviews should pay special attention to:
  - Accessibility API usage
  - external app window detection, activation, reopen, and reconnect behavior
  - SwiftUI state update timing
  - inconsistencies among `Unavailable`, front-window recovery, and card state
  - AppKit and SwiftUI responsibility boundaries
  - low-risk fixes that avoid unnecessary broad refactors

## Current Behavior Expectations
- Attached list order is user-visible state, but strict macOS z-order guarantees are not reliable with public APIs.
- `Follow Mode: None` means attached windows remain selected but do not follow board movement.
- `Find or Reopen` should reopen the app/document when possible and reconnect to a matching new AX window. `Use Front Window` is an explicit same-application fallback and must not silently attach a different app's window.
- `Minimize Unattached` is best-effort and may not affect system, special, full-screen, cross-Space, or permission-limited windows.
- Full-screen windows and windows on another Space are not reliable workspace targets. Do not present them as supported; public macOS APIs cannot reliably move another app's existing window into the current Space or control full-screen app Spaces.
- `Minimize Unattached On Workspace Switch` runs after the workspace switch has been shown; do not make workspace loading wait for all minimize operations.
- Switch-time minimize should reuse known window candidates from workspace switching where possible instead of always forcing a fresh full `listWindows()` pass.
- `Restore Missing Windows On Workspace Switch` controls whether workspace switching automatically opens/activates missing windows. Keep the default off; `Find or Reopen` remains the explicit recovery path.
- When `Restore Missing Windows On Workspace Switch` is off, do not run automatic open/activate/poll recovery for failed workspace-application windows during switching; keep them attached as unavailable.
- VS Code windows should not be protected by broad same-application ambiguity fallback; only the concretely matched attached window should be protected from minimize.
- Workspace switching should keep attached windows selected even when they are closed, stale, minimized, or temporarily unavailable.
- Workspace switching uses placeholder attached windows first, then replaces each row as matching live AX windows are found.
- Workspace switch recovery should fire open/activate requests for unresolved windows as a group, then use a shared polling loop rather than per-window polling loops.
- During workspace fronting, WindowBoard may temporarily use `.floating` regardless of the persistent `Keep Window Board On Top` setting, then restore the configured level.
- Workspace layout saves and restores both window position and optional window size. Size restore is best-effort and should not detach windows on failure.
- Status Item workspace switches should save the active workspace first without opening the WindowBoard window, preserving existing relative offsets and updating saved absolute positions where possible.
- Attached window position snapshots should stay low-frequency, run AX reads off the main thread, and persist only meaningful changes.
- Snapshot scheduling and sampling belong in `AttachedWindowSnapshotCoordinator`; snapshot state transitions belong in `AttachedWindowSnapshotReducer`. Keep session mutation and persistence execution at the caller boundary.
- Snapshot results from an old coordinator revision, a different active workspace, a stale window ID, or a reconnecting attachment must not overwrite current state.
- Preserve snapshot state semantics: minimized windows are recoverable/available, normal live windows become unavailable only after repeated read failures, and `pid == 0` placeholders may become unavailable immediately.
- Workspace-specific Status Item display may be an SF Symbol, emoji, or short text value saved on the workspace.
- `setPosition`, `setSize`, minimize/restore, and fronting operations should skip no-op work where possible and run off the main thread.
- Debug builds may include lightweight `Logger` timing around expensive workspace operations; keep this diagnostic logging low-noise and non-user-facing.

## Safety
- Do not use destructive git commands unless explicitly requested.
- Do not revert user changes.
- Keep generated build artifacts in existing build/dist locations.
