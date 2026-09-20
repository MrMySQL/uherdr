struct AppHotkeyModifiers: OptionSet, Hashable {
    let rawValue: Int

    static let command = AppHotkeyModifiers(rawValue: 1 << 0)
    static let shift = AppHotkeyModifiers(rawValue: 1 << 1)
}

struct AppHotkey: Hashable {
    let key: Character
    let modifiers: AppHotkeyModifiers
}

enum AppHotkeyAction: Equatable {
    case renameCurrentTab
    case renameCurrentWorkspace
    case togglePaneZoom
}

enum AppHotkeys {
    static func tabSelectionKey(at index: Int) -> Character? {
        guard (0..<10).contains(index) else { return nil }
        return Character(String((index + 1) % 10))
    }

    static let renameCurrentTab = AppHotkey(key: "r", modifiers: .command)
    static let renameCurrentWorkspace = AppHotkey(key: "r", modifiers: [.command, .shift])
    static let togglePaneZoom = AppHotkey(key: "\r", modifiers: .command)

    private static let bindings: [AppHotkey: AppHotkeyAction] = [
        renameCurrentTab: .renameCurrentTab,
        renameCurrentWorkspace: .renameCurrentWorkspace,
        togglePaneZoom: .togglePaneZoom,
    ]

    static func action(for key: Character, modifiers: AppHotkeyModifiers) -> AppHotkeyAction? {
        bindings[AppHotkey(key: key, modifiers: modifiers)]
    }
}
