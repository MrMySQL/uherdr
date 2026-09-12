import AppKit
import SwiftUI
import GhosttyTerminal
import HerdrCore
@testable import HerdrMac

enum GhosttyLiveTests {
    @MainActor static func run(socket: String, executable: String) async throws {
        guard socket.hasPrefix("/tmp/"), socket.contains("native-client-test") else {
            throw HerdrError.message("Requires an explicit disposable native-client-test socket under /tmp")
        }
        let client = HerdrClient(socketPath: socket)
        let created = try await client.request("workspace.create", params: [
            "label": .string("Ghostty integration"), "cwd": .string("/tmp"), "focus": .bool(false)
        ])
        let workspace = try created["workspace"].decode(Workspace.self)
        let pane = try created["root_pane"].decode(Pane.self)
        let suiteName = "dev.herdr.ghostty-live-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let devices = DeviceStore(defaults: defaults, profiles: [
            DeviceProfile(name: "Ghostty test", kind: .local, socketPath: socket, executable: executable)
        ])
        let store = devices.activeSession
        defer { devices.stop() }
        store.selectedPane = pane.id
        let transport = HerdrMac.TerminalController()
        let host = NSHostingView(rootView: AnyView(HerdrMac.TerminalSurface(
            controller: transport, pane: pane, store: store, dark: true, fontSize: store.fontSize, selected: store.selectedPane == pane.id
        )))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 400),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer {
            transport.stop()
            window.orderOut(nil)
        }

        func waitFor(_ predicate: () -> Bool) async throws {
            for _ in 0..<100 {
                if predicate() { return }
                if let error = transport.error { throw HerdrError.message(error) }
                try await Task.sleep(for: .milliseconds(50))
            }
            throw HerdrError.message("Timed out waiting for Ghostty/Herdr stream")
        }
        func terminal(in root: NSView) -> HerdrTerminalView? {
            if let view = root as? HerdrTerminalView { return view }
            return root.subviews.compactMap { terminal(in: $0) }.first
        }
        do {
            try await waitFor { transport.ready }
            guard let view = terminal(in: host),
                  case .inMemory(let session) = view.configuration.backend else {
                throw HerdrError.message("SwiftUI did not mount the Ghostty host backend")
            }
            window.makeFirstResponder(view)
            precondition(view.paste(text: "printf 'ghostty-live-%s\\n' ok"))
            precondition(view.sendKey(.enter))
            try await waitFor { session.readViewportText()?.contains("ghostty-live-ok") == true }
            print("PASS: production SwiftUI bridge sends shell input and renders Herdr output")

            window.setContentSize(NSSize(width: 980, height: 540))
            try await Task.sleep(for: .milliseconds(200))
            precondition(view.paste(text: "printf 'after-resize-%s\\n' ok"))
            precondition(view.sendKey(.enter))
            try await waitFor { session.readViewportText()?.contains("after-resize-ok") == true }
            print("PASS: live Herdr terminal remains interactive after resize")

            host.rootView = AnyView(HerdrMac.TerminalSurface(
                controller: transport, pane: pane, store: store, dark: true, fontSize: store.fontSize, selected: store.selectedPane == pane.id, visible: false
            ))
            try await Task.sleep(for: .milliseconds(100))
            guard window.firstResponder !== view, !view.acceptsFirstResponder else {
                throw HerdrError.message("A hidden terminal retained keyboard focus while the next tab loads")
            }
            host.rootView = AnyView(HerdrMac.TerminalSurface(
                controller: transport, pane: pane, store: store, dark: true, fontSize: store.fontSize, selected: store.selectedPane == pane.id
            ))
            try await waitFor { window.firstResponder === view }
            print("PASS: hidden terminals relinquish keyboard focus and regain it when shown")

            transport.retry()
            try await waitFor { transport.ready }
            try await waitFor { session.readViewportText()?.contains("ghostty-live-ok") == true }
            print("PASS: reconnect preserves the server pane and its output")

            if ProcessInfo.processInfo.environment["HERDR_TEST_MOUSE"] == "1" {
                try await checkMouse(view: view, transport: transport, session: session, window: window)
            }

            host.rootView = AnyView(EmptyView())
            try await Task.sleep(for: .milliseconds(100))
            precondition(view.controller == nil, "SwiftUI teardown must release the engine")
            let existing = try await client.request("pane.get", params: ["pane_id": .string(pane.id)])
            precondition(existing["pane"]["pane_id"].string == pane.id)
            print("PASS: SwiftUI teardown detaches without closing the server pane")
            try await checkZoom(client: client, devices: devices, workspace: workspace, pane: pane)
            try await checkRemote(socket: socket, executable: executable, pane: pane, defaults: defaults)
            _ = try await client.request("workspace.close", params: ["workspace_id": .string(workspace.id)])
        } catch {
            host.rootView = AnyView(EmptyView())
            transport.stop()
            _ = try? await client.request("workspace.close", params: ["workspace_id": .string(workspace.id)])
            throw error
        }
    }

    @MainActor private static func checkMouse(view: HerdrTerminalView, transport: HerdrMac.TerminalController,
                                             session: InMemoryTerminalSession, window: NSWindow) async throws {
        func waitFor(_ message: String, _ predicate: () -> Bool) async throws {
            for _ in 0..<100 {
                if predicate() { return }
                if let error = transport.error { throw HerdrError.message(error) }
                try await Task.sleep(for: .milliseconds(50))
            }
            throw HerdrError.message(message + ": " + (session.readViewportText() ?? "<no viewport>"))
        }
        let path = FileManager.default.currentDirectoryPath + "/Tests/Fixtures/terminal-mouse.py"
        precondition(view.paste(text: "python3 '" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"))
        precondition(view.sendKey(.enter))
        try await waitFor("Mouse fixture did not start") {
            session.readViewportText()?.contains("tool-collapsed") == true
        }
        try await waitFor("Herdr stream omitted application mouse state") { view.isMouseCaptured }
        func click() {
            // Inside the first cell at the test's default font, away from the
            // window corner where AppKit intercepts clicks for resizing.
            let point = view.convert(NSPoint(x: 6, y: view.bounds.height - 10), to: nil)
            for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp] {
                let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!
                // Exercise the mounted production view's AppKit handlers;
                // a synthetic test app may not own foreground window activation.
                if type == .leftMouseDown { view.mouseDown(with: event) }
                else { view.mouseUp(with: event) }
            }
        }
        click()
        try await waitFor("Click did not expand the tool result or release the button") {
            let text = session.readViewportText() ?? ""
            return text.contains("tool-result: success") && text.contains("mouse-release-received")
        }
        print("PASS: native click expands a tool call through the real Herdr stream")

        // Reset only the test renderer to prove a new stream restores mode state.
        session.receive("\u{1b}[?1000l\u{1b}[?1006l")
        session.waitForPendingOutput()
        precondition(!view.isMouseCaptured)
        transport.retry()
        try await waitFor("Reconnect did not restore application mouse state") { transport.ready && view.isMouseCaptured }
        click()
        try await waitFor("Click did not collapse the tool call after reconnect") {
            session.readViewportText()?.contains("tool-collapsed") == true
        }
        print("PASS: reconnect restores mouse input for an already-running application")

        transport.send(Data("d".utf8))
        try await waitFor("Disabling mouse mode without drawing left capture enabled") { !view.isMouseCaptured }
        transport.send(Data("e".utf8))
        try await waitFor("Enabling mouse mode without drawing did not update capture") { view.isMouseCaptured }
        transport.send(Data("q".utf8))
        try await waitFor("Exiting the application did not restore ordinary terminal input") {
            !view.isMouseCaptured && session.readViewportText()?.contains("mouse-fixture-finished") == true
        }
        print("PASS: mode-only changes and application exit update native mouse capture")
    }

    @MainActor private static func checkRemote(socket: String, executable: String, pane: Pane, defaults: UserDefaults) async throws {
        let fixture = FileManager.default.currentDirectoryPath + "/Tests/Fixtures/ssh-fixture.py"
        let remote = SessionStore(
            profile: DeviceProfile(name: "Remote Ghostty", host: "fixture.test", socketPath: socket, executable: executable),
            defaults: defaults, tunnel: SSHTunnel(sshExecutable: fixture)
        )
        defer { remote.disconnect() }
        await remote.refresh()
        guard remote.connected else { throw HerdrError.message(remote.connectionError ?? "Remote fixture did not connect") }
        remote.selectedPane = pane.id
        let transport = HerdrMac.TerminalController()
        let host = NSHostingView(rootView: AnyView(HerdrMac.TerminalSurface(
            controller: transport, pane: pane, store: remote, dark: true, fontSize: remote.fontSize, selected: remote.selectedPane == pane.id
        )))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 400),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { host.rootView = AnyView(EmptyView()); transport.stop(); window.orderOut(nil) }
        func waitFor(_ predicate: () -> Bool) async throws {
            for _ in 0..<100 {
                if predicate() { return }
                if let error = transport.error { throw HerdrError.message(error) }
                try await Task.sleep(for: .milliseconds(50))
            }
            throw HerdrError.message("Remote Ghostty terminal timed out")
        }
        try await waitFor { transport.ready }
        let usageMarker = DeviceProfile.clientSocketPath(for: remote.effectiveSocketPath) + ".used"
        precondition(FileManager.default.fileExists(atPath: usageMarker), "The Ghostty coordinator must connect through the device tunnel, not directly to its configured remote path")
        func terminal(in root: NSView) -> HerdrTerminalView? {
            if let view = root as? HerdrTerminalView { return view }
            return root.subviews.compactMap { terminal(in: $0) }.first
        }
        guard let view = terminal(in: host), case .inMemory(let session) = view.configuration.backend else {
            throw HerdrError.message("Remote Ghostty surface did not mount")
        }
        window.makeFirstResponder(view)
        precondition(view.paste(text: "printf 'ghostty-remote-%s\\n' ok"))
        precondition(view.sendKey(.enter))
        try await waitFor { session.readViewportText()?.contains("ghostty-remote-ok") == true }
        print("PASS: production Ghostty bridge uses the device tunnel for remote terminal input and output")
    }

    @MainActor private static func checkZoom(client: HerdrClient, devices: DeviceStore,
                                            workspace: Workspace, pane: Pane) async throws {
        let store = devices.activeSession
        let right = try await client.request("pane.split", params: [
            "target_pane_id": .string(pane.id), "direction": .string("right"), "focus": .bool(false)
        ])["pane"].decode(Pane.self)
        let bottom = try await client.request("pane.split", params: [
            "target_pane_id": .string(right.id), "direction": .string("down"), "focus": .bool(false)
        ])["pane"].decode(Pane.self)
        store.reconnect()
        store.selectSpace(workspace)
        let host = NSHostingView(rootView: AnyView(WorkspaceView(store: store, devices: devices)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { host.rootView = AnyView(EmptyView()); window.orderOut(nil) }
        func terminals(in root: NSView) -> [HerdrTerminalView] {
            if let terminal = root as? HerdrTerminalView { return [terminal] }
            return root.subviews.flatMap { terminals(in: $0) }
        }
        func waitFor(_ message: String, _ predicate: () -> Bool) async throws {
            for _ in 0..<100 {
                if predicate() { return }
                try await Task.sleep(for: .milliseconds(50))
            }
            throw HerdrError.message(message)
        }
        try await waitFor("Split terminals did not mount") { terminals(in: host).count == 3 }
        let originals = terminals(in: host)
        let frames = originals.map { $0.convert($0.bounds, to: host) }
        // The selected bottom-right leaf must expand through both split levels.
        let target = originals.max { a, b in
            let a = a.convert(a.bounds, to: host), b = b.convert(b.bounds, to: host)
            if abs(a.midX - b.midX) > 2 { return a.midX < b.midX }
            return host.isFlipped ? a.midY < b.midY : a.midY > b.midY
        }!
        store.focusPane(bottom.id)
        try await waitFor("Nested pane did not receive focus") {
            window.firstResponder === target
        }
        guard case .inMemory(let session) = target.configuration.backend else {
            throw HerdrError.message("Expected the Herdr in-memory backend")
        }
        precondition(target.paste(text: "printf 'zoom-retains-%s\\n' content"))
        precondition(target.sendKey(.enter))
        try await waitFor("Terminal did not render before zoom") {
            session.readViewportText()?.contains("zoom-retains-content") == true
        }
        for _ in 0..<3 {
            store.zoom(bottom.id)
            try await waitFor("Pane did not zoom") { store.currentLayout?.zoomed == true }
            try await Task.sleep(for: .milliseconds(100))
            guard Set(terminals(in: host).map(ObjectIdentifier.init)) == Set(originals.map(ObjectIdentifier.init)),
                  originals.allSatisfy({ $0.controller != nil }) else {
                throw HerdrError.message("Zoom recreated terminal views instead of preserving their live connections")
            }
            guard target.bounds.width > 800, target.bounds.height > 600 else {
                throw HerdrError.message("Nested pane did not expand to fill the workspace: \(target.bounds)")
            }
            let hidden = originals.first { $0 !== target }!
            let click = hidden.convert(NSPoint(x: hidden.bounds.midX, y: hidden.bounds.midY), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                NSApp.sendEvent(NSEvent.mouseEvent(with: type, location: click, modifierFlags: [],
                                                  timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: window.windowNumber, context: nil,
                                                  eventNumber: 0, clickCount: 1, pressure: 1)!)
            }
            guard store.selectedPane == bottom.id, window.firstResponder === target else {
                throw HerdrError.message("A hidden pane intercepted a click on the zoomed terminal")
            }
            store.zoom(bottom.id)
            try await waitFor("Pane did not restore") { store.currentLayout?.zoomed == false }
            try await Task.sleep(for: .milliseconds(100))
            guard Set(terminals(in: host).map(ObjectIdentifier.init)) == Set(originals.map(ObjectIdentifier.init)),
                  zip(originals, frames).allSatisfy({ view, frame in
                      let restored = view.convert(view.bounds, to: host)
                      return abs(restored.width - frame.width) < 2 && abs(restored.height - frame.height) < 2
                  }), session.readViewportText()?.contains("zoom-retains-content") == true else {
                throw HerdrError.message("Restore lost the original terminal views, split sizes, or content")
            }
        }
        precondition(target.paste(text: "printf 'after-zoom-%s\\n' ok"))
        precondition(target.sendKey(.enter))
        try await waitFor("Terminal input failed after zoom") {
            session.readViewportText()?.contains("after-zoom-ok") == true
        }
        print("PASS: repeated nested pane zoom preserves live terminals, split sizes, content, and input")

        let originalTab = store.currentTab!
        let otherTab = try await client.request("tab.create", params: [
            "workspace_id": .string(workspace.id), "label": .string("Switch target"), "focus": .bool(false)
        ])["tab"].decode(HerdrCore.Tab.self)
        await store.refresh()
        store.selectTab(otherTab)
        try await waitFor("Other tab did not load") { store.currentLayout?.tabID == otherTab.id }
        try await Task.sleep(for: .milliseconds(200))
        guard originals.allSatisfy({ $0.controller != nil && $0.window === window }) else {
            throw HerdrError.message("Switching tabs destroyed the previous terminal renderers and streams")
        }
        let other = terminals(in: host).first { view in !originals.contains { $0 === view } }!
        try await waitFor("Other tab did not receive focus") { window.firstResponder === other }
        for _ in 0..<3 {
            store.selectTab(originalTab)
            try await waitFor("Original tab did not receive focus") { window.firstResponder === target }
            guard session.readViewportText()?.contains("after-zoom-ok") == true,
                  zip(originals, frames).allSatisfy({ view, frame in
                      let restored = view.convert(view.bounds, to: host)
                      return abs(restored.width - frame.width) < 2 && abs(restored.height - frame.height) < 2
                  }) else {
                throw HerdrError.message("Tab switching lost terminal content or changed split sizes")
            }
            store.selectTab(otherTab)
            try await waitFor("Other tab lost focus on return") { window.firstResponder === other }
        }
        _ = try await client.request("tab.close", params: ["tab_id": .string(otherTab.id)])
        await store.refresh()
        try await waitFor("Closed tab retained its terminal stream") { other.controller == nil }
        print("PASS: tab switching preserves terminal instances, content, geometry and focus; closing releases them")

        // macOS exposes provider contents only in performDrop. Hover feedback
        // must be available synchronously, with no decoded source payload.
        try await waitFor("Pane layout unavailable for preview") { store.paneDragPayload(for: bottom.id) != nil }
        let preview = PaneDropState()
        let previewDelegate = PaneDockDropDelegate(paneID: bottom.id, size: CGSize(width: 400, height: 200),
                                                   visible: true, store: store, state: preview)
        for (point, edge) in [(CGPoint(x: 200, y: 5), PaneDockEdge.top),
                              (CGPoint(x: 5, y: 100), .left),
                              (CGPoint(x: 395, y: 100), .right),
                              (CGPoint(x: 200, y: 195), .bottom)] {
            previewDelegate.updatePreview(location: point, hasPaneItems: true)
            precondition(preview.edge == edge, "Preview must appear and follow the pointer before drop data is available")
        }
        previewDelegate.updatePreview(location: CGPoint(x: 200, y: 5), hasPaneItems: false)
        precondition(preview.edge == nil, "File and text drags must not show a pane preview")
        previewDelegate.updatePreview(location: CGPoint(x: 401, y: 100), hasPaneItems: true)
        precondition(preview.edge == nil, "Leaving the pane must clear the preview")
        previewDelegate.updatePreview(location: CGPoint(x: 200, y: 5), hasPaneItems: true)
        preview.reset()
        precondition(preview.edge == nil, "Ending a drag must clear its preview")
        previewDelegate.updatePreview(location: CGPoint(x: 200, y: 5), hasPaneItems: true)
        let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                      windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
                                      charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
        preview.handleEndingEvent(escape)
        precondition(preview.edge == nil, "Escape must clear feedback even when AppKit omits dropExited")
        // Native dragging can consume mouseUp and omit dropExited on a view
        // crossed earlier. Session completion must clear every visited pane.
        let previousTarget = PaneDropState()
        previousTarget.edge = .left
        preview.edge = .top
        PaneDropState.endDrag()
        precondition(preview.edge == nil && previousTarget.edge == nil,
                     "Ending the native drag must clear all previews without mouse or exit callbacks")
        print("PASS: pane preview appears before payload loading, tracks all edges, and clears correctly")

        for (index, edge) in PaneDockEdge.allCases.enumerated() {
            try await waitFor("Pane layout unavailable for docking") { store.paneDragPayload(for: pane.id) != nil }
            precondition(store.movePane(store.paneDragPayload(for: pane.id)!, to: bottom.id, edge: edge))
            try await waitFor("Pane docking did not finish") { !store.busy }
            if let error = store.operationError { throw HerdrError.message(error) }
            try await waitFor("Docked terminal did not regain keyboard focus") {
                store.selectedPane == pane.id && terminals(in: host).count == 3
                    && (window.firstResponder as? HerdrTerminalView)?.canAcceptFileDrop() == true
            }
            guard let moved = window.firstResponder as? HerdrTerminalView,
                  case .inMemory(let movedSession) = moved.configuration.backend else {
                throw HerdrError.message("Missing docked terminal renderer")
            }
            let marker = "dock-renderer-\(index)-ok"
            precondition(moved.paste(text: "printf 'dock-renderer-\(index)-%s\\n' ok"))
            precondition(moved.sendKey(.enter))
            try await waitFor("Docked terminal did not accept input: \(edge)") {
                movedSession.readViewportText()?.contains(marker) == true
            }
        }
        print("PASS: repeated four-edge docking preserves live terminal input, rendering, and focus")
        let transferTab = try await client.request("tab.create", params: [
            "workspace_id": .string(workspace.id), "label": .string("Transfer target"), "focus": .bool(false)
        ])["tab"].decode(HerdrCore.Tab.self)
        await store.refresh()
        // Visit both tabs first so the transfer exercises retained renderers.
        store.selectTab(transferTab)
        try await waitFor("Transfer target did not load") { !store.busy && store.currentLayout?.tabID == transferTab.id }
        store.selectTab(originalTab)
        try await waitFor("Source tab did not load") { store.paneDragPayload(for: pane.id) != nil }
        for (index, destination) in [transferTab, originalTab].enumerated() {
            precondition(store.movePane(store.paneDragPayload(for: pane.id)!, toTab: destination.id))
            try await waitFor("Tab transfer did not finish") { !store.busy }
            if let error = store.operationError { throw HerdrError.message(error) }
            try await waitFor("Transferred terminal did not regain keyboard focus") {
                store.selectedTab == destination.id && store.selectedPane == pane.id
                    && terminals(in: host).count == 4
                    && (window.firstResponder as? HerdrTerminalView)?.canAcceptFileDrop() == true
            }
            guard let moved = window.firstResponder as? HerdrTerminalView,
                  case .inMemory(let movedSession) = moved.configuration.backend else {
                throw HerdrError.message("Missing transferred terminal renderer")
            }
            try await waitFor("Tab transfer lost scrollback") {
                movedSession.readViewportText()?.contains("dock-renderer-3-ok") == true
            }
            precondition(moved.paste(text: "printf 'tab-transfer-\(index)-%s\\n' ok"))
            precondition(moved.sendKey(.enter))
            try await waitFor("Transferred terminal did not accept input") {
                movedSession.readViewportText()?.contains("tab-transfer-\(index)-ok") == true
            }
        }
        print("PASS: mounted cross-tab transfers preserve terminal input, rendering, scrollback, and focus")
    }
}
