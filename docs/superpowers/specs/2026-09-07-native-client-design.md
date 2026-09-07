# Herdr native macOS client

Approved in conversation on 2026-09-07.

Build a macOS 14+ app using SwiftUI for the shell and AppKit for interactive terminal surfaces. Connect to the installed herdr runtime; herdr owns shell processes, agents, and session persistence. The app must not stop the runtime on quit.

The window has a native sidebar with Spaces and Agents views, a tab strip, and a recursively split pane area. Spaces map to herdr workspaces. Each tab contains a tree of panes with horizontal and vertical split controls and draggable dividers. Create, select, rename, and close spaces, tabs, and panes. Closing running resources requires a clear confirmation. Agent status is visible on panes and in the sidebar; selecting an agent reveals its tab and pane. Support starting installed coding agents in available panes.

Use the local Unix socket API for session snapshots and mutations. Refresh authoritative state after commands and reconnect after errors. Verify the installed protocol before choosing the terminal data transport. Display connection errors inline and expose session/socket configuration. Persist connection preferences, appearance, and window geometry. Honor native keyboard shortcuts, copy/paste, dark/light mode, and accessibility labels.

Package as a Swift package with a script producing a runnable ad-hoc-signed .app. Tests cover protocol decoding, nested layout, transport errors, and live operations against an explicitly named disposable test session. Verify the window and terminal interactions on macOS. Document any upstream protocol limits accurately.
