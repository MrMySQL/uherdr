# Herdr runtime terminal-mode patches

This local patch lets uherdr forward clicks to mouse-enabled terminal applications,
including agents with collapsible tool calls. It restores application mouse modes
in the ANSI frames emitted by `herdr terminal session control` and `observe`.
The existing uherdr/Ghostty bridge already understands these sequences; no native
app binary change is required.

Base: [Herdr v0.8.2](https://github.com/herdrdev/herdr/tree/9eb521456ac0d19d3ab3d9d7cea3cca10baa8a4c),
commit `9eb521456ac0d19d3ab3d9d7cea3cca10baa8a4c`, protocol 20.
Apply `terminal-mouse-stream.patch`, then `terminal-bracketed-paste.patch`.
License: Apache-2.0, included here.
This is a local custom build, not an upstream release.

## Long multiline paste

Herdr 0.8.2 omits DEC mode 2004 (bracketed paste) from its reconstructed
terminal stream. Ghostty consequently sends clipboard newlines as ordinary
input instead of enclosing the text in `ESC [ 200 ~` / `ESC [ 201 ~`. Agent
input can be submitted or split before the final lines arrive.

`terminal-bracketed-paste.patch` extends the mouse patch's narrow mode snapshot
to include the live application's bracketed-paste state. It restores enabled
and disabled states on attach/reconnect, forwards mode-only changes, and commits
the baseline only after an output frame is queued. Scrollback disables mouse
capture while retaining paste framing for the live application. Interactive
`terminal attach` and the full TUI retain their existing host mode ownership.
The Swift app and wire protocol do not change.

## Behavior

- Initial attachment and reconnect restore mouse state, including an explicitly
  disabled state when returning to a shell.
- Changes to mouse modes produce frames even when no visible cells change.
- Failed output queue sends do not advance the mouse-state baseline.
- Viewing server scrollback disables application mouse reporting; returning to
  the live viewport restores it.
- Only JSON session control/observe opt in. The interactive `terminal attach`
  command retains its own wheel capture, and full-app terminal rendering is unchanged.
- No JSON or binary protocol schema changes are needed.

## Build

Install Rust 1.96.1 and Zig 0.15.2. From the uherdr repository:

```sh
git clone --depth 1 --branch v0.8.2 https://github.com/herdrdev/herdr.git .build/herdr-runtime
git -C .build/herdr-runtime rev-parse HEAD # Must match the base commit above.
git -C .build/herdr-runtime apply ../../Vendor/HerdrRuntime/terminal-mouse-stream.patch
git -C .build/herdr-runtime apply ../../Vendor/HerdrRuntime/terminal-bracketed-paste.patch
cd .build/herdr-runtime
cargo build --release --locked
mkdir -p ../../dist/herdr-runtime
cp target/release/herdr LICENSE ../../dist/herdr-runtime/
cd ../..
```

Zig 0.15.2 cannot link some newer macOS SDK stubs. This build used the
macOS 15.4 SDK. For the paste build, a temporary copy was used after the
system command-line tools update removed that SDK. Zig invokes `xcrun --sdk macosx --show-sdk-path`, so setting
`SDKROOT` alone is insufficient. A temporary build-only `xcrun` wrapper on `PATH`
returned the temporary SDK path instead; system developer settings were not changed.
All temporary Zig cache/tool paths used canonical `/private/tmp` paths to avoid
Zig resolving build-tool paths incorrectly through the `/tmp` symlink.

The verified Apple Silicon binary is at `dist/herdr-runtime/herdr` (git-ignored).
Its SHA-256 is `550b05ada3551396a4157dc2aff2009c1b6b7dbac0c36fef7c2a17067cf9b368`.
It retains the base `herdr 0.8.2` version string and protocol 20.

## Verify

From the runtime checkout:

```sh
cargo test --locked --bin herdr direct_mouse_stream -- --test-threads=1
cargo test --locked --bin herdr direct_paste_stream -- --test-threads=1
cargo test --locked --bin herdr server:: -- --test-threads=1
cargo fmt --check
python3 -m unittest scripts.test_ui_hot_path_architecture
```

From uherdr:

```sh
HERDR_BIN="$PWD/dist/herdr-runtime/herdr" bash scripts/test-terminal-mouse.sh
HERDR_BIN="$PWD/dist/herdr-runtime/herdr" bash scripts/test-terminal-paste.sh
HERDR_TEST_PASTE_AGENTS=1 HERDR_BIN="$PWD/dist/herdr-runtime/herdr" bash scripts/test-terminal-paste.sh
HERDR_BIN="$PWD/dist/herdr-runtime/herdr" bash scripts/test.sh
```

The mouse test creates and removes a disposable server. It exercises the mounted
production SwiftUI view, injected AppKit mouse events, Ghostty, the CLI, and the
runtime. A raw-mode terminal fixture expands its result only on a press at the
expected cell; release, reconnect, mode-only changes and exit are checked too.
Stock Herdr fails the stream-mode probe; the patched build passes.

The paste test uses a raw PTY fixture to compare all 41,531 bytes, including
bracketed framing and the last two lines. The opt-in agent check requires
`claude` and `codex` on `PATH`. It starts each CLI in an empty temporary folder,
accepts that folder's trust prompt, pastes 400 numbered Unicode lines through
Ghostty's actual clipboard action, then exports the full draft with Ctrl-G.
The temporary editor copies the draft and clears it; no prompt is submitted.
The clipboard is restored afterward. The test checks the exported draft byte
for byte, so a collapsed paste indicator alone cannot produce a pass.

Verified on 2026-09-14 with Claude Code 2.1.265 and Codex CLI 0.154.0:
both exported all 41,530 UTF-8 bytes from the native clipboard test, including
the final two lines. The raw PTY regression failed on the original runtime
(missing both paste delimiters) and passed on the patched release. A separate
unframed Claude probe retained only the final 732 of 19,128 characters; Codex
inferred a paste successfully in the direct-input probes, so those probes did
not independently reproduce truncation in Codex.

The 268 server tests and the native paste/keyboard checks pass. The broad
`scripts/test.sh` run reaches the existing performance fixture's
`Timed out: reveal and catch up` failure with both the original mouse-only
runtime and the new runtime; it is not a clean full-suite pass. The docking
check now waits for the replacement view to settle before sending input,
because the old focused view can briefly report ready during SwiftUI remounts.
This checks input after docking; input during an active remount is not covered.

## Activation

The server process, not just the CLI, must run the patched binary. Pointing uherdr
at a new executable does not replace an already-running server. For the local
server, Herdr supports a live handoff:

```sh
HERDR_SOCKET_PATH="$HOME/.config/herdr/herdr.sock" herdr server live-handoff \
  --import-exe "$PWD/dist/herdr-runtime/herdr" \
  --expected-protocol 20 --expected-version 0.8.2
```

Use the intended session's socket. Handoff reconnects clients and carries live
PTY processes into the new server. An isolated stock-to-patched handoff preserved
both shell and foreground fixture process IDs and allowed tool expansion after
reconnect. Existing Herdr handoff bounds replayed terminal history; this patch
does not change that behavior. Remote servers need their own platform build.

## Limits and removal

Standard SGR cell mouse input (1006) is verified end to end. Pixel mode (1016)
bits are preserved, but uherdr currently sends only rows/columns on resize;
accurate pixel-coordinate application behavior is not covered. The current
Ghostty C API exposes mode bits rather than the last-set ordering of competing
mouse modes; unusual simultaneous tracking/encoding combinations retain that
limitation. No new scan across inactive panes is added.

Remove these patches when an upstream runtime preserves session mouse and
bracketed-paste state and passes the same native regressions. Do not automatically apply it to a different
Herdr version.
