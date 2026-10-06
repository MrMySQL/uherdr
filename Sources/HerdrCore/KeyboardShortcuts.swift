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

    /// One lowercase character, or a named key: "return", "tab" or "escape".
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
        case "escape": return "⎋"
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
    case newTab, renameTab, selectTab, nextTab, previousTab, nextTabAlternate, previousTabAlternate
    case splitSideBySide, splitTopAndBottom, zoomPane, nextPane, previousPane, nextPaneAlternate, findInPane, closePane
    case nextMatch, previousMatch, nextMatchAlternate, previousMatchAlternate, closeSearch
    case showAgents, showSpaces
    case copy, paste, selectAll, largerText, largerTextAlternate, smallerText, newLine
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
        case .splitSideBySide: return KeyChord("d", .command)
        case .splitTopAndBottom: return KeyChord("d", [.command, .shift])
        case .zoomPane: return KeyChord("return", .command)
        case .nextPane: return KeyChord("]", .command)
        case .previousPane: return KeyChord("[", .command)
        case .nextPaneAlternate: return KeyChord("`", .control)
        case .findInPane: return KeyChord("f", .command)
        case .closePane: return KeyChord("w", [.command, .shift])
        case .nextMatch: return KeyChord("return", [])
        case .previousMatch: return KeyChord("return", .shift)
        case .nextMatchAlternate: return KeyChord("g", .command)
        case .previousMatchAlternate: return KeyChord("g", [.command, .shift])
        case .closeSearch: return KeyChord("escape", [])
        case .showAgents: return KeyChord("a", [.command, .shift])
        case .showSpaces: return KeyChord("s", [.command, .shift])
        case .copy: return KeyChord("c", .command)
        case .paste: return KeyChord("v", .command)
        case .selectAll: return KeyChord("a", .command)
        case .largerText: return KeyChord("+", .command)
        case .largerTextAlternate: return KeyChord("=", .command)
        case .smallerText: return KeyChord("-", .command)
        case .newLine: return KeyChord("return", .shift)
        case .settings: return KeyChord(",", .command)
        case .keyboardShortcuts: return KeyChord("/", .command)
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
    public var isTerminalBinding: Bool { [.copy, .paste, .selectAll, .newLine].contains(self) }

    /// Handled by an open Find in Pane search, which takes keys from the terminal.
    public var isPaneSearchBinding: Bool {
        [.nextMatch, .previousMatch, .nextMatchAlternate, .previousMatchAlternate, .closeSearch].contains(self)
    }

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
        ]),
        ShortcutGroup(title: "Panes", rows: [
            ShortcutRow(title: "Split side by side", actions: [.splitSideBySide]),
            ShortcutRow(title: "Split top and bottom", actions: [.splitTopAndBottom]),
            ShortcutRow(title: "Zoom pane", actions: [.zoomPane]),
            ShortcutRow(title: "Next / previous pane", actions: [.nextPane, .previousPane]),
            ShortcutRow(title: "Next pane", actions: [.nextPaneAlternate]),
            ShortcutRow(title: "Find in pane", actions: [.findInPane]),
            ShortcutRow(title: "Next / previous match", actions: [.nextMatch, .previousMatch]),
            ShortcutRow(title: "Next / previous match", actions: [.nextMatchAlternate, .previousMatchAlternate]),
            ShortcutRow(title: "Close search", actions: [.closeSearch]),
            ShortcutRow(title: "Close pane", actions: [.closePane]),
        ]),
        ShortcutGroup(title: "Sidebar", rows: [
            ShortcutRow(title: "Show agents", actions: [.showAgents]),
            ShortcutRow(title: "Show spaces", actions: [.showSpaces]),
        ]),
        ShortcutGroup(title: "Terminal", rows: [
            ShortcutRow(title: "Copy", actions: [.copy]),
            ShortcutRow(title: "Paste", actions: [.paste]),
            ShortcutRow(title: "Select all", actions: [.selectAll]),
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

    /// The sheet's columns: Spaces, Tabs and Panes, then the rest. Empty ones are dropped.
    public static func columns(_ groups: [ShortcutGroup]) -> [[ShortcutGroup]] {
        let leading = Set(all.prefix(3).map(\.title))
        return [groups.filter { leading.contains($0.title) }, groups.filter { !leading.contains($0.title) }].filter { !$0.isEmpty }
    }
}
