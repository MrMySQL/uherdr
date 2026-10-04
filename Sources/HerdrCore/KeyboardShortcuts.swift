import Foundation

/// A key with its modifiers, as the app's menus and the terminal use it.
public struct KeyChord: Codable, Hashable, Sendable {
    public struct Modifiers: OptionSet, Codable, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let control = Modifiers(rawValue: 1 << 0)
        public static let option = Modifiers(rawValue: 1 << 1)
        public static let shift = Modifiers(rawValue: 1 << 2)
        public static let command = Modifiers(rawValue: 1 << 3)
    }

    /// One lowercase character, or a named key: "return" or "tab".
    public var key: String
    public var modifiers: Modifiers

    public init(_ key: String, _ modifiers: Modifiers) {
        self.key = key
        self.modifiers = modifiers
    }

    /// macOS order: ⌃⌥⇧⌘, then the key.
    public var display: String { Self.modifierGlyphs(modifiers) + Self.keyGlyph(key) }

    public static func modifierGlyphs(_ modifiers: Modifiers) -> String {
        (modifiers.contains(.control) ? "⌃" : "") + (modifiers.contains(.option) ? "⌥" : "")
            + (modifiers.contains(.shift) ? "⇧" : "") + (modifiers.contains(.command) ? "⌘" : "")
    }

    public static func keyGlyph(_ key: String) -> String {
        switch key {
        case "return": return "↩"
        case "tab": return "Tab"
        default: return key.uppercased()
        }
    }
}

/// The digits a range action uses; only its modifiers can change.
public enum ShortcutRange: Sendable {
    case oneToNine
    case oneToNineAndZero

    public var keys: [String] {
        switch self {
        case .oneToNine: return (1...9).map(String.init)
        case .oneToNineAndZero: return (1...9).map(String.init) + ["0"]
        }
    }
}

public enum ShortcutAction: String, CaseIterable, Codable, Sendable {
    case newSpace, selectSpace, renameSpace
    case newTab, renameTab, selectTab, nextTab, previousTab, nextTabAlternate, previousTabAlternate, closeTab
    case splitSideBySide, splitTopAndBottom, zoomPane, nextPane, previousPane, nextPaneAlternate, findInPane, closePane
    case showAgents, showSpaces
    case copy, paste, largerText, largerTextAlternate, smallerText, newLine
    case settings, keyboardShortcuts

    public var defaultChord: KeyChord {
        switch self {
        case .newSpace: return KeyChord("n", .command)
        case .selectSpace: return KeyChord("1", .command)
        case .renameSpace: return KeyChord("r", [.command, .shift])
        case .newTab: return KeyChord("t", .command)
        case .renameTab: return KeyChord("r", .command)
        case .selectTab: return KeyChord("1", .control)
        case .nextTab: return KeyChord("tab", .control)
        case .previousTab: return KeyChord("tab", [.control, .shift])
        case .nextTabAlternate: return KeyChord("]", [.command, .shift])
        case .previousTabAlternate: return KeyChord("[", [.command, .shift])
        case .closeTab: return KeyChord("w", .command)
        case .splitSideBySide: return KeyChord("d", .command)
        case .splitTopAndBottom: return KeyChord("d", [.command, .shift])
        case .zoomPane: return KeyChord("return", .command)
        case .nextPane: return KeyChord("]", .command)
        case .previousPane: return KeyChord("[", .command)
        case .nextPaneAlternate: return KeyChord("`", .control)
        case .findInPane: return KeyChord("f", .command)
        case .closePane: return KeyChord("w", [.command, .shift])
        case .showAgents: return KeyChord("a", [.command, .shift])
        case .showSpaces: return KeyChord("s", [.command, .shift])
        case .copy: return KeyChord("c", .command)
        case .paste: return KeyChord("v", .command)
        case .largerText: return KeyChord("+", .command)
        case .largerTextAlternate: return KeyChord("=", .command)
        case .smallerText: return KeyChord("-", .command)
        case .newLine: return KeyChord("return", .shift)
        case .settings: return KeyChord(",", .command)
        case .keyboardShortcuts: return KeyChord("/", .command)
        }
    }

    /// The action on its own, for messages ("already used by …").
    public var title: String {
        switch self {
        case .newSpace: return "New space"
        case .selectSpace: return "Select space 1–9"
        case .renameSpace: return "Rename current space"
        case .newTab: return "New tab"
        case .renameTab: return "Rename current tab"
        case .selectTab: return "Select tab 1–9, tab 10"
        case .nextTab, .nextTabAlternate: return "Next tab"
        case .previousTab, .previousTabAlternate: return "Previous tab"
        case .closeTab: return "Close tab"
        case .splitSideBySide: return "Split side by side"
        case .splitTopAndBottom: return "Split top and bottom"
        case .zoomPane: return "Zoom pane"
        case .nextPane, .nextPaneAlternate: return "Next pane"
        case .previousPane: return "Previous pane"
        case .findInPane: return "Find in pane"
        case .closePane: return "Close pane"
        case .showAgents: return "Show agents"
        case .showSpaces: return "Show spaces"
        case .copy: return "Copy"
        case .paste: return "Paste"
        case .largerText, .largerTextAlternate: return "Larger text"
        case .smallerText: return "Smaller text"
        case .newLine: return "New line"
        case .settings: return "Settings"
        case .keyboardShortcuts: return "Keyboard shortcuts"
        }
    }

    /// Range actions keep their digits; their chord's key is ignored.
    public var range: ShortcutRange? {
        switch self {
        case .selectSpace: return .oneToNine
        case .selectTab: return .oneToNineAndZero
        default: return nil
        }
    }

    /// Handled by the terminal (Ghostty key bindings), not by app menus.
    public var isTerminalBinding: Bool { self == .copy || self == .paste || self == .newLine }

    /// Every concrete chord this action answers to with these modifiers and key.
    public func chords(for chord: KeyChord) -> [KeyChord] {
        guard let range else { return [chord] }
        return range.keys.map { KeyChord($0, chord.modifiers) }
    }

    /// Keycaps as the sheet shows them, e.g. ["⌘1–⌘9"] or ["⌃1–⌃9", "⌃0"].
    public func keycaps(for chord: KeyChord) -> [String] {
        let mods = KeyChord.modifierGlyphs(chord.modifiers)
        switch range {
        case .oneToNine: return ["\(mods)1–\(mods)9"]
        case .oneToNineAndZero: return ["\(mods)1–\(mods)9", "\(mods)0"]
        case nil: return [chord.display]
        }
    }
}

/// A row of the Keyboard Shortcuts sheet; pair rows hold two actions.
public struct ShortcutRow: Identifiable, Sendable {
    public let title: String
    public let actions: [ShortcutAction]
    public var id: String { actions.map(\.rawValue).joined(separator: "+") }
}

public struct ShortcutGroup: Identifiable, Sendable {
    public let title: String
    public let rows: [ShortcutRow]
    public var id: String { title }

    public static let all: [ShortcutGroup] = [
        ShortcutGroup(title: "Spaces", rows: [
            ShortcutRow(title: "New space", actions: [.newSpace]),
            ShortcutRow(title: "Select space 1–9 (sidebar order)", actions: [.selectSpace]),
            ShortcutRow(title: "Rename current space", actions: [.renameSpace]),
        ]),
        ShortcutGroup(title: "Tabs", rows: [
            ShortcutRow(title: "New tab", actions: [.newTab]),
            ShortcutRow(title: "Rename current tab", actions: [.renameTab]),
            ShortcutRow(title: "Select tab 1–9, tab 10", actions: [.selectTab]),
            ShortcutRow(title: "Next / previous tab", actions: [.nextTab, .previousTab]),
            ShortcutRow(title: "Next / previous tab", actions: [.nextTabAlternate, .previousTabAlternate]),
            ShortcutRow(title: "Close tab", actions: [.closeTab]),
        ]),
        ShortcutGroup(title: "Panes", rows: [
            ShortcutRow(title: "Split side by side", actions: [.splitSideBySide]),
            ShortcutRow(title: "Split top and bottom", actions: [.splitTopAndBottom]),
            ShortcutRow(title: "Zoom pane", actions: [.zoomPane]),
            ShortcutRow(title: "Next / previous pane", actions: [.nextPane, .previousPane]),
            ShortcutRow(title: "Next pane", actions: [.nextPaneAlternate]),
            ShortcutRow(title: "Find in pane", actions: [.findInPane]),
            ShortcutRow(title: "Close pane", actions: [.closePane]),
        ]),
        ShortcutGroup(title: "Sidebar", rows: [
            ShortcutRow(title: "Show agents", actions: [.showAgents]),
            ShortcutRow(title: "Show spaces", actions: [.showSpaces]),
        ]),
        ShortcutGroup(title: "Terminal", rows: [
            ShortcutRow(title: "Copy", actions: [.copy]),
            ShortcutRow(title: "Paste", actions: [.paste]),
            ShortcutRow(title: "Larger text", actions: [.largerText, .largerTextAlternate]),
            ShortcutRow(title: "Smaller text", actions: [.smallerText]),
            ShortcutRow(title: "New line in Claude Code and Codex", actions: [.newLine]),
        ]),
        ShortcutGroup(title: "App", rows: [
            ShortcutRow(title: "Settings", actions: [.settings]),
            ShortcutRow(title: "Keyboard shortcuts", actions: [.keyboardShortcuts]),
        ]),
    ]

    /// Groups with only the rows whose title or keys match `query`.
    public static func filtered(_ query: String, chord: (ShortcutAction) -> KeyChord?) -> [ShortcutGroup] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return all }
        return all.compactMap { group in
            let rows = group.rows.filter { row in
                row.title.localizedCaseInsensitiveContains(needle)
                    || group.title.localizedCaseInsensitiveContains(needle)
                    || row.actions.contains { action in
                        chord(action).map { action.keycaps(for: $0).joined(separator: " ").localizedCaseInsensitiveContains(needle) } ?? false
                    }
            }
            return rows.isEmpty ? nil : ShortcutGroup(title: group.title, rows: rows)
        }
    }
}

/// The user's shortcuts: defaults plus their changes. A change may also
/// leave an action with no shortcut (after another action took its keys).
public struct ShortcutBindings: Codable, Equatable, Sendable {
    public static let preferencesKey = "keyboardShortcuts.v1"

    /// Present keys are changes; a nil value means "no shortcut".
    private var overrides: [String: KeyChord?] = [:]

    public init() {}

    public func chord(for action: ShortcutAction) -> KeyChord? {
        if let change = overrides[action.rawValue] { return change }
        return action.defaultChord
    }

    public func isChanged(_ action: ShortcutAction) -> Bool { overrides[action.rawValue] != nil }
    public var changedCount: Int { overrides.count }

    /// A chord needs ⌘, ⌃ or ⌥ to stay out of typed text; ⇧ alone is
    /// accepted only with Return or Tab (like ⇧↩ for a new line).
    public static func isValid(_ chord: KeyChord) -> Bool {
        if !chord.modifiers.isDisjoint(with: [.command, .control, .option]) { return true }
        return chord.modifiers == .shift && (chord.key == "return" || chord.key == "tab")
    }

    /// ⌃ with a letter (⌃C, ⌃D, ⌃R…) means something to terminal programs;
    /// ⌘ shortcuts never reach the terminal.
    public static func isTerminalReserved(_ chord: KeyChord, for action: ShortcutAction) -> Bool {
        action.chords(for: chord).contains { candidate in
            candidate.modifiers.contains(.control) && !candidate.modifiers.contains(.command)
                && candidate.key.count == 1 && candidate.key.first!.isASCII && candidate.key.first!.isLetter
        }
    }

    /// The other action already answering to any key this chord would give `action`.
    public func clash(for chord: KeyChord, assigningTo action: ShortcutAction) -> ShortcutAction? {
        let wanted = Set(action.chords(for: chord))
        return ShortcutAction.allCases.first { other in
            guard other != action, let existing = self.chord(for: other) else { return false }
            return !wanted.isDisjoint(with: other.chords(for: existing))
        }
    }

    /// Gives `action` this chord; any action holding the same keys is left
    /// without a shortcut (shown as changed, so Reset brings it back).
    /// Assigning the default chord removes the change; Reset is exactly that.
    public mutating func assign(_ chord: KeyChord, to action: ShortcutAction) {
        var chord = chord
        if let range = action.range { chord.key = range.keys[0] }
        while let other = clash(for: chord, assigningTo: action) {
            overrides[other.rawValue] = .some(nil)
        }
        overrides[action.rawValue] = chord == action.defaultChord ? nil : .some(chord)
    }

    public mutating func resetAll() { overrides = [:] }

    /// Ghostty key bindings for the terminal's own shortcuts.
    public var ghosttyKeybinds: [String] {
        var binds = ["super+a=select_all"]
        if let copy = chord(for: .copy) { binds.append(Self.ghostty(copy) + "=copy_to_clipboard") }
        if let paste = chord(for: .paste) { binds.append(Self.ghostty(paste) + "=paste_from_clipboard") }
        if let newLine = chord(for: .newLine) {
            // Claude Code and Codex read CSI 13;2u as a new line, whatever key sends it.
            binds.append(Self.ghostty(newLine) + "=text:\\x1b[13;2u")
            if newLine.key == "return" { binds.append(Self.ghostty(newLine, key: "numpad_enter") + "=text:\\x1b[13;2u") }
        }
        return binds
    }

    static func ghostty(_ chord: KeyChord, key: String? = nil) -> String {
        var parts: [String] = []
        if chord.modifiers.contains(.control) { parts.append("ctrl") }
        if chord.modifiers.contains(.option) { parts.append("alt") }
        if chord.modifiers.contains(.shift) { parts.append("shift") }
        if chord.modifiers.contains(.command) { parts.append("super") }
        parts.append(key ?? (chord.key == "return" ? "enter" : chord.key))
        return parts.joined(separator: "+")
    }

    public static func load(from defaults: UserDefaults) -> ShortcutBindings {
        guard let data = defaults.data(forKey: preferencesKey),
              let bindings = try? JSONDecoder().decode(ShortcutBindings.self, from: data) else { return ShortcutBindings() }
        return bindings
    }

    public func save(to defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.preferencesKey) }
    }
}

/// What changing a shortcut needs next: each question is asked once, clash first.
public enum ShortcutChangeStep: Equatable, Sendable {
    case invalid
    case clash(ShortcutAction)
    case terminalReserved
    case apply

    public static func next(for chord: KeyChord, action: ShortcutAction, in bindings: ShortcutBindings,
                            clashAccepted: Bool = false, terminalAccepted: Bool = false) -> ShortcutChangeStep {
        // Range actions only take modifiers; any digit stands in for the key.
        var candidate = chord
        if let range = action.range { candidate.key = range.keys[0] }
        guard ShortcutBindings.isValid(candidate) else { return .invalid }
        if !clashAccepted, let other = bindings.clash(for: candidate, assigningTo: action) { return .clash(other) }
        if !terminalAccepted, ShortcutBindings.isTerminalReserved(candidate, for: action) { return .terminalReserved }
        return .apply
    }
}
