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
    case togglePaneZoom
}

enum AppHotkeys {
    static let renameCurrentTab = AppHotkey(key: "r", modifiers: [.command, .shift])
    static let togglePaneZoom = AppHotkey(key: "\r", modifiers: .command)

    private static let bindings: [AppHotkey: AppHotkeyAction] = [
        renameCurrentTab: .renameCurrentTab,
        togglePaneZoom: .togglePaneZoom,
    ]

    static func action(for key: Character, modifiers: AppHotkeyModifiers) -> AppHotkeyAction? {
        bindings[AppHotkey(key: key, modifiers: modifiers)]
    }
}
