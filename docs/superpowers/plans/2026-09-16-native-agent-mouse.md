# Native Agent Mouse Implementation Plan

> Execute the independent wire transport and native integration tasks in this session, then review the combined result.

**Goal:** Enable application-owned selection and clipboard delivery with stock Herdr.
**Architecture:** Version-gated binary terminal control plus a focused client-shell clipboard connection; existing Ghostty view and rendering remain in place.
**Tech Stack:** Swift, AppKit, Unix sockets, Herdr v0.9.0 protocol 22 and endpoint generation 1.
**Spec:** docs/superpowers/specs/2026-09-16-native-agent-mouse.md

## Constraints
- Do not patch or replace the server, restart user sessions, or include unrelated coloring work.
- Keep legacy CLI transport for unsupported server protocols.
- Only the focused visible pane may own the clipboard connection.
- Preserve connection identity during paste and resize, with ordered bounded I/O.

## Task 1: Native wire codec and socket transport
- [x] Add `Sources/HerdrCore/NativeTerminalConnection.swift` and `Tests/HerdrCoreTests/NativeTerminalTests.swift`.
- [x] Test known varint messages, fragmented frames, malformed/truncated data, oversized frames, and mouse event conversion.
- [x] Implement `NativeTerminalConnection(socketPath:pane:cols:rows:takeover:onEvent:)`, `start()`, `send(Data)`, `resize(cols:rows:)`, `scroll(delta:)`, `setFocused(Bool)`, and `stop()`.
- [x] Events: `.frame(Data)`, `.mouseCapture(Bool)`, `.clipboard(Data)`, `.clipboardReady(Bool)`, `.error(String)`. Callbacks may arrive off-main; native coordinator uses generation checks and waits for clipboard readiness before accepting OSC 52 events.
- [x] Match real stock-server messages. Check clipboard via endpoint shell; the direct connection controls sizing for its attached pane, while the client-shell endpoint may resize tabs without direct resize locks on stock Herdr.

## Task 2: Native integration and live regression
- [x] Add server protocol storage and choose native transport for protocol 22 in `TerminalController`.
- [x] Route captured mouse reports through structured messages and reset capture on disconnect. Enable Ghostty mouse modes from server state, retaining Shift bypass.
- [x] Tie clipboard connection to actual native focus/visibility and apply clipboard writes on the main thread.
- [x] Extend live fixture and tests for application selection, OSC 52 delivery, local Shift selection, mode transitions, focus/resize/reconnect.
- [x] Run existing keyboard/paste tests and build/package/sign the app. The synthetic application covers its transport; actual authenticated Claude Code was not exercised.
- [x] Update stock-server compatibility docs and request a focused review before delivery.
