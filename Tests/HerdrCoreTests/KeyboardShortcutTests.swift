import Foundation
import HerdrCore

enum KeyboardShortcutTests {
    static func run() {
        // Every action is in exactly one row of the sheet.
        let listed = ShortcutGroup.all.flatMap(\.rows).flatMap(\.actions)
        XCTAssertEqual(listed.count, ShortcutAction.allCases.count)
        XCTAssertEqual(Set(listed), Set(ShortcutAction.allCases))
        XCTAssertEqual(ShortcutGroup.all.map(\.title), ["Spaces", "Tabs", "Panes", "Sidebar", "Terminal", "App"])
        // No two defaults that can fire together share a chord, counting every digit of a range.
        // An open pane search takes keys from the terminal, so only those two may overlap.
        for live in [ShortcutAction.allCases.filter { !$0.isPaneSearchBinding }, ShortcutAction.allCases.filter { !$0.isTerminalBinding }] {
            let chords = live.flatMap { $0.chords(for: $0.defaultChord) }
            XCTAssertEqual(chords.count, Set(chords).count)
        }
        // The defaults are the shortcuts the app had before this table
        // (HerdrApp.swift menus, the Ghostty key bindings and the pane search keys).
        let expected: [ShortcutAction: String] = [
            .newSpace: "⌘N", .renameSpace: "⇧⌘R", .newTab: "⌘T", .renameTab: "⌘R",
            .nextTab: "⌃Tab", .previousTab: "⌃⇧Tab", .nextTabAlternate: "⇧⌘]", .previousTabAlternate: "⇧⌘[",
            .splitSideBySide: "⌘D", .splitTopAndBottom: "⇧⌘D", .zoomPane: "⌘↩", .nextPane: "⌘]", .previousPane: "⌘[",
            .nextPaneAlternate: "⌃`", .findInPane: "⌘F", .closePane: "⇧⌘W", .nextMatch: "↩", .previousMatch: "⇧↩",
            .nextMatchAlternate: "⌘G", .previousMatchAlternate: "⇧⌘G", .closeSearch: "⎋", .showAgents: "⇧⌘A", .showSpaces: "⇧⌘S",
            .copy: "⌘C", .paste: "⌘V", .selectAll: "⌘A", .largerText: "⌘+", .largerTextAlternate: "⌘=", .smallerText: "⌘-",
            .newLine: "⇧↩", .settings: "⌘,", .keyboardShortcuts: "⌘/",
        ]
        XCTAssertEqual(Set(expected.keys), Set(ShortcutAction.allCases.filter { $0.range == nil }))
        for (action, display) in expected { XCTAssertEqual(action.defaultChord.display, display) }
        XCTAssertEqual(ShortcutAction.selectSpace.keycaps(for: ShortcutAction.selectSpace.defaultChord), ["⌘1–⌘9"])
        XCTAssertEqual(ShortcutAction.selectTab.keycaps(for: ShortcutAction.selectTab.defaultChord), ["⌃1–⌃9", "⌃0"])
        XCTAssertEqual(ShortcutAction.selectTab.chords(for: KeyChord("x", .control)).map(\.key), ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"])
        XCTAssertEqual(Set(ShortcutAction.allCases.filter(\.isTerminalBinding)), [.copy, .paste, .selectAll, .newLine])
        XCTAssertEqual(Set(ShortcutAction.allCases.filter(\.isPaneSearchBinding)),
                       [.nextMatch, .previousMatch, .nextMatchAlternate, .previousMatchAlternate, .closeSearch])
        // Search matches titles, group names and keys.
        let defaults: (ShortcutAction) -> KeyChord? = { $0.defaultChord }
        XCTAssertEqual(ShortcutGroup.filtered("zoom", chord: defaults).flatMap(\.rows).map(\.title), ["Zoom pane"])
        XCTAssertEqual(ShortcutGroup.filtered("⇧⌘D", chord: defaults).flatMap(\.rows).map(\.title), ["Split top and bottom"])
        XCTAssertEqual(ShortcutGroup.filtered("sidebar", chord: defaults).flatMap(\.rows).map(\.title),
                       ["Select space 1–9 (sidebar order)", "Show agents", "Show spaces"])
        XCTAssertEqual(ShortcutGroup.filtered("  ", chord: defaults).count, ShortcutGroup.all.count)
        XCTAssertTrue(ShortcutGroup.filtered("no such shortcut", chord: defaults).isEmpty)
        // The sheet splits into two columns, or one when a search leaves a side empty.
        let columns = { (query: String) in ShortcutGroup.columns(ShortcutGroup.filtered(query, chord: defaults)).map { $0.map(\.title) } }
        XCTAssertEqual(columns(""), [["Spaces", "Tabs", "Panes"], ["Sidebar", "Terminal", "App"]])
        XCTAssertEqual(columns("zoom"), [["Panes"]])
        XCTAssertEqual(columns("settings"), [["App"]])
        XCTAssertEqual(columns("no such shortcut"), [])
        print("PASS: shortcut table covers every action once, keeps today's defaults without clashes, searches, and fills one or two columns")
    }
}
