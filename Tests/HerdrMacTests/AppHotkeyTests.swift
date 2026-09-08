import Foundation

@main
struct AppHotkeyTests {
    static func main() {
        precondition(
            AppHotkeys.action(for: "r", modifiers: .command) == .renameCurrentTab,
            "Command-R should rename the current tab"
        )
        precondition(
            AppHotkeys.action(for: "r", modifiers: [.command, .shift]) == .renameCurrentWorkspace,
            "Command-Shift-R should rename the current workspace"
        )
        precondition(
            AppHotkeys.action(for: "\r", modifiers: .command) == .togglePaneZoom,
            "Command-Return should toggle the focused pane's zoom"
        )
        precondition(
            AppHotkeys.action(for: "r", modifiers: []) == nil,
            "Unmodified R must not trigger an app action"
        )
        precondition(
            AppHotkeys.action(for: "\r", modifiers: [.command, .shift]) == nil,
            "Command-Shift-Return must not toggle pane zoom"
        )
        print("PASS: app hotkeys route Command-R, Command-Shift-R, and Command-Return")
    }
}
