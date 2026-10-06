import Foundation
import HerdrCore

enum KeyboardShortcutTests {
    static func run() {
        // Every action is in exactly one row of the sheet.
        let listed = ShortcutGroup.all.flatMap(\.rows).flatMap(\.actions)
        XCTAssertEqual(listed.count, ShortcutAction.allCases.count)
        XCTAssertEqual(Set(listed), Set(ShortcutAction.allCases))
        XCTAssertEqual(ShortcutGroup.all.map(\.title), ["Spaces", "Tabs", "Panes", "Sidebar", "Terminal", "App"])
        // No two defaults share a chord, counting every digit of a range.
        let chords = ShortcutAction.allCases.flatMap { $0.chords(for: $0.defaultChord) }
        XCTAssertEqual(chords.count, Set(chords).count)
        // The defaults are the shortcuts the app had before this table
        // (HerdrApp.swift menus and the Ghostty key bindings).
        let expected: [ShortcutAction: String] = [
            .newSpace: "⌘N", .renameSpace: "⇧⌘R", .newTab: "⌘T", .renameTab: "⌘R",
            .nextTab: "⌃Tab", .previousTab: "⌃⇧Tab", .nextTabAlternate: "⇧⌘]", .previousTabAlternate: "⇧⌘[",
            .splitSideBySide: "⌘D", .splitTopAndBottom: "⇧⌘D", .zoomPane: "⌘↩", .nextPane: "⌘]", .previousPane: "⌘[",
            .nextPaneAlternate: "⌃`", .findInPane: "⌘F", .closePane: "⇧⌘W", .showAgents: "⇧⌘A", .showSpaces: "⇧⌘S",
            .copy: "⌘C", .paste: "⌘V", .largerText: "⌘+", .largerTextAlternate: "⌘=", .smallerText: "⌘-",
            .newLine: "⇧↩", .settings: "⌘,", .keyboardShortcuts: "⌘/",
        ]
        for (action, display) in expected { XCTAssertEqual(action.defaultChord.display, display) }
        XCTAssertEqual(ShortcutAction.selectSpace.keycaps(for: ShortcutAction.selectSpace.defaultChord), ["⌘1–⌘9"])
        XCTAssertEqual(ShortcutAction.selectTab.keycaps(for: ShortcutAction.selectTab.defaultChord), ["⌃1–⌃9", "⌃0"])
        XCTAssertEqual(ShortcutAction.selectTab.chords(for: KeyChord("x", .control)).map(\.key), ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"])
        XCTAssertEqual(Set(ShortcutAction.allCases.filter(\.isTerminalBinding)), [.copy, .paste, .newLine])
        // Search matches titles, group names and keys.
        let defaults: (ShortcutAction) -> KeyChord? = { $0.defaultChord }
        XCTAssertEqual(ShortcutGroup.filtered("zoom", chord: defaults).flatMap(\.rows).map(\.title), ["Zoom pane"])
        XCTAssertEqual(ShortcutGroup.filtered("⇧⌘D", chord: defaults).flatMap(\.rows).map(\.title), ["Split top and bottom"])
        XCTAssertEqual(ShortcutGroup.filtered("sidebar", chord: defaults).flatMap(\.rows).map(\.title),
                       ["Select space 1–9 (sidebar order)", "Show agents", "Show spaces"])
        XCTAssertEqual(ShortcutGroup.filtered("  ", chord: defaults).count, ShortcutGroup.all.count)
        XCTAssertTrue(ShortcutGroup.filtered("no such shortcut", chord: defaults).isEmpty)
        print("PASS: shortcut table covers every action once, keeps today's defaults without clashes, and searches")
        try! runBindings()
    }

    static func runBindings() throws {
        var bindings = ShortcutBindings()
        XCTAssertEqual(bindings.changedCount, 0)
        XCTAssertEqual(bindings.chord(for: .splitSideBySide), KeyChord("d", .command))
        // 07b: ⌘D for Find in pane clashes with Split side by side; Replace clears Split.
        XCTAssertEqual(bindings.clashes(for: KeyChord("d", .command), assigningTo: .findInPane), [.splitSideBySide])
        bindings.assign(KeyChord("d", .command), to: .findInPane)
        XCTAssertEqual(bindings.chord(for: .findInPane), KeyChord("d", .command))
        XCTAssertTrue(bindings.chord(for: .splitSideBySide) == nil && bindings.isChanged(.splitSideBySide) && bindings.isChanged(.findInPane))
        XCTAssertEqual(bindings.changedCount, 2)
        // Reset of Split is assigning its default, which now clashes with Find.
        XCTAssertEqual(bindings.clashes(for: ShortcutAction.splitSideBySide.defaultChord, assigningTo: .splitSideBySide), [.findInPane])
        // Moving Find elsewhere does not hand Split its keys back on its own.
        bindings.assign(KeyChord("f", [.command, .shift]), to: .findInPane)
        XCTAssertTrue(bindings.chord(for: .splitSideBySide) == nil)
        XCTAssertEqual(bindings.clashes(for: ShortcutAction.splitSideBySide.defaultChord, assigningTo: .splitSideBySide), [])
        bindings.assign(ShortcutAction.splitSideBySide.defaultChord, to: .splitSideBySide)
        XCTAssertTrue(!bindings.isChanged(.splitSideBySide))
        XCTAssertEqual(bindings.changedCount, 1)
        // 07d: a range changes only its modifiers; any of its digits can clash.
        bindings.assign(KeyChord("7", [.command, .control]), to: .selectSpace)
        XCTAssertEqual(bindings.chord(for: .selectSpace), KeyChord("1", [.command, .control]))
        XCTAssertEqual(ShortcutAction.selectSpace.keycaps(for: bindings.chord(for: .selectSpace)!), ["⌃⌘1–⌃⌘9"])
        XCTAssertEqual(bindings.clashes(for: KeyChord("5", [.command, .control]), assigningTo: .newTab), [.selectSpace])
        XCTAssertEqual(bindings.clashes(for: KeyChord("x", .control), assigningTo: .selectSpace), [.selectTab])
        // Assigning the default again removes the change.
        bindings.assign(KeyChord("9", .command), to: .selectSpace)
        XCTAssertTrue(!bindings.isChanged(.selectSpace))
        // 07c: ⌃ with a letter is the terminal's; ⌘, ⌃⌘ and ⌃ with a digit or Tab are not.
        XCTAssertTrue(ShortcutBindings.isTerminalReserved(KeyChord("d", .control), for: .closePane))
        XCTAssertTrue(ShortcutBindings.isTerminalReserved(KeyChord("c", [.control, .shift]), for: .copy))
        XCTAssertTrue(!ShortcutBindings.isTerminalReserved(KeyChord("d", [.control, .command]), for: .closePane))
        XCTAssertTrue(!ShortcutBindings.isTerminalReserved(KeyChord("w", [.command, .shift]), for: .closePane))
        XCTAssertTrue(!ShortcutBindings.isTerminalReserved(KeyChord("x", .control), for: .selectTab))
        XCTAssertTrue(!ShortcutBindings.isTerminalReserved(KeyChord("tab", .control), for: .nextTab))
        // A shortcut needs ⌘, ⌃ or ⌥; ⇧ alone only with Return or Tab.
        XCTAssertTrue(ShortcutBindings.isValid(KeyChord("return", .shift)) && ShortcutBindings.isValid(KeyChord("k", .option)))
        XCTAssertTrue(!ShortcutBindings.isValid(KeyChord("k", .shift)) && !ShortcutBindings.isValid(KeyChord("k", [])))
        // Saved and loaded unchanged, including an action left without a shortcut.
        let suite = "dev.herdr.shortcut-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(ShortcutBindings.load(from: defaults), ShortcutBindings())
        bindings.assign(KeyChord("d", .command), to: .closePane)
        bindings.save(to: defaults)
        let loaded = ShortcutBindings.load(from: defaults)
        XCTAssertEqual(loaded, bindings)
        XCTAssertTrue(loaded.chord(for: .splitSideBySide) == nil && loaded.isChanged(.splitSideBySide))
        bindings.resetAll()
        XCTAssertEqual(bindings, ShortcutBindings())
        // The terminal's own keys become Ghostty bindings.
        XCTAssertEqual(ShortcutBindings().ghosttyKeybinds, ["super+a=select_all", "super+c=copy_to_clipboard", "super+v=paste_from_clipboard",
                                                            "shift+enter=text:\\x1b[13;2u", "shift+numpad_enter=text:\\x1b[13;2u"])
        var terminal = ShortcutBindings()
        terminal.assign(KeyChord("return", .option), to: .newLine)
        terminal.assign(KeyChord("c", [.control, .shift]), to: .copy)
        terminal.assign(KeyChord("v", .command), to: .closePane)
        XCTAssertEqual(terminal.ghosttyKeybinds, ["super+a=select_all", "ctrl+shift+c=copy_to_clipboard",
                                                  "alt+enter=text:\\x1b[13;2u", "alt+numpad_enter=text:\\x1b[13;2u"])
        // ⌘A selects all only while no action has it, or the terminal would take it first.
        terminal.assign(KeyChord("a", .command), to: .showAgents)
        XCTAssertEqual(terminal.ghosttyKeybinds, ["ctrl+shift+c=copy_to_clipboard", "alt+enter=text:\\x1b[13;2u", "alt+numpad_enter=text:\\x1b[13;2u"])
        terminal.assign(KeyChord("a", .command), to: .copy)
        XCTAssertEqual(terminal.ghosttyKeybinds, ["super+a=copy_to_clipboard", "alt+enter=text:\\x1b[13;2u", "alt+numpad_enter=text:\\x1b[13;2u"])
        terminal.assign(KeyChord("c", .command), to: .copy)
        XCTAssertEqual(terminal.ghosttyKeybinds.first, "super+a=select_all")
        // The change flow: invalid keys first, then a clash, then the terminal warning, each once.
        let plain = ShortcutBindings()
        XCTAssertEqual(ShortcutChangeStep.next(for: KeyChord("k", .shift), action: .findInPane, in: plain), .invalid)
        XCTAssertEqual(ShortcutChangeStep.next(for: KeyChord("k", [.command, .shift]), action: .findInPane, in: plain), .apply)
        XCTAssertEqual(ShortcutChangeStep.next(for: KeyChord("d", .command), action: .findInPane, in: plain), .clash([.splitSideBySide]))
        var withCtrlD = ShortcutBindings()
        withCtrlD.assign(KeyChord("d", .control), to: .splitSideBySide)
        XCTAssertEqual(ShortcutChangeStep.next(for: KeyChord("d", .control), action: .closePane, in: withCtrlD), .clash([.splitSideBySide]))
        XCTAssertEqual(ShortcutChangeStep.next(for: KeyChord("d", .control), action: .closePane, in: withCtrlD, clashAccepted: true), .terminalReserved)
        XCTAssertEqual(ShortcutChangeStep.next(for: KeyChord("d", .control), action: .closePane, in: withCtrlD, clashAccepted: true, terminalAccepted: true), .apply)
        // A range takes any digit pressed as its key and is never a terminal key.
        XCTAssertEqual(ShortcutChangeStep.next(for: KeyChord("4", [.command, .control]), action: .selectSpace, in: plain), .apply)
        XCTAssertEqual(ShortcutChangeStep.next(for: KeyChord("4", .control), action: .selectSpace, in: plain), .clash([.selectTab]))
        // A range can take keys from several actions; the question names every one Replace clears.
        var crowded = ShortcutBindings()
        crowded.assign(KeyChord("3", [.command, .control]), to: .newTab)
        crowded.assign(KeyChord("5", [.command, .control]), to: .renameTab)
        XCTAssertEqual(ShortcutChangeStep.next(for: KeyChord("1", [.command, .control]), action: .selectSpace, in: crowded), .clash([.newTab, .renameTab]))
        crowded.assign(KeyChord("1", [.command, .control]), to: .selectSpace)
        XCTAssertTrue(crowded.chord(for: .newTab) == nil && crowded.chord(for: .renameTab) == nil)
        // Resetting a row stops at the first clash and hands back the rest, to finish after Replace.
        var row = ShortcutBindings()
        row.assign(KeyChord("k", .command), to: .nextTab)
        row.assign(KeyChord("j", .command), to: .previousTab)
        row.assign(ShortcutAction.nextTab.defaultChord, to: .newTab)
        let stop = row.reset([.nextTab, .previousTab])
        XCTAssertEqual(stop?.action, .nextTab)
        XCTAssertEqual(stop?.rest, [.previousTab])
        XCTAssertTrue(row.isChanged(.nextTab) && row.isChanged(.previousTab))
        row.assign(ShortcutAction.nextTab.defaultChord, to: .nextTab)
        XCTAssertTrue(row.reset(stop!.rest) == nil)
        XCTAssertTrue(!row.isChanged(.nextTab) && !row.isChanged(.previousTab) && row.chord(for: .newTab) == nil)
        // Actions before the clash are reset at once.
        row.assign(KeyChord("j", .command), to: .previousTab)
        row.assign(ShortcutAction.nextTab.defaultChord, to: .newTab)
        let later = row.reset([.previousTab, .nextTab])
        XCTAssertEqual(later?.action, .nextTab)
        XCTAssertEqual(later?.rest, [])
        XCTAssertTrue(!row.isChanged(.previousTab))
        print("PASS: shortcut changes: replace leaves the other unset, reset, ranges, terminal keys, validity, saving, Ghostty bindings")
    }
}
