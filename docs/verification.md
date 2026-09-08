# Verification — 2026-09-07

Built and inspected on Apple Silicon macOS using Swift 6.3.3 and herdr 0.8.2 (protocol 20).

## Automated checks

- `./scripts/test.sh` — passed. Creates its own named runtime under a temporary directory and stops/cleans it afterward.
- 10 core tests — nested right/down layouts, invalid layout rejection, server errors and request IDs, split UTF-8 frames, ANSI decoding, oversized frames, missing sockets, and zoomed/unzoomed pane selection.
- Live API tests — workspace/tab/pane create and close, nested splits, split ratio update, shell command input and output, agent status decoding, rename, and layout collapse after pane close.
- Terminal stream tests — ANSI frames, interactive input, resize to 110×35, scrolling, and detach without destroying the pane.
- `./scripts/build-app.sh` — release build and app packaging passed.
- `codesign --verify --deep --strict dist/Herdr.app` and `plutil -lint dist/Herdr.app/Contents/Info.plist` — passed.

## Native window checks

Used the actual packaged app with a disposable session, not a browser mockup:

- Created a project space through the native sheet.
- Split right, then split the right pane down.
- Dragged the divider and checked resized terminal rendering.
- Typed a shell command and verified its output in the selected pane.
- Created a second tab and verified output persisted across tab switches.
- Zoomed two different tabs and verified immediate typing after switching targeted the visible pane.
- Checked both light and dark appearance; restored System appearance afterward.
- Injected an explicitly labeled temporary agent-status fixture, verified its Blocked badge in the Agents sidebar, and selected it to reveal the corresponding pane.

Third-party agent credentials and real provider calls were not exercised. Agents must already be installed and authenticated as required by their respective CLIs. Test-only agent metadata and runtime state were removed with the disposable session.

## Corrections made during verification

- Gave zoomed terminal views stable terminal identities to prevent connection reuse across tabs.
- Resolved the visible zoomed pane immediately when switching tabs and restored keyboard focus after AppKit view attachment.
- Expanded saved tilde socket paths on initial launch.
- Removed pipe readability handlers on EOF.
- Rebuilt app bundles from clean output so read-only dependency resources do not break repeated packaging.

## Workspace shortcuts

- Added native Command-1 through Command-9 menu shortcuts using the complete workspace order.
- Workspace cards reveal their matching shortcut while Command is held; hints keep their numbering during sidebar search.
- `scripts/test-hotkeys.sh` passed for holding/releasing Command, combined modifiers, app deactivation, inactive state, and observer cleanup.
- Verified Command-1, Command-2, and Command-3 in the packaged app against three disposable workspaces, including terminal focus and a filtered sidebar.
- The release build and existing 10 core tests passed. The hold-state transitions were checked directly against the AppKit observer; UI automation verified the workspace-switching actions.
# Ghostty prototype — 2026-09-08

SwiftTerm has been replaced with the pinned GhosttyTerminal wrapper. The full
`bash scripts/test.sh` suite passed, including real AppKit Ghostty surfaces and
a disposable Herdr server through the production SwiftUI bridge:

- Unicode output, grid resize, Enter/Shift-Enter/keypad Enter, Option-Enter,
  negotiated keyboard mode, bracketed paste, and focus isolation.
- Server-frame query suppression, font changes preserving the surface,
  shell input/output, reconnect, and teardown preserving the server pane.
- Resource resolution from a macOS app bundle without using the build path.

`bash scripts/build-app.sh` builds the release app; its ad-hoc signature passes
`codesign --verify --deep --strict dist/Herdr.app`.
These checks use shell fixtures, not an interactive Claude Code session.
The vendored wrapper's provenance and two local compatibility changes are
documented in `Vendor/GhosttyTerminal/README.md`.

## Pane zoom — 2026-09-08

Zoom and restore keep the split tree and its terminal surfaces mounted, changing
pane geometry and visibility without reconnecting the streams. Hidden terminals
stop rendering and ignore focus and mouse/scroll events.

`bash scripts/test.sh` passed, including a live regression that repeats zoom and
restore on a bottom-right nested pane, checks that all three native terminal views
survive, and verifies restored split sizes, retained output, and subsequent input.
The regression reproduced terminal recreation before the fix.
`bash scripts/build-app.sh`, the strict code-signature check, and the app plist
check passed for the updated `dist/Herdr.app`.
