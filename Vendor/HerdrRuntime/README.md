# Herdr runtime mouse-stream patch

This local patch lets uherdr forward clicks to mouse-enabled terminal applications,
including agents with collapsible tool calls. It restores application mouse modes
in the ANSI frames emitted by `herdr terminal session control` and `observe`.
The existing uherdr/Ghostty bridge already understands these sequences; no native
app binary change is required.

Base: [Herdr v0.8.2](https://github.com/herdrdev/herdr/tree/9eb521456ac0d19d3ab3d9d7cea3cca10baa8a4c),
commit `9eb521456ac0d19d3ab3d9d7cea3cca10baa8a4c`, protocol 20.
Source patch: `terminal-mouse-stream.patch`. License: Apache-2.0, included here.
This is a local custom build, not an upstream release.

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
cd .build/herdr-runtime
cargo build --release --locked
mkdir -p ../../dist/herdr-runtime
cp target/release/herdr LICENSE ../../dist/herdr-runtime/
cd ../..
```

On macOS 26, Zig 0.15.2 cannot link some newer SDK stubs. This build used the
installed macOS 15.4 SDK. Zig invokes `xcrun --sdk macosx --show-sdk-path`, so setting
`SDKROOT` alone is insufficient. A temporary build-only `xcrun` wrapper on `PATH`
selected `macosx15.4` instead; system developer settings were not changed.
All temporary Zig cache/tool paths used canonical `/private/tmp` paths to avoid
Zig resolving build-tool paths incorrectly through the `/tmp` symlink.

The verified Apple Silicon binary is at `dist/herdr-runtime/herdr` (git-ignored).
Its SHA-256 is `1c83729cdbf85c1a3ebff1853616f7d7c8666d2868919baa109a54db23baf00f`.
It retains the base `herdr 0.8.2` version string and protocol 20.

## Verify

From the runtime checkout:

```sh
cargo test --locked --bin herdr direct_mouse_stream -- --test-threads=1
cargo test --locked --bin herdr server:: -- --test-threads=1
cargo fmt --check
python3 -m unittest scripts.test_ui_hot_path_architecture
```

From uherdr:

```sh
HERDR_BIN="$PWD/dist/herdr-runtime/herdr" bash scripts/test-terminal-mouse.sh
HERDR_BIN="$PWD/dist/herdr-runtime/herdr" bash scripts/test.sh
```

The mouse test creates and removes a disposable server. It exercises the mounted
production SwiftUI view, injected AppKit mouse events, Ghostty, the CLI, and the
runtime. A raw-mode terminal fixture expands its result only on a press at the
expected cell; release, reconnect, mode-only changes and exit are checked too.
Stock Herdr fails the stream-mode probe; the patched build passes.

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

Remove this patch when an upstream runtime preserves session mouse state and
passes the same native regression. Do not automatically apply it to a different
Herdr version.
