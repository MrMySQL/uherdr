import AppKit
import SwiftUI
import GhosttyTerminal
import HerdrCore
@testable import HerdrMac

@main struct TerminalAppearanceTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        setbuf(stdout, nil)
        Task { @MainActor in
            do {
                try await sidebarEditorControls()
                try await settingsPresetControls()
                try await retainedAppearance(socket: CommandLine.arguments[1], executable: CommandLine.arguments[2])
                print("PASS: mounted terminal appearance regressions")
                exit(0)
            } catch { print("FAIL: \(error)"); exit(1) }
        }
        NSApp.run()
    }

    @MainActor static func sidebarEditorControls() async throws {
        let suite = "dev.herdr.sidebar-mounted.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AppearanceStore(defaults: defaults)
        try store.applyImportedSettings(HerdrAppearanceConfig.parse("""
        [ui.sidebar.spaces]
        rows = [["state_icon", {token="workspace",rules=[{contains="prod",fg="#ff8040",bold=true,hide=false}]}], ["$owner"]]
        """))
        let host = NSHostingView(rootView: SidebarRulesEditor(store: store).padding(24)
            .environment(\.resolvedAppearance, store.resolvedSnapshot)
            .background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(contentRect: NSRect(x: 60, y: 60, width: 900, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Sidebar rules acceptance"
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil); window.contentView = nil }
        for source in [AppearanceThemeSource.herdrConfig, .native] {
            if source == .native { try store.copySidebarToNative() }
            try await Task.sleep(for: .milliseconds(200))
            host.layoutSubtreeIfNeeded()
            let controls = descendants(host).compactMap { $0 as? NSPopUpButton }.filter { $0.itemTitles.contains("Inherit") }
            guard !controls.isEmpty && controls.allSatisfy({ $0.isEnabled == (source == .native) }) else {
                throw HerdrError.message("Sidebar style controls must be read-only until copied to Native")
            }
            if let directory = ProcessInfo.processInfo.environment["HERDR_SETTINGS_CAPTURE_DIR"] {
                let path = URL(fileURLWithPath: directory).appendingPathComponent("sidebar-\(source.rawValue)-native-cache.png").path
                guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw HerdrError.message("Sidebar capture unavailable") }
                host.cacheDisplay(in: host.bounds, to: bitmap)
                guard let data = bitmap.representation(using: .png, properties: [:]) else { throw HerdrError.message("Sidebar PNG unavailable") }
                try data.write(to: URL(fileURLWithPath: path))
                print("CAPTURE: mounted sidebar editor and conditional preview \(path)")
            }
        }
        print("PASS: mounted sidebar editor is read-only for import and editable after full native copy")
    }

    @MainActor static func settingsPresetControls() async throws {
        let suite = "dev.herdr.settings-mounted.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AppearanceStore(defaults: defaults)
        let session = SessionStore(profile: DeviceProfile(name: "Settings fixture", executable: "/unused"), defaults: defaults, appearanceStore: store)
        let host = NSHostingView(rootView: EditorSheet(sheet: .settings, store: session)
            .background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 770),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.orderBack(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        for source in [AppearanceThemeSource.native, .herdrConfig] {
            if source == .herdrConfig {
                try store.applyImportedSettings(try HerdrAppearanceConfig.parse("""
                [theme]
                name = "catppuccin"
                auto_switch = true
                light_name = "catppuccin-latte"
                [ui.sidebar.spaces]
                rows = [[{token="workspace",rules=[{contains="prod",fg="#ff8040",bold=true,hide=false}]}]]
                """))
            }
            try await Task.sleep(for: .milliseconds(150))
            host.layoutSubtreeIfNeeded()
            let pickers = descendants(host).compactMap { $0 as? NSPopUpButton }
                .filter { $0.itemTitles.contains("Nord") }
            guard pickers.count == 3 else {
                throw HerdrError.message("Expected three mounted theme preset controls; found \(pickers.count)")
            }
            guard pickers.allSatisfy(\.isEnabled) else {
                throw HerdrError.message("Native preset controls are disabled for \(source.rawValue)")
            }
            if let directory = ProcessInfo.processInfo.environment["HERDR_SETTINGS_CAPTURE_DIR"],
               let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: bitmap)
                if let data = bitmap.representation(using: .png, properties: [:]) {
                    let url = URL(fileURLWithPath: directory).appendingPathComponent("settings-\(source.rawValue)-native-cache.png")
                    try data.write(to: url)
                    print("CAPTURE: mounted settings view \(url.path)")
                }
            }
        }
        guard let scroll = descendants(host).compactMap({ $0 as? NSScrollView }).max(by: { $0.frame.height < $1.frame.height }),
              let document = scroll.documentView, document.frame.height > scroll.contentSize.height else {
            throw HerdrError.message("Full Settings must scroll to the sidebar editor and preview")
        }
        for position in ["middle", "bottom"] {
            let maximum = document.frame.height - scroll.contentSize.height
            scroll.contentView.scroll(to: NSPoint(x: 0, y: position == "middle" ? maximum / 2 : maximum))
            scroll.reflectScrolledClipView(scroll.contentView)
            try await Task.sleep(for: .milliseconds(150))
            guard scroll.contentView.bounds.origin.y > 0 else { throw HerdrError.message("Settings scrolling did not move") }
            if let directory = ProcessInfo.processInfo.environment["HERDR_SETTINGS_CAPTURE_DIR"],
               let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory + "/settings-" + position + "-native-cache.png"))
            }
        }
        print("PASS: full 480-point Settings scrolls through rules to preview; all three native preset controls remain enabled for Native and Herdr config sources")
    }

    @MainActor static func retainedAppearance(socket: String, executable: String) async throws {
        guard socket.hasPrefix("/tmp/"), socket.contains("native-client-test") else {
            throw HerdrError.message("Requires a disposable native-client-test socket")
        }
        let client = HerdrClient(socketPath: socket)
        let suite = "dev.herdr.appearance-mounted.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let devices = DeviceStore(defaults: defaults, profiles: [DeviceProfile(name: "Appearance fixture", kind: .local, socketPath: socket, executable: executable)])
        let store = devices.activeSession
        store.appearance = "light"
        let created = try await client.request("workspace.create", params: ["label": .string("Appearance fixture"), "cwd": .string("/tmp"), "focus": .bool(true)])
        let space = try created["workspace"].decode(Workspace.self)
        let first = try created["root_pane"].decode(Pane.self)
        let second = try await client.request("tab.create", params: ["workspace_id": .string(space.id), "label": .string("Other"), "focus": .bool(false)])["root_pane"].decode(Pane.self)
        await store.refresh()
        store.selectSpace(space)
        let deck = TerminalTabDeckView()
        var publishedRoots: [String: [TerminalTabSnapshot]] = [:]
        var releasedRoots: Set<String> = []
        deck.didPublishRoot = { tabID, snapshot in
            if let snapshot { publishedRoots[tabID, default: []].append(snapshot) }
            else { releasedRoots.insert(tabID) }
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 650), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = deck
        window.orderBack(nil)
        defer { deck.removeAllTabs(); window.orderOut(nil); devices.stop() }
        func update(_ scheme: ColorScheme = .light) {
            deck.update(store: store, colorScheme: scheme, displayScale: window.backingScaleFactor)
            deck.layoutSubtreeIfNeeded()
        }
        var views: [String: HerdrTerminalView] = [:]
        for pane in [first, second] {
            store.selectedTab = pane.tabID
            store.selectedPane = pane.id
            await store.refresh()
            update()
            let marker = "appearance-\(pane.id)-END"
            _ = try await client.request("pane.send_input", params: ["pane_id": .string(pane.id), "text": .string("printf '\\033[31mANSI red \\033[38;2;42;190;240mRGB blue \\033[0m\(marker)\\n'"), "keys": .array([.string("enter")])])
            try await wait("mount \(pane.id)") {
                update()
                if let view = terminals(deck).first(where: { viewport($0).contains(marker) }) { views[pane.id] = view; return true }
                return false
            }
        }
        let hidden = views[first.id]!, visible = views[second.id]!
        let controllers = views.mapValues { $0.controller! }
        let delegates = views.mapValues { $0.delegate as! HerdrMac.TerminalSurface.Coordinator }
        let generations = delegates.mapValues { $0.controller.generation }
        let oldConfig = hidden.controller!.renderedConfig
        let theme = hidden.controller!.theme
        let hiddenHost = deck.subviews.compactMap { $0 as? NSHostingView<AnyView> }.first { $0.isHidden }!
        guard publishedRoots[first.tabID]?.isEmpty == false,
              publishedRoots[second.tabID]?.isEmpty == false else {
            throw HerdrError.message("Mounted hosts did not report initial root publications")
        }
        let baselineStart = publishedRoots[first.tabID]!.count
        for value in ["baseline one", "baseline two", "baseline three"] {
            _ = try await client.request("pane.rename", params: ["pane_id": .string(first.id), "label": .string(value)])
            await store.refresh(); update()
        }
        let baseline = publishedRoots[first.tabID]!.count - baselineStart
        print("BASELINE: hidden cosmetic root publications = \(baseline) across 3 metadata updates")
        guard baseline == 0 else { throw HerdrError.message("Hidden metadata roots regressed from the recorded zero-publication baseline") }
        try store.appearanceStore.applyImportedSettings(ImportedAppearanceSettings(themeName: "terminal", autoSwitch: true))
        update()
        guard hidden.controller!.renderedConfig == oldConfig, hidden.controller!.theme == theme,
              visible.controller === controllers[second.id] else {
            throw HerdrError.message("Reading embedded ANSI colors changed an active engine")
        }
        let paletteStart = publishedRoots[first.tabID]!.count
        for color in [ColorValue.rgb(180, 40, 80), .rgb(70, 130, 210), .rgb(90, 200, 100)] {
            store.appearanceStore.setNativeOverride(color, for: "accent", scope: .common)
            update()
        }
        let publications = publishedRoots[first.tabID]!.count - paletteStart
        print("CURRENT: hidden cosmetic root publications = \(publications) across 3 UI palette updates")
        guard publications == baseline, hidden.controller!.renderedConfig == oldConfig else {
            throw HerdrError.message("Hidden appearance publications differ from measured baseline")
        }
        // Search is a native AppKit descendant of the separately hosted root:
        // its attributed text proves the palette environment actually arrived.
        store.appearanceStore.setNativeOverride(.rgb(230, 70, 100), for: "text", scope: .common)
        store.paneSearchRequest = (second.id, UUID())
        update()
        try await wait("mounted search output") { descendants(deck).contains { $0 is SearchOutputTextView } }
        let search = descendants(deck).compactMap { $0 as? SearchOutputTextView }.first!
        try await wait("search snapshot") { !search.string.isEmpty }
        let actual = (search.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)?.usingColorSpace(.sRGB)
        guard let actual, abs(actual.redComponent - 230.0 / 255) < 0.01,
              abs(actual.greenComponent - 70.0 / 255) < 0.01 else {
            throw HerdrError.message("Mounted search did not receive current UI palette; got \(String(describing: actual))")
        }
        store.appearanceStore.setNativeOverride(.rgb(80, 100, 210), for: "text", scope: .common)
        update()
        try await wait("existing search restyles after a palette edit") {
            let color = (search.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)?.usingColorSpace(.sRGB)
            return color.map { abs($0.redComponent - 80.0 / 255) < 0.01 && abs($0.blueComponent - 210.0 / 255) < 0.01 } == true
        }
        let currentTextColor = (search.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)?.usingColorSpace(.sRGB)
        for (id, view) in views {
            guard terminals(deck).contains(where: { $0 === view }), view.controller === controllers[id],
                  delegates[id]!.controller.generation == generations[id], view.controller!.theme == theme,
                  view.controller!.renderedConfig == oldConfig else {
                throw HerdrError.message("UI palette changed live terminal/controller, connection, or Ghostty theme")
            }
            print("IDENTITY: \(id): native \(ObjectIdentifier(view)), renderer \(ObjectIdentifier(controllers[id]!)), transport \(ObjectIdentifier(delegates[id]!.controller)), generation \(generations[id]!) unchanged")
        }
        store.appearance = "dark"
        update(.light) // A forced mode wins even if the enclosing window is light.
        guard visible.controller!.renderedConfig != oldConfig, hidden.controller!.renderedConfig == oldConfig else {
            throw HerdrError.message("Light/dark update did not reach only the visible Ghostty surface")
        }
        let beforeReveal = publishedRoots[first.tabID]!.count
        var paletteReadyAtReveal = false
        let visibility = hidden.onRetainedTabVisibility
        hidden.onRetainedTabVisibility = { shown, zoomed in
            if shown {
                // Inspect retained presentation values at the exact native reveal boundary.
                paletteReadyAtReveal = hiddenHost.appearance?.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    && hidden.appearance?.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    && hidden.controller!.renderedConfig != oldConfig
                    && publishedRoots[first.tabID]!.count == beforeReveal + 1
                    && publishedRoots[first.tabID]!.last?.appearance == store.appearanceStore.resolvedSnapshot
            }
            visibility?(shown, zoomed)
        }
        store.selectedTab = first.tabID; store.selectedPane = first.id
        update(.dark)
        hidden.onRetainedTabVisibility = visibility
        guard paletteReadyAtReveal else { throw HerdrError.message("Pending appearance not applied before native reveal") }
        // The revealed root must use the latest palette, including changes made while hidden.
        store.paneSearchRequest = (first.id, UUID())
        update(.dark)
        try await wait("revealed search") { descendants(hiddenHost).contains { $0 is SearchOutputTextView } }
        let revealedSearch = descendants(hiddenHost).compactMap { $0 as? SearchOutputTextView }.first!
        try await wait("revealed snapshot") { !revealedSearch.string.isEmpty }
        let revealedColor = (revealedSearch.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)?.usingColorSpace(.sRGB)
        guard revealedColor == currentTextColor, hidden.controller === controllers[first.id], hidden.controller!.theme == theme,
              viewport(hidden).contains("appearance-\(first.id)-END"), delegates[first.id]!.controller.generation == generations[first.id] else {
            throw HerdrError.message("Reveal lost palette, controller, theme, connection, or terminal output")
        }
        store.appearance = "light"; update(.light)
        guard hidden.controller!.renderedConfig == oldConfig else { throw HerdrError.message("Light Ghostty theme did not restore in place") }
        print("PASS: UI palette preserves native/controller identity, stream, fixed Ghostty theme and ANSI/RGB output; hidden roots match baseline and catch up before reveal; light/dark updates in place")
        // Exercise real shell continuity beyond the existing viewport/identity checks.
        let pasteboard = NSPasteboard.general
        let savedClipboard = (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
        defer {
            pasteboard.clearContents()
            pasteboard.writeObjects(savedClipboard.map { values in
                let item = NSPasteboardItem()
                for (type, data) in values { item.setData(data, forType: type) }
                return item
            })
        }
        precondition(hidden.paste(text: "printf 'THEME_PID=%s\\n' $$; printf 'SCROLLBACK_SENTINEL_%s\\n' before; for i in {1..120}; do printf 'history-line-%s\\n' $i; done; printf 'SELECTION_SENTINEL_%s\\n' ready"))
        precondition(hidden.sendKey(.enter))
        try await wait("selection fixture output") { viewport(hidden).contains("SELECTION_SENTINEL_ready") }
        let beforeHistory = try await store.readPaneForSearch(first.id).text
        let pidLine = beforeHistory.components(separatedBy: "\n").first { $0.hasPrefix("THEME_PID=") && Int($0.dropFirst(10)) != nil }
        guard let pidLine, beforeHistory.contains("SCROLLBACK_SENTINEL_before") else { throw HerdrError.message("Missing live shell PID/scrollback sentinel") }
        precondition(hidden.performBindingAction("select_all"))
        func selection() throws -> String {
            pasteboard.clearContents()
            guard hidden.performBindingAction("copy_to_clipboard"), let value = pasteboard.string(forType: .string), value.contains("SELECTION_SENTINEL_ready") else {
                throw HerdrError.message("Theme change lost native terminal selection")
            }
            return value
        }
        let selectedText = try selection()
        for (mode, preset) in [("light", "one-light"), ("dark", "nord"), ("light", "uherdr")] {
            store.appearance = mode
            try store.appearanceStore.setPreset(preset)
            update(mode == "dark" ? .dark : .light)
            try await Task.sleep(for: .milliseconds(100))
            guard try selection() == selectedText, hidden.controller === controllers[first.id],
                  delegates[first.id]!.controller.generation == generations[first.id] else {
                throw HerdrError.message("Theme change replaced selection, renderer, or writable controller")
            }
        }
        precondition(hidden.paste(text: "printf 'AFTER_THEME_PID=%s\\n' $$; printf 'INPUT_CONTINUES_%s\\n' yes"))
        precondition(hidden.sendKey(.enter))
        try await wait("input after theme changes") { viewport(hidden).contains("INPUT_CONTINUES_yes") }
        let afterHistory = try await store.readPaneForSearch(first.id).text
        guard afterHistory.contains("AFTER_" + pidLine), afterHistory.contains("SCROLLBACK_SENTINEL_before"),
              afterHistory.contains("history-line-1"), afterHistory.contains("history-line-120") else {
            throw HerdrError.message("Shell PID or server scrollback changed across themes")
        }
        print("PASS: live \(pidLine), output sentinel, exact native selection, 120-line scrollback, subsequent input, renderer and writable controller survive light/dark and UI theme changes")
        if let directory = ProcessInfo.processInfo.environment["HERDR_APPEARANCE_CAPTURE_DIR"] {
            // Optional manual QA uses the real workspace and disposable shells.
            // No agent processes are started; the footer previews native status badges.
            deck.removeAllTabs()
            store.appearanceStore.resetNativeOverrides()
            _ = try await client.request("workspace.create", params: ["label": .string("Unselected space"), "cwd": .string("/tmp"), "focus": .bool(false)])
            _ = try await client.request("pane.split", params: ["target_pane_id": .string(first.id), "direction": .string("right"), "focus": .bool(false)])
            await store.refresh()
            let host = NSHostingView(rootView: AppearanceVisualFixture(store: store, devices: devices))
            window.contentView = host
            window.setContentSize(NSSize(width: 1200, height: 800))
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            for (name, mode, preset) in [("default-light", "light", "uherdr"), ("default-dark", "dark", "uherdr"), ("conditional-dark", "dark", "nord"), ("conditional-light-search", "light", "one-light")] {
                store.appearance = mode
                try store.appearanceStore.setPreset(preset)
                if name.hasPrefix("conditional") {
                    let config = try HerdrAppearanceConfig.parse(String(contentsOf: URL(fileURLWithPath: "docs/appearance-example.toml"), encoding: .utf8))
                    try store.appearanceStore.setNativeSidebar(config.sidebar)
                    _ = try await client.request("workspace.rename", params: ["workspace_id": .string(space.id), "label": .string("production")])
                    await store.refresh()
                }
                if name.contains("search") { store.paneSearchRequest = (first.id, UUID()) }
                try await Task.sleep(for: .milliseconds(800))
                if name.contains("search"), let field = window.firstResponder as? NSTextView {
                    field.insertText("ANSI", replacementRange: NSRange(location: NSNotFound, length: 0))
                    try await Task.sleep(for: .milliseconds(300))
                }
                let capture = Process()
                capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                capture.arguments = ["-x", "-l", String(window.windowNumber), directory + "/" + name + ".png"]
                try capture.run(); capture.waitUntilExit()
                print("VISUAL: \(name) screen capture exit \(capture.terminationStatus)")
                if capture.terminationStatus != 0, let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    if let data = bitmap.representation(using: .png, properties: [:]) {
                        try data.write(to: URL(fileURLWithPath: directory + "/" + name + "-native-cache.png"))
                        print("VISUAL: saved actual AppKit cached rendering (Metal terminal contents may be absent)")
                    }
                }
                // NavigationSplitView's material sidebar cannot be captured by
                // cacheDisplay on this host. Capture the same production sidebar
                // in a plain native host as separate, explicitly named evidence.
                let sidebar = NSHostingView(rootView: DeviceSidebarView(devices: devices)
                    .environment(\.resolvedAppearance, store.appearanceStore.resolvedSnapshot)
                    .environment(\.colorScheme, mode == "dark" ? .dark : .light)
                    .foregroundStyle(NativePalette(snapshot: store.appearanceStore.resolvedSnapshot, colorScheme: mode == "dark" ? .dark : .light).color("text"))
                    .background(Color(nsColor: .windowBackgroundColor)))
                let sidebarWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
                sidebarWindow.appearance = NSAppearance(named: mode == "dark" ? .darkAqua : .aqua)
                sidebarWindow.contentView = sidebar
                sidebarWindow.orderBack(nil)
                try await Task.sleep(for: .milliseconds(150))
                sidebar.layoutSubtreeIfNeeded()
                if let bitmap = sidebar.bitmapImageRepForCachingDisplay(in: sidebar.bounds) {
                    sidebar.cacheDisplay(in: sidebar.bounds, to: bitmap)
                    if let data = bitmap.representation(using: .png, properties: [:]) {
                        try data.write(to: URL(fileURLWithPath: directory + "/" + name + "-sidebar-native-cache.png"))
                    }
                }
                sidebarWindow.orderOut(nil)
                sidebarWindow.contentView = nil
            }
            window.contentView = nil
        }
        deck.removeAllTabs()
        guard releasedRoots == Set([first.tabID, second.tabID]) else {
            throw HerdrError.message("Cleared hosts did not report root removal publications")
        }
        _ = try await client.request("workspace.close", params: ["workspace_id": .string(space.id)])
    }

    @MainActor static func wait(_ label: String, _ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(15)
        while !predicate() {
            guard Date() < deadline else { throw HerdrError.message("Timed out: \(label)") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    @MainActor static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    @MainActor static func terminals(_ view: NSView) -> [HerdrTerminalView] { descendants(view).compactMap { $0 as? HerdrTerminalView } }
    @MainActor static func viewport(_ view: HerdrTerminalView) -> String {
        guard case .inMemory(let session) = view.configuration.backend else { return "" }
        return session.readViewportText() ?? ""
    }
}

private struct AppearanceVisualFixture: View {
    @ObservedObject var store: SessionStore
    let devices: DeviceStore
    var body: some View {
        VStack(spacing: 0) {
            WorkspaceView(store: store, devices: devices)
            HStack {
                ForEach([AgentStatus.working, .blocked, .done, .idle, .unknown], id: \.self) { StatusBadge(status: $0) }
            }.padding(8)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.resolvedAppearance, store.appearanceStore.resolvedSnapshot)
        .preferredColorScheme(store.colorScheme)
    }
}
