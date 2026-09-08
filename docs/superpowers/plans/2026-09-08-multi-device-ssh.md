# Multi-device SSH Implementation Plan

**Goal:** Browse and work in all saved devices from one sidebar.

**Architecture:** A DeviceStore owns one independent SessionStore per saved DeviceProfile. Remote sessions use one managed OpenSSH connection forwarding the API and companion terminal Unix sockets.

**Tech Stack:** Swift, SwiftUI/AppKit, Foundation Process, OpenSSH; macOS 14+, existing SwiftTerm and herdr requirements.

**Spec:** `docs/superpowers/specs/2026-09-08-multi-device-ssh-design.md`

- [x] Add Codable device profiles, strict SSH argument/path validation, remote discovery, and cancellable process/tunnel lifecycle. Test persistence, unsafe inputs, timeouts, stderr, and cleanup in HerdrCoreTests.
- [x] Introduce DeviceStore and adapt SessionStore for device-specific clients, persistence, reconnect, remote directories, and disconnect. Verify with two isolated servers whose IDs overlap.
- [x] Add grouped device sidebar and connection editor; keep actions/sheets bound to their source session. Recreate detail views on device switches and pass effective tunnel sockets to terminals.
- [x] Document SSH prerequisites and usage. Run the full build, local integration/keyboard tests, multi-device tests, and review the diff for lifecycle and routing errors.

All implementation takes place on `feat/multi-device-ssh` in its worktree. Leave the user's uncommitted main-checkout changes untouched; do not merge or publish.
