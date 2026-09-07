# Herdr Native Client Implementation Plan

**Goal:** Build a runnable native macOS client for herdr with spaces, tabs, agents, and nested terminal splits.

**Architecture:** SwiftUI window and AppKit terminal surfaces share a main-actor observable session store. A serial background Unix-socket client communicates with the herdr runtime. Models represent server IDs and layout trees without replacing running PTYs.

**Tech Stack:** Swift 6 tools, SwiftUI, AppKit, Foundation, Darwin sockets; macOS 14+.

**Spec:** docs/superpowers/specs/2026-09-07-native-client-design.md

## Global constraints
- macOS 14+; native UI and terminal drawing.
- Existing sessions remain alive when the app exits.
- Integration tests use only a disposable named session.
- Build using the installed command-line Swift toolchain.

## Tasks
- [x] Verify upstream socket and terminal transport, then capture representative protocol fixtures.
- [x] Add a Swift package with core models and tests for snapshot decoding, nested split decoding, and malformed responses. Run tests before completing the model implementation.
- [x] Implement serialized local socket requests with timeouts, complete writes, bounded responses, and server error propagation. Verify against a temporary socket and a disposable herdr runtime.
- [x] Implement the session store: load/refresh, connection preferences, workspace/tab/pane mutations, split ratio changes, agent actions, and ordered terminal input.
- [x] Implement native shell: spaces and agents sidebar, tab strip, nested resizable panes, create/rename/close sheets, settings, and menus.
- [x] Implement interactive AppKit terminal rendering using the verified upstream transport; check keyboard input, colors, Unicode, copy/paste, scrolling, and resizing.
- [x] Package a .app, run core and live integration checks, visually inspect the actual native window, and document build/run instructions and limits.

## Validation
Use `swift run HerdrCoreTests` for core behavior; the installed Command Line Tools do not include XCTest. Use `swift build -c release` and `scripts/build-app.sh` for delivery. A live integration executable must create its own workspace, split right and down, modify a split ratio, send a marker command, verify output, rename resources, and close only those resources. GUI inspection must exercise selection, split dividers, tab switching, and terminal input.
