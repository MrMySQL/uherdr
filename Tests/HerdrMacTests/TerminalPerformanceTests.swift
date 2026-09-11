import AppKit
import Combine
import SwiftUI
import QuartzCore
import GhosttyTerminal
import HerdrCore
@testable import HerdrMac

@main struct TerminalPerformanceTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        setbuf(stdout, nil)
        Task { @MainActor in
            do {
                let args = CommandLine.arguments.dropFirst().filter { $0 != "--retention-only" }
                if !CommandLine.arguments.contains("--retention-only") { try await publications() }
                if args.count == 2 {
                    try await retention(socket: args[0], executable: args[1])
                }
                print("PASS: terminal performance regressions")
                exit(0)
            } catch {
                print("FAIL: \(error)")
                exit(1)
            }
        }
        NSApp.run()
    }

    @MainActor static func publications() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("herdr-frame-fixture-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let script = folder.appendingPathComponent("frames")
        try """
        #!/bin/sh
        printf '%s\\n' '{"type":"terminal.frame","bytes":"YQ=="}'
        count=0
        while IFS= read -r line; do
            count=$((count + 1))
            if [ "$count" -eq 6 ]; then
                printf '%s\\n' '{"type":"terminal.closed","reason":"fixture closed"}'
                exit 0
            fi
            printf '%s\\n' '{"type":"terminal.frame","bytes":"Yg=="}'
        done
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let controller = HerdrMac.TerminalController()
        defer { controller.stop() }
        var bytes = Data()
        controller.receive = { bytes.append($0) }
        controller.start(executable: script.path, socket: "/tmp/unused-frame-fixture.sock", pane: "fixture", cols: 80, rows: 24)
        try await wait("initial ready frame") { controller.ready && bytes == Data("a".utf8) }
        var readinessChanges: [Bool] = []
        let observation = controller.$ready.dropFirst().sink { readinessChanges.append($0) }
        defer { observation.cancel() }
        for i in 1...5 {
            controller.send(Data("input".utf8))
            try await wait("frame \(i)") { bytes.count == i + 1 }
        }
        guard readinessChanges.isEmpty else {
            throw HerdrError.message("Steady terminal frames republished readiness \(readinessChanges.count) times")
        }
        controller.send(Data("close".utf8))
        try await wait("closed transition") { !controller.ready && controller.error == "fixture closed" }
        try await Task.sleep(for: .milliseconds(200))
        guard readinessChanges == [false], bytes == Data("abbbbb".utf8) else {
            throw HerdrError.message("Readiness deduplication lost bytes or a real close transition")
        }
        print("PASS: steady output does not publish readiness; bytes and close transition preserved")
    }

    @MainActor static func retention(socket: String, executable: String) async throws {
        guard socket.hasPrefix("/tmp/"), socket.contains("native-client-test") else {
            throw HerdrError.message("Requires a disposable native-client-test socket")
        }
        let client = HerdrClient(socketPath: socket)
        let suite = "dev.herdr.retention-tests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let devices = DeviceStore(defaults: defaults, profiles: [DeviceProfile(name: "Retention fixture", kind: .local, socketPath: socket, executable: executable)])
        let store = devices.activeSession
        let created = try await client.request("workspace.create", params: ["label": .string("Retention fixture"), "cwd": .string("/tmp"), "focus": .bool(true)])
        let space = try created["workspace"].decode(Workspace.self)
        let firstPane = try created["root_pane"].decode(Pane.self)
        let secondPane = try await client.request("pane.split", params: ["target_pane_id": .string(firstPane.id), "direction": .string("right"), "focus": .bool(false)])["pane"].decode(Pane.self)
        let other = try await client.request("tab.create", params: ["workspace_id": .string(space.id), "label": .string("Other"), "focus": .bool(false)])
        let otherPane = try other["root_pane"].decode(Pane.self)
        await store.refresh()
        store.selectSpace(space)
        let host = NSHostingView(rootView: AnyView(WorkspaceView(store: store, devices: devices)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = host
        window.orderBack(nil)
        defer { host.rootView = AnyView(EmptyView()); window.orderOut(nil); devices.stop() }
        var views: [String: HerdrTerminalView] = [:]
        for pane in [firstPane, secondPane, otherPane] {
            let tab = store.tabs.first { $0.id == pane.tabID }!
            store.selectTab(tab)
            let marker = "retention-\(pane.id)-END"
            _ = try await client.request("pane.send_input", params: ["pane_id": .string(pane.id), "text": .string("printf '\(marker)\\n'"), "keys": .array([.string("enter")])])
            try await wait("mount \(pane.id)") {
                if let view = terminals(host).first(where: { viewport($0).contains(marker) }) {
                    views[pane.id] = view; return true
                }
                return false
            }
        }
        try await wait("other tab focus") { window.firstResponder === views[otherPane.id] }
        let originalIDs = Set(views.values.map(ObjectIdentifier.init))
        let hidden = views[firstPane.id]!
        let oldSize = hidden.bounds.size
        let oldConfig = hidden.controller!.renderedConfig
        window.setContentSize(NSSize(width: 1400, height: 900))
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        guard hidden.bounds.size == oldSize else {
            throw HerdrError.message("Resizing the active tab also laid out a hidden terminal: \(oldSize) -> \(hidden.bounds.size)")
        }
        store.fontSize += 2
        store.appearance = "dark"
        _ = try await client.request("pane.rename", params: ["pane_id": .string(firstPane.id), "label": .string("Renamed hidden pane")])
        await store.refresh()
        try await Task.sleep(for: .milliseconds(100))
        guard hidden.controller!.renderedConfig == oldConfig else {
            throw HerdrError.message("Hidden tab eagerly applied an appearance update")
        }
        _ = try await client.request("pane.send_input", params: ["pane_id": .string(firstPane.id), "text": .string("printf 'hidden-output-kept-END\\n'"), "keys": .array([.string("enter")])])
        try await wait("hidden terminal still receives output") { viewport(hidden).contains("hidden-output-kept-END") }
        guard let deck = descendants(host).compactMap({ $0 as? TerminalTabDeckView }).first else {
            throw HerdrError.message("Missing terminal deck")
        }
        store.selectTab(store.tabs.first { $0.id == firstPane.tabID }!)
        deck.update(store: store, colorScheme: .dark, displayScale: window.backingScaleFactor)
        guard !hidden.isHiddenOrHasHiddenAncestor,
              hidden.controller!.renderedConfig != oldConfig,
              hidden.accessibilityLabel()?.contains("Renamed hidden pane") == true else {
            throw HerdrError.message("Tab revealed before its pending presentation changes were applied")
        }
        try await wait("reveal and catch up") {
            window.firstResponder === hidden && hidden.bounds.size != oldSize
                && hidden.controller!.renderedConfig != oldConfig
                && hidden.accessibilityLabel()?.contains("Renamed hidden pane") == true
                && hidden.appearance?.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        }
        guard Set(terminals(host).map(ObjectIdentifier.init)) == originalIDs else {
            throw HerdrError.message("Switching recreated terminals")
        }
        // Exercise coalesced SwiftUI updates: the outgoing hidden snapshot
        // may never be rendered before this tab is selected again.
        store.selectedTab = otherPane.tabID
        store.selectedPane = otherPane.id
        deck.update(store: store, colorScheme: .dark, displayScale: window.backingScaleFactor)
        store.selectedTab = firstPane.tabID
        store.selectedPane = firstPane.id
        deck.update(store: store, colorScheme: .dark, displayScale: window.backingScaleFactor)
        try await wait("rapid tab round-trip restores focus") {
            window.firstResponder === hidden && hidden.acceptsFirstResponder
        }
        guard views[otherPane.id]?.acceptsFirstResponder == false else {
            throw HerdrError.message("Rapid switching left a hidden terminal accepting input")
        }
        store.zoom(firstPane.id)
        try await wait("zoom") { store.currentLayout?.zoomed == true && terminals(host).filter(\.acceptsFirstResponder).count == 1 }
        store.zoom(firstPane.id)
        try await wait("unzoom") { store.currentLayout?.zoomed == false && terminals(host).filter(\.acceptsFirstResponder).count == 2 }
        guard Set(terminals(host).map(ObjectIdentifier.init)) == originalIDs else {
            throw HerdrError.message("Zooming recreated terminals")
        }
        _ = try await client.request("tab.close", params: ["tab_id": .string(otherPane.tabID)])
        await store.refresh()
        try await wait("closed hidden tab releases its renderer") { views[otherPane.id]?.controller == nil }
        _ = try await client.request("workspace.close", params: ["workspace_id": .string(space.id)])
        await store.refresh()
        try await wait("closed workspace releases all renderers") { views.values.allSatisfy { $0.controller == nil } }
        print("PASS: hidden resize isolation, output, appearance/metadata catch-up, focus, zoom, identity, and cleanup")
    }

    @MainActor static func wait(_ label: String, _ predicate: () -> Bool) async throws {
        let deadline = CACurrentMediaTime() + 15
        while !predicate() {
            guard CACurrentMediaTime() < deadline else { throw HerdrError.message("Timed out: \(label)") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    @MainActor static func descendants(_ root: NSView) -> [NSView] {
        [root] + root.subviews.flatMap(descendants)
    }
    @MainActor static func terminals(_ root: NSView) -> [HerdrTerminalView] {
        if let view = root as? HerdrTerminalView { return [view] }
        return root.subviews.flatMap(terminals)
    }
    @MainActor static func viewport(_ view: HerdrTerminalView) -> String {
        guard case .inMemory(let session) = view.configuration.backend else { return "" }
        return session.readViewportText() ?? ""
    }
}
