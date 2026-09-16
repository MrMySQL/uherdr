# Native clipboard paste

Use the native app with an official Herdr **0.9.0 or newer server and CLI**.
No custom server build is required. Clipboard input uses the existing terminal
control connection, without reconnecting or calling a separate paste API.

Claude Code enables bracketed paste in a native terminal. Herdr's reconstructed
ANSI frames do not forward that mode, so the embedded terminal otherwise sends
clipboard newlines as ordinary input. Codex can recognize some unframed pastes,
which can hide the missing mode.

The app enables bracketed paste on the outer Ghostty surface when the running
server's snapshot reports version 0.9.0 or newer. Ghostty still handles clipboard
reading and sanitization. Its opener, payload and closer callbacks are collected
into one `terminal.input` message, with surrounding keys sent separately in order.
The official server recognizes that complete packet and applies the application's
actual paste mode. A program with bracketed paste disabled receives plain text.

The control connection, terminal surface and agent process stay in place. Older
servers retain their previous mode behavior; they must be upgraded for this fix.
Checking only the CLI version is insufficient when an older server is still running.

Herdr limits input messages to 1 MiB, including the 12 paste delimiter bytes.
An oversized paste is rejected before transmission. Subsequent input is stopped
until the user dismisses the error, so an Enter intended for the rejected paste
cannot submit an earlier draft. Dismissing the error resumes the same connection.

## Files and clipboard images

Command-V and Edit → Paste accept copied Finder files, clipboard screenshots,
and raw image/movie representations. Screenshots without a file path are saved
in a private temporary directory; TIFF clipboard images are converted to PNG.
Copied files retain their original bytes and names. SSH panes upload through
the same separate transfer channel as file drops before receiving any paths.

Each copied file is sent as its own bracketed paste. Codex and Claude Code
recognize supported image paths and render their own image attachment labels.
Combining multiple paths in one event would leave them as plain prompt text.
Videos and other files are passed through for the receiving harness to handle;
the terminal does not add model support or fabricate attachment labels.
This requires the 0.9+ server paste framing described above.

Failed/cancelled uploads remove staged clipboard files. Accepted local staging
remains in the OS temporary directory so an unsubmitted draft can still read it;
accepted remote uploads retain their remote copies. Clipboard contents are not
modified, and programmatic clipboard reads do not stage or upload files.

## Verification

```sh
HERDR_BIN=/path/to/official/herdr bash scripts/test-terminal-paste.sh
HERDR_TEST_PASTE_AGENTS=1 HERDR_BIN=/path/to/official/herdr bash scripts/test-terminal-paste.sh
HERDR_TEST_PASTE_AGENTS=1 HERDR_TEST_PASTE_FILES=1 HERDR_BIN=/path/to/official/herdr bash scripts/test-terminal-paste.sh
```

The runner creates and removes a disposable server. It checks native Ghostty
clipboard input, raw PTY bytes with paste mode enabled and disabled, consecutive
pastes, a preceding key, immediate Enter, and unchanged control connection identity.
The optional agent check launches actual Claude Code and Codex CLIs in temporary
folders and exports their full drafts using Ctrl-G. The temporary editor clears
the draft on return; no prompt is submitted. Clipboard contents are restored.
`HERDR_TEST_PASTE_FILES=1` additionally requires each CLI to display attachments
for two copied image files and a raw screenshot, without submitting the draft.
`HERDR_TEST_CLIPBOARD_FILES=1 HERDR_BIN=/path/to/official/herdr bash scripts/test-agent-file-drops.sh`
checks copied images and screenshots in both local and real localhost SSH panes,
including uploaded byte equality. This mode does not submit prompts.

To test a private example locally, also set
`HERDR_TEST_PASTE_TEXT_FILE=/absolute/path/to/example.txt`. The example is not
added to the repository. Without it, the agent check uses 41,530 UTF-8 bytes of
numbered Unicode text, including explicit final two lines.

The native packet checks cover payload/closer fragmentation, arbitrary raw bytes,
immediate Escape, input limits and discarding unfinished paste on reconnect.

Upstream references: [0.9.0 release](https://github.com/herdrdev/herdr/releases/tag/v0.9.0),
[direct terminal input](https://github.com/herdrdev/herdr/blob/v0.9.0/src/server/pane_input.rs),
[paste encoding](https://github.com/herdrdev/herdr/blob/v0.9.0/src/pane.rs).

## Upgrade compatibility

Verified with the official macOS arm64 0.9.0 binary, Claude Code 2.1.272 and
Codex CLI 0.154.0. Both agents preserved the 41,530-byte generated example and
a private 1,212-byte reproduction exactly. Native PTY tests also verified paste
mode on/off, input ordering, size-error recovery and unchanged control connection.

Stock 0.9.0 omits mouse modes and application clipboard events from its JSON
terminal stream. For protocol 22, uherdr uses the stock binary terminal protocol
and a focused client-shell connection to carry these events without server patches.
Application-owned selection can write the macOS clipboard; Shift-drag retains
native local selection and automatic copying. Other protocol versions retain
the CLI transport and native local copy-on-selection. Herdr routes clipboard
writes from all panes to its foreground client and does not identify the source
pane; uherdr accepts those writes only while that native terminal retains keyboard focus. The connection opens when
an application captures the mouse and stays until focus leaves, allowing a final
copy to arrive after the application disables mouse reporting.
The required client-shell connection also participates in stock Herdr's layout:
when it is the sole shell client, tabs without a directly attached native terminal
can be resized to its viewport. Directly attached panes keep their own dimensions.
Protocol 22 offers no independent clipboard-only subscription.
This paste change does not automatically install or replace a running server.

A disposable 0.8.2-to-0.9.0 live handoff preserved the shell PID. A one-time
runtime upgrade is separate from paste handling; pasting never performs a handoff.
The retained-tab performance fixture now resizes relative to its restored window
size, avoiding a no-op resize when macOS restores the previous test dimensions.
The live performance checks pass against both 0.8.2 and official 0.9.0.

## Rendering after resize and tab switches

The replay surface disables autowrap because server frames position cells
explicitly. A separate race can still leave stale cells: pinned Ghostty calls
the host resize callback before resizing its terminal grid, so a fast server
frame can be parsed at the old dimensions. Later partial frames then assume a
screen that the native terminal never received intact.

After 150 ms without another resize, the controller repeats the latest
`terminal.resize` request. Herdr sends a full repaint for an identical-size
request without resizing the PTY or delivering another SIGWINCH. Initial
readiness and revealing a retained pane also schedule recovery. Hiding or
stopping the pane cancels pending work, and ordinary output does not schedule
additional repaints. This uses the existing control connection.

The delay allows native resizing to settle; it is not a native completion
barrier. An unusually long native stall could outlast it. The current native
API reports requested dimensions and exposes no resize-completion barrier.

`bash scripts/test-performance.sh` includes a native regression that holds the
Ghostty resize callback long enough for a new-size frame to arrive first. Before
recovery, the bottom eight rows remain blank; afterward all rows match without
scrolling. It also checks coalescing, visibility and teardown cancellation.
`HERDR_BIN=/path/to/herdr bash scripts/test.sh` adds live retained-tab checks,
including restoring deliberately stale native cells when a pane is revealed.
