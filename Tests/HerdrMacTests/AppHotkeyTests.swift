import Foundation

@main
struct AppHotkeyTests {
    static func main() {
        precondition(
            AppHotkeys.action(for: "r", modifiers: [.command, .shift]) == .renameCurrentTab,
            "Command-Shift-R should rename the current tab"
        )
        precondition(
            AppHotkeys.action(for: "\r", modifiers: .command) == .togglePaneZoom,
            "Command-Return should toggle the focused pane's zoom"
        )
        precondition(
            AppHotkeys.action(for: "r", modifiers: .command) == nil,
            "Command-R must not rename the current tab"
        )
        precondition(
            AppHotkeys.action(for: "\r", modifiers: [.command, .shift]) == nil,
            "Command-Shift-Return must not toggle pane zoom"
        )
        print("PASS: app hotkeys route Command-Shift-R and Command-Return")
    }
}
