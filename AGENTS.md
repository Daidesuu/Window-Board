# WindowBoard Agent Notes

## Project Shape
- This is a macOS Xcode project for WindowBoard.
- The app is SwiftUI with narrow AppKit bridges for `NSWindow` observation and click handling.
- External window discovery, movement, minimization, focus, and raise behavior use Accessibility APIs through `AXUIElement`.
- The original single-window MVP is complete. Current work is in the post-MVP workspace/session manager phase.
- Workspace runtime state is centralized in `WorkspaceSessionController`; keep main-window and Status Item workspace switching on that shared path.

## Build And Run
- Prefer `./script/build_and_run.sh` for normal build/run verification.
- Use `./script/build_and_run.sh --verify` when confirming that the app launches.
- For compile-only checks, use:
  - `xcodebuild -project WindowBoard.xcodeproj -scheme WindowBoard -configuration Debug -derivedDataPath build/DerivedData build`
- Launching the macOS GUI app may require elevated execution approval.

## Implementation Guidelines
- Keep changes scoped to the current workspace/session behavior unless the user explicitly asks for broader product work.
- Avoid blocking the main thread with Accessibility calls. Prefer background queues/tasks for AX reads, moves, minimize/restore, and fronting operations.
- Treat closed or stale AX windows as recoverable/unavailable state where possible; do not silently detach user-selected windows unless explicitly requested.
- Do not assume macOS can restore the exact same closed window. Reconnection should be best-effort using bundle, document URL, title, and app identity.
- Preserve the current UI controls and option names unless the user requests wording changes.
- Do not split workspace switching logic between the main window and Status Item. Add behavior to `WorkspaceSessionController` first, then have callers pass UI-specific context such as board origin or cached windows.
- Prefer fast UI updates followed by background AX work. Workspace switches may show placeholder attached windows before every AX operation has finished.

## Current Behavior Expectations
- Attached list order is user-visible state, but strict macOS z-order guarantees are not reliable with public APIs.
- `Follow Mode: None` means attached windows remain selected but do not follow board movement.
- `Open / Reconnect` should reopen the app/document when possible and reconnect to a matching new AX window.
- `Minimize Unattached` is best-effort and may not affect system, special, full-screen, cross-Space, or permission-limited windows.
- Full-screen windows and windows on another Space are not reliable workspace targets. Do not present them as supported; public macOS APIs cannot reliably move another app's existing window into the current Space or control full-screen app Spaces.
- `Minimize Unattached On Workspace Switch` runs after the workspace switch has been shown; do not make workspace loading wait for all minimize operations.
- `Restore Missing Windows On Workspace Switch` controls whether workspace switching automatically opens/activates missing windows. Keep the default off; `Find or Reopen` remains the explicit recovery path.
- VS Code windows should not be protected by broad same-application ambiguity fallback; only the concretely matched attached window should be protected from minimize.
- Workspace switching should keep attached windows selected even when they are closed, stale, minimized, or temporarily unavailable.
- Workspace switching uses placeholder attached windows first, then replaces each row as matching live AX windows are found.
- Workspace switch recovery should fire open/activate requests for unresolved windows as a group, then use a shared polling loop rather than per-window polling loops.
- During workspace fronting, WindowBoard may temporarily use `.floating` regardless of the persistent `Keep Window Board On Top` setting, then restore the configured level.
- Workspace layout saves and restores both window position and optional window size. Size restore is best-effort and should not detach windows on failure.
- Status Item workspace switches should save the active workspace first without opening the WindowBoard window, preserving existing relative offsets and updating saved absolute positions where possible.
- Attached window position snapshots should stay low-frequency, run AX reads off the main thread, and persist only meaningful changes.
- Workspace-specific Status Item display may be an SF Symbol, emoji, or short text value saved on the workspace.
- `setPosition`, `setSize`, minimize/restore, and fronting operations should skip no-op work where possible and run off the main thread.

## Safety
- Do not use destructive git commands unless explicitly requested.
- Do not revert user changes.
- Keep generated build artifacts in existing build/dist locations.
