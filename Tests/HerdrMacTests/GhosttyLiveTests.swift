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
            controller: transport, pane: pane, store: store, dark: true
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

            transport.retry()
            try await waitFor { transport.ready }
            try await waitFor { session.readViewportText()?.contains("ghostty-live-ok") == true }
            print("PASS: reconnect preserves the server pane and its output")

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
            controller: transport, pane: pane, store: remote, dark: true
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
    }
}
