import SwiftUI
import HerdrCore

extension KeyChord {
    var keyEquivalent: KeyEquivalent {
        switch key {
        case "return": return .return
        case "tab": return .tab
        default: return KeyEquivalent(Character(key))
        }
    }

    var eventModifiers: EventModifiers {
        var result: EventModifiers = []
        if modifiers.contains(.command) { result.insert(.command) }
        if modifiers.contains(.shift) { result.insert(.shift) }
        if modifiers.contains(.control) { result.insert(.control) }
        if modifiers.contains(.option) { result.insert(.option) }
        return result
    }

    var keyboardShortcut: KeyboardShortcut { KeyboardShortcut(keyEquivalent, modifiers: eventModifiers) }

    /// A range action's shortcut for one of its digits.
    func keyboardShortcut(digit: Character) -> KeyboardShortcut { KeyboardShortcut(KeyEquivalent(digit), modifiers: eventModifiers) }
}
