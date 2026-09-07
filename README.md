# Herdr for macOS

A native SwiftUI + AppKit client for the herdr runtime. Spaces map to herdr workspaces; each space has tabs with nested, resizable terminal panes. The Agents view shows detected agents and their status.

## Requirements

- macOS 14 or newer.
- Swift command-line tools (Swift 6.0 or newer) to build.
- herdr 0.8.2 or newer with `herdr terminal session control` support.

## Build and run

```sh
./scripts/build-app.sh
open dist/Herdr.app
```

Open `Package.swift` in Xcode to develop the app, or use `swift build` and `swift run HerdrCoreTests` from a terminal. Swift Package Manager downloads the pinned SwiftTerm dependency on the first build.

The app uses your default local herdr socket. Set an explicit socket and the herdr executable in Settings to connect to a named session. Start herdr first, or use the app's Start Server button. Quit detaches the client; shells and agents remain owned by herdr.

## Interaction

- Sidebar: switch between Spaces and Agents; select a space or jump to an agent. Command-1 through Command-9 select the first nine spaces in sidebar order. Hold Command to reveal shortcut badges on the space cards. Search filtering does not renumber shortcuts.
- Tabs: create with Command-T; rename and close from the context menu.
- Panes: Command-D splits side by side; Command-Shift-D stacks panes. Drag the divider to resize. Use the pane header to focus, zoom, rename, start an agent, or close.
- Terminal: normal keyboard input, native text selection, Command-C/Command-V, and mouse-wheel scrolling.
- Command-N creates a space. Command-comma opens Settings.

Closing a pane, tab, or space terminates its processes and therefore asks for confirmation. Terminal ownership conflicts are shown on the affected pane; Take Control explicitly replaces the previous writable controller.

## Architecture

`HerdrCore` contains Codable protocol models, bounded JSON line parsing, and local Unix socket requests. `HerdrMac` contains the SwiftUI shell, session store, and SwiftTerm AppKit bridge. Each visible terminal uses `herdr terminal session control` with JSON messages on standard input and base64 ANSI frames on standard output. The CLI handles herdr's binary protocol negotiation. Shells are never spawned as substitutes for server panes.

Connection state is refreshed from authoritative snapshots. UI actions use explicit server resource IDs. Window geometry and connection/appearance preferences are persisted locally.

## Distribution

The build script creates an ad-hoc-signed app for local use. Distribution to other Macs requires your own Developer ID signing and notarization. The herdr runtime is installed separately.

## Dependencies

[SwiftTerm](https://github.com/migueldeicaza/SwiftTerm), MIT license, supplies the native terminal emulator. [Herdr](https://github.com/herdrdev/herdr) supplies the runtime and terminal/control protocols.

## Verification

```sh
swift run HerdrCoreTests  # Protocol, layout, selection, and error handling
./scripts/test-hotkeys.sh # Command-key hint lifecycle
./scripts/test.sh         # Also starts and cleans up an isolated herdr server
```

The standalone Swift test runner works with Command Line Tools; XCTest is not required. Live tests cover workspace/tab/pane lifecycle, nested right/down splits, divider ratios, shell input/output, agent status fixtures, terminal ANSI streaming, resize, scrolling, and detach preservation. They accept only an explicitly disposable socket under `/tmp`.

Topology and agent status refresh every 1.25 seconds and after actions; terminal output streams continuously. Only visible terminals acquire writable controllers. Remote SSH connections and Kitty graphics overlays are not included in this version.
