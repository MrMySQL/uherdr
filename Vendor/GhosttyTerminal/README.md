# Vendored GhosttyTerminal Swift wrapper

Source: https://github.com/Lakr233/libghostty-spm
Tag: 1.5.20260906
Commit: 733ae3b29d447b6707cbfc00879027a076dfd0eb

Only Sources/GhosttyKit and Sources/GhosttyTerminal are copied. The package
manifest retains the same checksummed XCFramework and pins MSDisplayLink 2.2.0.
The native binary is downloaded by SwiftPM, not committed here.

Local changes: InMemoryTerminalSession.init accepts
suppressesTerminalResponses (default false). When enabled, its existing
serialized output path calls ghostty_surface_write_buffer_replay instead of
ghostty_surface_write_buffer. The pinned native binary already exports this API.
It suppresses protocol replies at their source, including replies that would
otherwise escape through asynchronous mailboxes after receive returns.

GhosttyRuntimeResources also checks the signed macOS app's Contents/Resources
for its resource bundle before using SwiftPM's command-line Bundle.module
accessor. This prevents packaged apps from depending on the build directory.

Herdr owns the authoritative terminal and answers its queries. Its ANSI display
frames must update the embedded renderer without generating duplicate replies
as shell input. A Swift callback gate around receive is insufficient.

Upgrades: compare both source directories against the pinned upstream revision,
retain the small replay option until upstream exposes an equivalent API, and
run scripts/test.sh from the repository root. Terminal tests include actual
Ghostty query suppression followed by keyboard input.

The wrapper retains its MIT license in LICENSE. Ghostty's MIT notice lives in
../../docs/licenses/Ghostty-LICENSE.
