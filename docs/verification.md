# Verification — 2026-09-07

## Native copy-on-selection — 2026-09-16

Automatic copying uses the native client's Ghostty configuration:
`copy-on-select = clipboard`. The embedded wrapper advertises a selection
clipboard but discards writes to it, so the default setting selects text without
updating the macOS clipboard. Explicitly choosing `clipboard` sends the selected
text to the system pasteboard on release. No server customization is required.

A temporary native probe linked against the rebuilt app verified drag selection,
automatic clipboard contents, explicit copy, and selection surviving unrelated
output and same-text redraws. The keyboard, paste, file-drop and URL checks in
the native harness passed. The release app built and its strict signature check
passed.

Application mouse and clipboard events are available in stock Herdr 0.9.0's
binary protocol 22, although its JSON terminal stream discards them. The native
client now uses that protocol and a focused client-shell connection. The optional
`scripts/test-terminal-mouse.sh` exercises application press/drag/release,
OSC 52 clipboard delivery, Shift-drag local copying, PTY dimensions, reconnect,
and mode-only changes against a disposable stock server.

The native mouse suite passed on stock Herdr 0.9.0 (protocol 22), including final
clipboard delivery when the application exits and disables mouse reporting.
The AppKit harness supplies deterministic key-window state and injects mouse
handlers into the production SwiftUI/Ghostty bridge; it does not claim a manual
foreground-window or actual Claude Code check. Wire and Unix-socket lifecycle
tests passed, including fragmented messages, malformed data, input ordering,
custom API socket names and graceful detach before reconnect.

PR #22 follow-up verification: the slow-peer Unix-socket regression reproduced
accepted input loss when a new command batch joined a partially written batch.
Waiting for the outgoing batch to drain fixes it; the test checks all three large
inputs arrive intact and in order. `swift run HerdrCoreTests` passed. The native
mouse suite also passed again, including the pinned Ghostty core's
`copy-on-select = clipboard` behavior through the Shift-drag pasteboard assertion
in `Tests/HerdrMacTests/GhosttyLiveTests.swift`. This run used the installed macOS
26.5 SDK and SwiftPM native build system; the selected macOS 27 Command Line Tools
lacked the SwiftUI macro plugin. Actual Claude Code selection remains untested.

The repository regression components passed after targeted reruns: core/live API,
hotkeys, search, agent-worktree fixtures, pane transfers, native keyboard/paste,
retained-tab performance, terminal stream and SSH forwarding. The first full run
hit an intermittent pane-transfer shell-environment assertion; both the committed
baseline and this branch passed isolated reruns. Performance validation caught an
extra mouse-reset sequence on legacy startup; resetting only when capture changes
restored the existing exact-byte check. No authenticated agent tests ran.
The release app build, strict signature verification, plist validation and
`git diff --check` passed. Packaging builds the `Herdr` product explicitly,
leaving debug-only test executables out of the release build.

Stock clipboard messages lack originating-pane identity. The necessary active
client-shell endpoint can also resize tabs without direct resize locks; see
[paste compatibility](terminal-paste.md#upgrade-compatibility). It starts only
after mouse capture is requested and closes on blur, hide or disconnect.


## Multi-device SSH — 2026-09-08

Implemented on `feat/multi-device-ssh`, forked from `main` at `f9130ce` in a separate worktree. Merged `main` at `f00f25e` to preserve the Ghostty renderer, live-terminal zoom behavior, and worktree-based agent launches alongside multi-device connections.

- `bash scripts/test.sh` passed, including the original protocol, live API, command hints, hotkeys, keyboard encoding, and terminal stream checks.
- New profile/process tests passed: saved-device round trips, migration of old local preferences and selection, SSH input validation, bounded diagnostics, timeout, cancellation, independent tunnels, reuse, private socket permissions, cleanup, host-key/forwarding errors, and reconnect.
- `bash scripts/test-devices.sh` passed against two disposable real herdr servers with overlapping workspace IDs. Verified action isolation, per-device selection, persistence, disconnect/reconnect, remote directory handling, terminal frames/input/resize/scroll through forwarded sockets, and preservation of remote workspaces after detach.
- Independent code review identified a queued-action/disconnect race. A regression test reproduced it before the fix and passed afterward: obsolete queued actions do not dispatch or leave the device busy.
- Integration testing exposed the separate binary terminal socket. Remote connections now forward both the API socket and its derived `-client.sock` companion.
- After merging main, the full suite passed with Ghostty. The production native bridge test verifies terminal input/output through the device's forwarded terminal socket; a fixture usage marker detects accidental bypass of the tunnel. Repeated nested zoom preserves the same terminal surfaces and their content.
- Agent worktree tests use isolated device profiles and injected clients. A new queued-launch/disconnect test verifies that a cancelled connection cannot create a worktree or leave the session busy.
- `bash scripts/build-app.sh`, `codesign --verify --deep --strict dist/Herdr.app`, `plutil -lint dist/Herdr.app/Contents/Info.plist`, and `git diff --check` passed.

The SSH integration harness is explicitly a controlled process stand-in with real Unix-stream forwarding. Authentication and a connection to a physical remote Mac were not exercised. Native multi-device visual interaction was not manually inspected; the app was compiled and its underlying connection/routing behavior exercised. Existing native-window checks below describe the original local-client version.

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

## Coloring acceptance — 2026-09-16

The coloring work was checked with macOS 26.6.2 (25G83), Apple Swift 6.4
(`swiftlang-6.4.0.34.1`), the process-local
`SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk`, and installed
Herdr 0.9.0. macOS 14 and Swift 6.0 remain the minimum documented requirements;
this run does not claim execution on those older versions. No system toolchain
selection or license settings were changed.

All final commands below exited 0 after code changes settled. Every live check
used disposable `/tmp` sockets; `HERDR_TEST_PASTE_AGENTS` was unset, and no paid
agent sessions were started.

| Command | Result |
| --- | --- |
| `swift build --product Herdr` | Passed |
| `swift run HerdrCoreTests` | Passed; catalog, TOML, rule, protocol and metadata fixtures |
| `bash scripts/test-appearance.sh` | Passed; migration, import, caching, settings, native and live appearance |
| `bash scripts/test-hotkeys.sh` | Passed |
| `bash scripts/test-performance.sh` | Passed; publication and repaint regressions |
| `bash scripts/test-terminal-keyboard.sh` | Passed |
| `bash scripts/test-devices.sh` | Passed; two disposable servers and forwarded stream |
| `./scripts/test.sh` | Passed; full live shell, layout, keyboard, search, performance and tunnel suite |
| `./scripts/build-app.sh` | Passed; release app packaged |
| `git diff --check` | Passed |

Output is not pristine: existing Command Line Tools linker warnings about
missing `Developer/usr/lib` and `Developer/Library/Frameworks` search paths
remain. Earlier dependency-build Swift/C++ warnings from pinned TOMLKit are
also a known toolchain limitation, not a claim of clean Swift 6.0 compilation.
An extra benchmark attempted during import development built successfully but
timed out waiting for a foreground window before collecting metrics; it is not
part of the passing required checks above.

The final appearance fixture printed `THEME_PID=51546`, selected the actual
terminal text through Ghostty's public select/copy bindings, and compared the
exact selection after One Light, Nord dark and uherdr light changes. It then
sent input through the existing native terminal, observed the same PID and
`INPUT_CONTINUES_yes`, and read back the original output sentinel plus the first/last lines of the
120-line history fixture from server scrollback. The native view, renderer,
writable-controller object and connection generation stayed unchanged. The
clipboard's original item data was restored after the test. Existing checks
also preserve the Ghostty theme/config for UI-only edits and ANSI/RGB output.

Hidden-tab publication counts match Task 3's measured baseline exactly:
**0 across 3 metadata updates; 0 across 3 UI palette updates**. Reveal publishes
one current snapshot and applies the pending native/terminal appearance before
visibility. No threshold was raised and no eager hidden update was added.

### Native visual inspection

The catalog remains pinned to Herdr
`18061191fdc019498610aee81f0df93f6c2ebd31`; see
[theme provenance](theme-provenance.md). Inspected all 17 concrete upstream
presets, the native uherdr default, and the imported symbolic terminal source
in actual production WorkspaceView/DeviceSidebarView renders. Search showed
two ANSI matches; tabs included selected and inactive states; panes included
focused and unfocused headers/borders; the footer used production status badges
with fixture values. The uherdr light/dark renders retain the prior native
surfaces, green accent, status colors and terminal palettes before selecting
another preset.

Normal and explicit AppKit `accessibilityHighContrastAqua` /
`accessibilityHighContrastDarkAqua` host appearances were rendered. This checks
native high-contrast appearances without changing global preferences; it is
not a live system-wide Increase Contrast toggle test. Explicit upstream RGB
roles remain fixed in that appearance. Selected-tab underlines, focused pane
borders, selected folder icons, textual statuses and accessibility selection
labels remain alongside color.

| Presets inspected | Observations |
| --- | --- |
| Catppuccin, Catppuccin Latte, Dracula | Legible primary text, distinct matches, tab/focus geometry and status labels; some secondary roles are softer. |
| Gruvbox, Gruvbox Light | Legible warm text; selected tab and search remain apparent. Light mustard/green status roles are softer than primary text. |
| Kanagawa, Kanagawa Lotus | Text/search and selection geometry remain apparent; dark red/green status roles are relatively muted. |
| Nord, One Dark, One Light | Primary content and matches readable; inactive borders and secondary text are subtle. |
| Rose Pine, Rose Pine Dawn | Primary text/search readable; dark Rose Pine's Done color is weak against the dark background. Dawn has subtle inactive borders. |
| Solarized, Solarized Light | Lower contrast primary/secondary text and inactive chrome; Solarized Light text/panel is approximately 4.13:1. |
| Tokyo Night, Tokyo Night Day | Text, search and active tab/focus remain apparent; Day uses blue text with softer secondary chrome. |
| Vesper, uherdr, terminal | Primary text readable, geometry retained; muted secondary/reset roles depend on native system backgrounds. |

These observations are not a blanket accessibility or WCAG conformance claim.
Exact upstream values are preserved. Settings now warns about preview pairs
below 4.5:1 and about fixed sidebar foregrounds (including dim opacity) against
sidebar/active-row backgrounds. Warnings never change colors. System material
backgrounds are estimates, so an advisory ratio does not certify every state.

Production Settings was checked at its actual 480-point width, including
scrolling through overrides/rules to the preview and fixed Done/Cancel footer.
Native preset controls remain reachable under both sources, imported controls
are disabled/read-only, and a visible Row gap label now explains its numeric
field. [Middle](images/appearance/settings-middle-native-cache.png) and
[bottom](images/appearance/settings-bottom-native-cache.png) renders preserve
this evidence, including contrast diagnostics.

Deliverable [light/dark theme and conditional sidebar examples](appearance.md#native-rendering-examples)
and [default light](images/appearance/default-light-native-cache.png) /
[default dark](images/appearance/default-dark-native-cache.png) renders are
committed under `docs/images/appearance`. Representative high-contrast
[Search/Solarized Light](images/appearance/solarized-light-increased-native-cache.png)
and [Rose Pine](images/appearance/rose-pine-increased-native-cache.png) renders
show the catalog limitations above.

`/usr/sbin/screencapture -l` could not create a window image in this environment.
All delivered PNGs are actual AppKit `cacheDisplay` renders, not desktop
screenshots or synthetic mockups. The material sidebar is blank in the main
window cache, so separate images render the production sidebar in a plain native
host. The terminal's Metal content was present on this machine. Other platforms
may omit it from view caches.

### Compatibility and scope

The committed `snapshot-0.9-live.json` is a real installed-server response.
Newer optional metadata fixtures are derived from the pinned public schema;
no newer live binary was available or built. Deterministic next-snapshot
metadata removal/expiry, old-server missing fields, legacy title fallback and
device-overlapping IDs are covered. Newer live-server TTL timing is untested.
The [fixture provenance](../Tests/Fixtures/sidebar-snapshot-provenance.md)
explicitly identifies the matching legacy/newer fixture names.

No runtime/vendor edits, remote config writes, automatic file watcher,
cross-machine preference sync, individual resource colors or new terminal
palette controls were added. The [tested minimal TOML](appearance-example.toml)
is exercised by the default appearance runner. Historical verification sections
above describe earlier work and have been preserved.

### Final review follow-ups

The broad whole-branch review at `c183a4c` found no blocking issues. Its three
minor follow-ups now use exact newline-delimited scrollback records, describe
reset as restoring the selected base palette before any native fallback, and
preserve object paths with spaces in both supported generated linker-list
layouts. A focused fixture covers SwiftPM's one-object-per-line layout and the
Swift 6.4/Xcode space-separated response layout with quoted and escaped paths.

With `HERDR_TEST_PASTE_AGENTS` unset and the process-local SDK 26.5 path above,
`bash scripts/test-app-test-link.sh`, `bash scripts/test-appearance.sh`, and
`./scripts/test.sh` all exited 0 on the amended code. The mounted appearance
run observed exact `history-line-1` and `history-line-120` records while
preserving the live shell, selection, renderer and writable controller. The
full suite exercised all shared-helper consumers. Existing linker warning
noise remained unchanged.


## PR #23 review follow-up — 2026-09-17

The nine review findings were addressed: configuration-matched release test
builds, complete sidebar accessibility content, condition-based appearance test
waits, refusal of lossy imported-sidebar copies, omitted empty configured rows,
bounded rendered row spacing, tolerant unknown non-finite TOML fields, rule
cleanup when switching to non-text tokens, and pre-open regular-file validation.
The test linker also now decodes quoted SwiftPM object paths, including TOMLKit's
`Date&Time` filenames, while preserving unquoted paths containing spaces.

Regression evidence: the unknown TOML field failed with
`JSONEncoder.invalidValue(-inf)` before the direct bridge; the native-copy test
failed with `Lossy sidebar copy was accepted` before the guard. Both core and
appearance-store suites passed afterward, including persisted copy diagnostics,
native-state preservation, `/dev/null`, and symlink-to-device rejection. The
quoted-path fixture failed before the linker fix and passed afterward. The
release pane-drag runner passed its transfer, identity, docking, failure, and
selection-race checks.

Validation used Apple Swift 6.4 with the installed macOS 26.5 SDK and SwiftPM's
native build system. Temporary process-local wrappers supplied
`--build-system native --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk`
to SwiftPM and `-sdk` to `swiftc`; no system toolchain setting changed. The default
macOS 27 Command Line Tools attempt failed because its SwiftUI macro plugin was
missing. Existing native-build deprecation/toolchain warnings remain.

A mounted accessibility probe exposed the SwiftUI `NSHostingView` as an `AXGroup`
with no accessible children, even in a frontmost window. The incomplete probe
was removed; the row-label and empty-button fixes were code-reviewed, but this
run does not claim VoiceOver or mounted accessibility-tree verification.

Final `bash scripts/test-appearance.sh` and `bash scripts/test.sh` runs both
exited 0. Mounted appearance checks passed for bounded row spacing, token-rule
compatibility, read-only/imported controls, enabled preset selection, unchanged
terminal/controller identity, exact clipboard selection, shell PID, 120-line
scrollback, and subsequent input. Aggregate validation passed core/live API,
hotkeys, search, agent-worktree fixtures, pane transfers, keyboard/paste/file
handling, retained-tab performance, terminal streaming, and multi-device/SSH
routing. Tests used disposable local sessions with `HERDR_TEST_PASTE_AGENTS`
unset. `git diff --check` passed, and independent code review found no remaining
source issues.

The next automated review found two follow-ups. Native workspace text now
announces every status, including idle/unknown, while the separate status dot is
hidden from accessibility to avoid duplicate announcements; tab/pane counts and
shortcut children remain available. The Settings wait now checks the rendered
Native/Herdr-config segmented control's selected segment in addition to enabled
preset controls, preventing the previous source's UI from satisfying the wait.
The complete appearance suite passed again after both changes; independent
review and whitespace validation passed as well.
