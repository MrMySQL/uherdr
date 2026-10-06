import SwiftUI
import AppKit
import HerdrCore

extension KeyChord {
    var keyEquivalent: KeyEquivalent {
        switch key {
        case "return": return .return
        case "tab": return .tab
        case "escape": return .escape
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

extension KeyChord {
    /// The chord a key press makes, read from the unshifted key so ⇧⌘]
    /// is "]" with ⇧ (as menus store it), not "}". Space has no keycap glyph
    /// or Ghostty key name here, so it is not taken.
    init?(event: NSEvent) {
        var modifiers: Modifiers = []
        if event.modifierFlags.contains(.command) { modifiers.insert(.command) }
        if event.modifierFlags.contains(.control) { modifiers.insert(.control) }
        if event.modifierFlags.contains(.option) { modifiers.insert(.option) }
        if event.modifierFlags.contains(.shift) { modifiers.insert(.shift) }
        switch event.keyCode {
        case 36, 76: self.init("return", modifiers)
        case 48: self.init("tab", modifiers)
        default:
            guard let base = event.characters(byApplyingModifiers: [])?.lowercased(), base.count == 1,
                  let scalar = base.unicodeScalars.first, scalar.value > 0x20, scalar.value < 0x7f else { return nil }
            self.init(base, modifiers)
        }
    }
}
