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
        print("PASS: tab shortcuts map 1–9 then 0")
    }
}
