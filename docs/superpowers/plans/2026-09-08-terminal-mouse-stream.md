# Terminal mouse stream implementation plan

> Execute the runtime implementation with subagent-driven-development; the primary agent owns the native integration fixture, build tooling and delivery.

**Goal:** Clicking agent tool calls in uherdr reaches the mouse-enabled terminal application.
**Architecture:** Preserve the runtime's mouse reporting mode and encoding using standard DECSET/DECRST sequences in existing ANSI terminal frames. No wire schema change or JSON migration. Ghostty already interprets these sequences.
**Spec:** User request and the reproduced missing-mode defect in docs/verification.md.
**Constraints:** Base runtime on installed Herdr 0.8.2 (9eb521456ac0d19d3ab3d9d7cea3cca10baa8a4c). Keep ordinary shell selection, terminal query suppression and server scrollback. Do not replace or restart user sessions before a tested artifact is available. Changes to external services are out of scope. Keep runtime changes as a reproducible local patch.

### Task 1: Runtime mode preservation
- [x] Extend existing runtime tests to prove initial mouse state, mode-only changes, encoding changes, disable, reconnect and deferred sends.
- [x] Preserve narrow mouse state in direct terminal ANSI rendering with cached state committed only after successful queueing. Identical cells must not suppress mode updates. Full-app rendering must stay unchanged.
- [x] Include mouse modes 9/1000/1002/1003 and encodings 1005/1006/1015/1016 as actually tracked by the runtime. Clear old modes before changing. Make pixel behavior explicit.
- [x] Run focused Rust tests, formatting and a release build. Review the patch.

### Task 2: Real click validation and delivery
- [x] Use a raw-mode Python terminal fixture that displays collapsed tool text and expands only on a click at the expected cell.
- [x] Exercise production SwiftUI, Ghostty and the actual patched runtime; verify press/release, disable and reconnect.
- [x] Run the existing terminal and stream suites; test stable failure versus patched success.
- [x] Save the upstream patch, base SHA, build instructions and verified runtime artifact in the project; update verification notes.

Review ruling: application mouse projection is opt-in for JSON Control/Observe requests. Legacy interactive Attach keeps its existing host wheel capture. Runtime replacement was validated in a disposable handoff; user-session activation remains a separate operation.
