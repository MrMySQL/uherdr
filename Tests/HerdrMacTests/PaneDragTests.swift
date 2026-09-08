import Foundation
import HerdrCore

@main struct PaneDragTests {
    @MainActor static func main() async throws {
        testPreviewGeometry()
        let suite = "dev.herdr.pane-drag-tests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let profile = DeviceProfile(name: "Pane fixture", kind: .local,
                                    socketPath: "/tmp/uherdr-pane-drag.sock", executable: "/tmp/herdr")
        let cases: [(PaneDockEdge, LayoutNode, [String])] = [
            (.left, .split(.right, 0.5, .pane("a"), .pane("b")), ["pane.move", "pane.move", "pane.swap"]),
            (.right, .split(.right, 0.5, .pane("b"), .pane("a")), ["pane.move", "pane.move"]),
            (.top, .split(.down, 0.5, .pane("a"), .pane("b")), ["pane.move", "pane.move", "pane.swap"]),
            (.bottom, .split(.down, 0.5, .pane("b"), .pane("a")), ["pane.move", "pane.move"])
        ]
        for (edge, expected, methods) in cases {
            for failure in ["", "park", "dock"] + (methods.count == 3 ? ["order"] : []) {
                let client = DockClient(failure: failure)
                let store = SessionStore(profile: profile, defaults: defaults, client: client)
                await store.refresh()
                let original = store.currentLayout
                let payload = store.paneDragPayload(for: "a")!
                for target in ["a", "missing", "other"] {
                    precondition(!store.movePane(payload, to: target, edge: edge), "Self, closed, and cross-tab drops must be rejected")
                }
                let foreign = PaneDragPayload(deviceID: UUID(), connectionGeneration: payload.connectionGeneration, tabID: "t", paneID: "a")
                precondition(!store.movePane(foreign, to: "b", edge: edge), "Pane IDs cannot cross devices")
                let stale = PaneDragPayload(deviceID: profile.id, connectionGeneration: UUID(), tabID: "t", paneID: "a")
                precondition(!store.movePane(stale, to: "b", edge: edge), "Previous connections cannot move panes")
                store.busy = true
                precondition(!store.movePane(payload, to: "b", edge: edge))
                store.busy = false
                precondition(store.movePane(payload, to: "b", edge: edge))
                precondition(!store.movePane(payload, to: "b", edge: edge), "Repeated drops cannot queue another move")
                store.busy = false // Another completed action must not unlock docking.
                precondition(!store.movePane(payload, to: "b", edge: edge), "The docking lock must survive other actions clearing busy")
                store.busy = true
                await store.refresh() // Polling must not publish the temporary tab.
                try await settle(store)
                let calls = await client.calls
                precondition(calls.map(\.0) == (failure == "park" ? ["pane.move"] : failure == "dock" ? ["pane.move", "pane.move"] : methods))
                let snapshots = await client.snapshotCount
                precondition(snapshots == 2, "Do not refresh the intermediate temporary-tab state")
                precondition(calls[0].1["pane_id"] == .string("a"))
                precondition(calls[0].1["destination"]?["type"] == .string("new_tab"))
                precondition(calls[0].1["destination"]?["workspace_id"] == .string("w"))
                precondition(calls[0].1["focus"] == .bool(false))
                if calls.count >= 2 {
                    precondition(calls[1].1["pane_id"] == .string("a"))
                    precondition(calls[1].1["destination"]?["target_pane_id"] == .string("b"))
                    precondition(calls[1].1["destination"]?["tab_id"] == .string("t"))
                    precondition(calls[1].1["destination"]?["ratio"] == .number(0.5))
                    precondition(calls[1].1["focus"] == .bool(true))
                }
                if calls.count == 3 {
                    precondition(calls[2].1 == ["source_pane_id": .string("a"), "target_pane_id": .string("b")])
                }
                if failure.isEmpty {
                    precondition(store.operationError == nil)
                    precondition(store.currentLayout?.root == expected, "Persisted layout must dock on the requested edge")
                    precondition(store.selectedPane == "a")
                } else {
                    precondition(store.operationError != nil)
                    if failure == "park" { precondition(store.currentLayout == original) }
                    else if failure == "dock" {
                        precondition(store.selectedTab == "parking", "Reveal the safe terminal if the transfer back fails")
                        precondition(store.currentLayout?.root == .pane("a"))
                    } else {
                        precondition(store.currentLayout?.root.paneIDs == ["b", "a"], "Refresh a partially completed move after failure")
                    }
                }
                store.disconnect()
                precondition(store.paneDragPayload(for: "a") == nil)
                precondition(!store.movePane(payload, to: "b", edge: edge))
            }
        }
        let interrupted = SessionStore(profile: profile, defaults: defaults, client: DockClient(failure: ""))
        await interrupted.refresh()
        precondition(interrupted.movePane(interrupted.paneDragPayload(for: "a")!, to: "b", edge: .top))
        interrupted.connected = false
        try await settle(interrupted)
        print("PASS: four docking edges, preview geometry, focus, invalid drops, duplicate drops, and partial failures")
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--live" {
            try await testLive(socket: CommandLine.arguments[2], defaults: defaults)
        }
    }

    static func testPreviewGeometry() {
        let size = CGSize(width: 400, height: 200)
        let cases: [(CGPoint, PaneDockEdge, CGRect)] = [
            (CGPoint(x: 5, y: 100), .left, CGRect(x: 0, y: 0, width: 200, height: 200)),
            (CGPoint(x: 395, y: 100), .right, CGRect(x: 200, y: 0, width: 200, height: 200)),
            (CGPoint(x: 200, y: 5), .top, CGRect(x: 0, y: 0, width: 400, height: 100)),
            (CGPoint(x: 200, y: 195), .bottom, CGRect(x: 0, y: 100, width: 400, height: 100))
        ]
        for (point, edge, rect) in cases {
            precondition(PaneDockEdge.at(point, in: size) == edge)
            precondition(edge.preview(in: size) == rect)
        }
        precondition(PaneDockEdge.at(CGPoint(x: 100, y: 60), in: size) == .top, "Use physical distance on rectangular panes")
        precondition(PaneDockEdge.at(CGPoint(x: 200, y: 100), in: size) == .bottom, "The center has a deterministic destination")
        precondition(PaneDockEdge.at(CGPoint(x: -1, y: 10), in: size) == nil)
        precondition(PaneDockEdge.at(CGPoint(x: 401, y: 10), in: size) == nil)
        precondition(PaneDockEdge.at(.zero, in: .zero) == nil)
    }

    @MainActor static func settle(_ store: SessionStore) async throws {
        for _ in 0..<200 {
            if !store.busy { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        preconditionFailure("Pane move did not finish")
    }

    @MainActor static func testLive(socket: String, defaults: UserDefaults) async throws {
        guard socket.hasPrefix("/tmp/"), socket.contains("native-client-test") else {
            throw HerdrError.message("Requires an explicit disposable test socket")
        }
        let client = HerdrClient(socketPath: socket)
        for edge in PaneDockEdge.allCases {
            let created = try await client.request("workspace.create", params: ["label": .string("Dock test"), "cwd": .string("/tmp"), "focus": .bool(true)])
            let source = try created["root_pane"].decode(Pane.self)
            do {
                let sibling = try await client.request("pane.split", params: ["target_pane_id": .string(source.id), "direction": .string("right")])["pane"].decode(Pane.self)
                let target = try await client.request("pane.split", params: ["target_pane_id": .string(sibling.id), "direction": .string("down")])["pane"].decode(Pane.self)
                _ = try await client.request("layout.set_split_ratio", params: ["tab_id": .string(source.tabID), "path": .array([.bool(true)]), "ratio": .number(0.65)])
                let profile = DeviceProfile(name: "Dock live", kind: .local, socketPath: socket, executable: "/tmp/herdr")
                let store = SessionStore(profile: profile, defaults: defaults, client: client)
                await store.refresh()
                precondition(store.movePane(store.paneDragPayload(for: source.id)!, to: target.id, edge: edge))
                try await settle(store)
                if let error = store.operationError { throw HerdrError.message(error) }
                let nested: LayoutNode
                switch edge {
                case .left: nested = .split(.right, 0.5, .pane(source.id), .pane(target.id))
                case .right: nested = .split(.right, 0.5, .pane(target.id), .pane(source.id))
                case .top: nested = .split(.down, 0.5, .pane(source.id), .pane(target.id))
                case .bottom: nested = .split(.down, 0.5, .pane(target.id), .pane(source.id))
                }
                precondition(store.currentLayout?.root == .split(.down, 0.65, .pane(sibling.id), nested), "Docking \(edge) must collapse the old split and retain unrelated ratios: \(String(describing: store.currentLayout?.root))")
                for pane in [source, sibling, target] {
                    precondition(store.panes.first { $0.id == pane.id }?.terminalID == pane.terminalID)
                }
                precondition(store.selectedPane == source.id)
                store.disconnect()
                _ = try await client.request("workspace.close", params: ["workspace_id": .string(source.workspaceID)])
            } catch {
                _ = try? await client.request("workspace.close", params: ["workspace_id": .string(source.workspaceID)])
                throw error
            }
        }
        print("PASS: live docking on all four edges, old split collapse, nested ratios, focus, and terminal identity")
    }
}

private actor DockClient: HerdrRequesting {
    let failure: String
    var snapshotCount = 0
    var parked = false
    var moved = false
    var swapped = false
    var direction = "right"
    var calls: [(String, [String: JSONValue])] = []
    init(failure: String) { self.failure = failure }
    func request(_ method: String, params: [String: JSONValue], timeout: Int) async throws -> JSONValue {
        switch method {
        case "pane.move", "pane.swap":
            calls.append((method, params))
            let stage = method == "pane.swap" ? "order" : params["destination"]?["type"] == .string("new_tab") ? "park" : "dock"
            if stage == failure { throw HerdrError.message("Fixture failure: \(stage)") }
            if stage == "park" {
                parked = true
                return .object(["move_result": .object(["pane": .object(["tab_id": .string("parking")])])])
            }
            if stage == "dock" { parked = false; moved = true; direction = params["destination"]?["split"].string ?? "missing" }
            else { swapped = true }
            return .object(["type": .string("ok")])
        case "session.snapshot":
            snapshotCount += 1
            let value = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"snapshot":{"version":"test","protocol":20,"focused_workspace_id":"w","focused_tab_id":"t","focused_pane_id":"a","workspaces":[{"workspace_id":"w","label":"Test","active_tab_id":"t","pane_count":3,"tab_count":2,"agent_status":"unknown"}],"tabs":[{"tab_id":"t","workspace_id":"w","label":"Test","pane_count":2,"agent_status":"unknown"},{"tab_id":"other-tab","workspace_id":"w","label":"Other","pane_count":1,"agent_status":"unknown"}],"panes":[{"pane_id":"a","terminal_id":"ta","workspace_id":"w","tab_id":"t","agent_status":"unknown"},{"pane_id":"b","terminal_id":"tb","workspace_id":"w","tab_id":"t","agent_status":"unknown"},{"pane_id":"other","terminal_id":"to","workspace_id":"w","tab_id":"other-tab","agent_status":"unknown"}],"agents":[]}}"#.utf8))
            if !parked { return value }
            guard case .object(var snapshot) = value["snapshot"],
                  case .array(var tabs) = snapshot["tabs"], case .array(let panes) = snapshot["panes"] else { fatalError("Bad fixture") }
            tabs.append(.object(["tab_id": .string("parking"), "workspace_id": .string("w"), "label": .string("Terminal"), "pane_count": .number(1), "agent_status": .string("unknown")]))
            snapshot["tabs"] = .array(tabs)
            snapshot["panes"] = .array(panes.map { pane in
                guard pane["pane_id"] == .string("a"), case .object(var object) = pane else { return pane }
                object["tab_id"] = .string("parking")
                return .object(object)
            })
            return .object(["snapshot": .object(snapshot)])
        case "layout.export":
            if params["tab_id"] == .string("parking") {
                return .object(["layout": .object(["tab_id": .string("parking"), "zoomed": .bool(false), "focused_pane_id": .string("a"), "root": .object(["type": .string("pane"), "pane_id": .string("a")])])])
            }
            return .object(["layout": .object([
                "tab_id": .string("t"), "zoomed": .bool(false), "focused_pane_id": .string("a"),
                "root": .object(["type": .string("split"), "direction": .string(direction), "ratio": .number(moved ? 0.5 : 0.65),
                                 "first": .object(["type": .string("pane"), "pane_id": .string(moved && !swapped ? "b" : "a")]),
                                 "second": .object(["type": .string("pane"), "pane_id": .string(moved && !swapped ? "a" : "b")])])
            ])])
        default: throw HerdrError.message("Unexpected method: \(method)")
        }
    }
}
