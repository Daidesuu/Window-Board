# WindowBoard Agent Notes

## Project Shape
- This is a macOS Xcode project for WindowBoard.
- The app is SwiftUI with narrow AppKit bridges for `NSWindow` observation and click handling.
- External window discovery, movement, minimization, focus, and raise behavior use Accessibility APIs through `AXUIElement`.

## Build And Run
- Prefer `./script/build_and_run.sh` for normal build/run verification.
- Use `./script/build_and_run.sh --verify` when confirming that the app launches.
- For compile-only checks, use:
  - `xcodebuild -project WindowBoard.xcodeproj -scheme WindowBoard -configuration Debug -derivedDataPath build/DerivedData build`
- Launching the macOS GUI app may require elevated execution approval.

## Implementation Guidelines
- Keep changes scoped to the MVP behavior unless the user explicitly asks for broader product work.
- Avoid blocking the main thread with Accessibility calls. Prefer background queues/tasks for AX reads, moves, minimize/restore, and fronting operations.
- Treat closed or stale AX windows as recoverable/unavailable state where possible; do not silently detach user-selected windows unless explicitly requested.
- Do not assume macOS can restore the exact same closed window. Reconnection should be best-effort using bundle, document URL, title, and app identity.
- Preserve the current UI controls and option names unless the user requests wording changes.

## Current Behavior Expectations
- Attached list order is user-visible state, but strict macOS z-order guarantees are not reliable with public APIs.
- `Follow Mode: None` means attached windows remain selected but do not follow board movement.
- `Open / Reconnect` should reopen the app/document when possible and reconnect to a matching new AX window.
- `Minimize Unattached` is best-effort and may not affect system, special, full-screen, cross-Space, or permission-limited windows.
- Workspace switch minimization should classify against a freshly read window list, not only the cached UI list.
- VS Code windows should not be protected by broad same-application ambiguity fallback; only the concretely matched attached window should be protected from minimize.

## Safety
- Do not use destructive git commands unless explicitly requested.
- Do not revert user changes.
- Keep generated build artifacts in existing build/dist locations.
