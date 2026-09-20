import Foundation

@main
struct AppHotkeyTests {
    static func main() {
        let tabKeys: [Character] = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"]
        for (index, key) in tabKeys.enumerated() {
            precondition(AppHotkeys.tabSelectionKey(at: index) == key, "Tab shortcuts must follow visible order, with 0 for the tenth tab")
        }
        precondition(AppHotkeys.tabSelectionKey(at: -1) == nil, "Negative tab indices must not have shortcuts")
        precondition(AppHotkeys.tabSelectionKey(at: 10) == nil, "Tabs after the tenth must not reuse a shortcut")
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
        print("PASS: tab shortcuts map 1–9 then 0, and app hotkeys route Command-R, Command-Shift-R, and Command-Return")
    }
}
