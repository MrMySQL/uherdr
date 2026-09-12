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
        let singlePane = SessionStore(profile: profile, defaults: defaults, client: DockClient(failure: ""))
        await singlePane.refresh()
        singlePane.layouts["t"] = try JSONDecoder().decode(TabLayout.self, from: Data(#"{"tab_id":"t","zoomed":false,"focused_pane_id":"a","root":{"type":"pane","pane_id":"a"}}"#.utf8))
        precondition(singlePane.paneDragPayload(for: "a") != nil, "A tab’s only pane must be draggable to another tab")
        singlePane.disconnect()
        try await testTabTransfers(profile: profile, defaults: defaults)
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

    @MainActor static func testTabTransfers(profile: DeviceProfile, defaults: UserDefaults) async throws {
        for failure in ["", "dock", "zoomed_tab"] {
            let client = DockClient(failure: failure)
            let store = SessionStore(profile: profile, defaults: defaults, client: client)
            store.selectedTab = "t"
            await store.refresh()
            let original = store.currentLayout
            let source = store.paneDragPayload(for: "a")!
            store.tabs.append(try JSONDecoder().decode(HerdrCore.Tab.self, from: Data(#"{"tab_id":"foreign-space-tab","workspace_id":"another-space","label":"Elsewhere","pane_count":1,"agent_status":"unknown"}"#.utf8)))
            for tabID in ["t", "missing", "foreign-space-tab"] {
                precondition(!store.movePane(source, toTab: tabID))
            }
            store.sheet = .tab
            precondition(!store.movePane(source, toTab: "other-tab"))
            store.sheet = nil
            store.pendingClose = ResourceTarget(kind: "pane", id: "a", label: "A")
            precondition(!store.movePane(source, toTab: "other-tab"))
            store.pendingClose = nil
            store.layouts["t"] = try JSONDecoder().decode(TabLayout.self, from: Data(#"{"tab_id":"t","zoomed":true,"focused_pane_id":"a","root":{"type":"pane","pane_id":"a"}}"#.utf8))
            precondition(!store.movePane(source, toTab: "other-tab"), "Restore the split layout before moving a zoomed pane")
            store.layouts["t"] = original
            for invalid in [
                PaneDragPayload(deviceID: UUID(), connectionGeneration: source.connectionGeneration, tabID: "t", paneID: "a"),
                PaneDragPayload(deviceID: profile.id, connectionGeneration: UUID(), tabID: "t", paneID: "a"),
                PaneDragPayload(deviceID: profile.id, connectionGeneration: source.connectionGeneration, tabID: "wrong", paneID: "a"),
                PaneDragPayload(deviceID: profile.id, connectionGeneration: source.connectionGeneration, tabID: "t", paneID: "missing")
            ] {
                precondition(!store.movePane(invalid, toTab: "other-tab"))
            }
            store.busy = true
            precondition(!store.movePane(source, toTab: "other-tab"))
            store.busy = false
            precondition(store.movePane(source, toTab: "other-tab"))
            store.busy = false
            precondition(!store.movePane(source, toTab: "other-tab"), "The move lock prevents duplicate transfers")
            store.busy = true
            await store.refresh()
            try await settle(store)
            let calls = await client.calls
            precondition(calls.count == 1 && calls[0].0 == "pane.move", "Cross-tab transfers must not park or close terminals")
            precondition(calls[0].1 == [
                "pane_id": .string("a"), "focus": .bool(true),
                "destination": .object(["type": .string("tab"), "tab_id": .string("other-tab"),
                                        "split": .string("right"), "ratio": .number(0.5)])
            ])
            if failure.isEmpty {
                precondition(store.operationError == nil)
                precondition(store.selectedTab == "other-tab" && store.selectedPane == "a")
                precondition(store.currentLayout?.root == .split(.right, 0.5, .pane("other"), .pane("a")))
                precondition(store.layouts["t"]?.root == .pane("b"), "Refresh the hidden source tree after collapse")
                precondition(store.panes.first { $0.id == "a" }?.terminalID == "ta")
            } else {
                precondition(store.operationError != nil)
                precondition(store.selectedTab == "t" && store.currentLayout == original)
            }
            store.disconnect()
            precondition(!store.movePane(source, toTab: "other-tab"))
        }
        let client = DockClient(failure: "")
        let store = SessionStore(profile: profile, defaults: defaults, client: client)
        store.selectedTab = "t"
        await store.refresh()
        precondition(store.movePane(store.paneDragPayload(for: "a")!, toTab: "other-tab"))
        store.selectTab(store.currentTab!)
        try await settle(store)
        precondition(store.selectedTab == "t", "A pending move must not override a newer tab selection")
        store.disconnect()
        print("PASS: tab transfers, preserved terminal identity, both cached layouts, invalid/duplicate drops, failures, and selection races")
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
        try await testLiveTabTransfers(client: client, socket: socket, defaults: defaults)
    }

    @MainActor static func testLiveTabTransfers(client: HerdrClient, socket: String, defaults: UserDefaults) async throws {
        for splitSource in [false, true] {
            let created = try await client.request("workspace.create", params: ["label": .string("Tab move test"), "cwd": .string("/tmp"), "focus": .bool(true)])
            let source = try created["root_pane"].decode(Pane.self)
            do {
                if splitSource {
                    _ = try await client.request("pane.split", params: ["target_pane_id": .string(source.id), "direction": .string("down")])
                }
                let target = try await client.request("tab.create", params: ["workspace_id": .string(source.workspaceID), "label": .string("Destination"), "focus": .bool(false)])
                let targetPane = try target["root_pane"].decode(Pane.self)
                _ = try await client.request("pane.send_input", params: ["pane_id": .string(source.id), "text": .string("UHERDR_MOVE_TOKEN=kept"), "keys": .array([.string("enter")])])
                let profile = DeviceProfile(name: "Tab move live", kind: .local, socketPath: socket, executable: "/tmp/herdr")
                let store = SessionStore(profile: profile, defaults: defaults, client: client)
                await store.refresh()
                store.layouts[targetPane.tabID] = try await client.request("layout.export", params: ["tab_id": .string(targetPane.tabID)])["layout"].decode(TabLayout.self)
                guard let payload = store.paneDragPayload(for: source.id) else { throw HerdrError.message("Source pane is not draggable") }
                let zoomSibling = try await client.request("pane.split", params: ["target_pane_id": .string(targetPane.id), "direction": .string("down")])["pane"].decode(Pane.self)
                let zoomResult = try await client.request("pane.zoom", params: ["pane_id": .string(targetPane.id), "mode": .string("toggle")])
                precondition(zoomResult["zoom"]["zoomed"] == .bool(true))
                precondition(store.movePane(payload, toTab: targetPane.tabID))
                try await settle(store)
                precondition(store.operationError != nil && store.selectedTab == source.tabID,
                             "A zoomed destination must report that Herdr rejected the move and keep the source selected")
                _ = try await client.request("pane.zoom", params: ["pane_id": .string(targetPane.id), "mode": .string("toggle")])
                _ = try await client.request("pane.close", params: ["pane_id": .string(zoomSibling.id)])
                precondition(store.movePane(payload, toTab: targetPane.tabID))
                try await settle(store)
                if let error = store.operationError { throw HerdrError.message(error) }
                precondition(store.selectedTab == targetPane.tabID && store.selectedPane == source.id)
                precondition(store.currentLayout?.root == .split(.right, 0.5, .pane(targetPane.id), .pane(source.id)))
                precondition(store.panes.first { $0.id == source.id }?.terminalID == source.terminalID)
                precondition(store.panes.first { $0.id == source.id }?.tabID == targetPane.tabID)
                if splitSource {
                    precondition(store.layouts[source.tabID]?.root.paneIDs.count == 1)
                    precondition(store.layouts[source.tabID]?.root.paneIDs.contains(source.id) == false)
                } else {
                    precondition(!store.tabs.contains { $0.id == source.tabID }, "Moving the last pane removes the empty tab")
                    precondition(store.layouts[source.tabID] == nil)
                }
                _ = try await client.request("pane.send_input", params: ["pane_id": .string(source.id), "text": .string("printf 'tab-move-%s\\n' \"$UHERDR_MOVE_TOKEN\""), "keys": .array([.string("enter")])])
                var keptShell = false
                for _ in 0..<40 {
                    let output = try await client.request("pane.read", params: ["pane_id": .string(source.id), "source": .string("recent"), "lines": .number(40)])
                    if output["read"]["text"].string?.contains("tab-move-kept") == true { keptShell = true; break }
                    try await Task.sleep(for: .milliseconds(100))
                }
                precondition(keptShell, "The original shell and its environment must survive the transfer")
                store.disconnect()
                _ = try await client.request("workspace.close", params: ["workspace_id": .string(source.workspaceID)])
            } catch {
                _ = try? await client.request("workspace.close", params: ["workspace_id": .string(source.workspaceID)])
                throw error
            }
        }
        print("PASS: live tab transfers, last-pane tab removal, cached source collapse, focus, and preserved shell environment")
    }
}

private actor DockClient: HerdrRequesting {
    let failure: String
    var snapshotCount = 0
    var parked = false
    var moved = false
    var swapped = false
    var movedToOtherTab = false
    var direction = "right"
    var calls: [(String, [String: JSONValue])] = []
    init(failure: String) { self.failure = failure }
    func request(_ method: String, params: [String: JSONValue], timeout: Int) async throws -> JSONValue {
        switch method {
        case "tab.focus": return .object(["type": .string("ok")])
        case "pane.move", "pane.swap":
            calls.append((method, params))
            let stage = method == "pane.swap" ? "order" : params["destination"]?["type"] == .string("new_tab") ? "park" : "dock"
            if stage == failure { throw HerdrError.message("Fixture failure: \(stage)") }
            if params["destination"]?["tab_id"] == .string("other-tab") {
                if failure == "zoomed_tab" {
                    return .object(["type": .string("pane_move"), "move_result": .object([
                        "changed": .bool(false), "reason": .string("zoomed_tab")
                    ])])
                }
                movedToOtherTab = true
                return .object(["type": .string("pane_move"), "move_result": .object(["changed": .bool(true), "reason": .null])])
            }
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
            if movedToOtherTab {
                guard case .object(var snapshot) = value["snapshot"],
                      case .array(let panes) = snapshot["panes"] else { fatalError("Bad fixture") }
                snapshot["panes"] = .array(panes.map { pane in
                    guard pane["pane_id"] == .string("a"), case .object(var object) = pane else { return pane }
                    object["tab_id"] = .string("other-tab")
                    return .object(object)
                })
                return .object(["snapshot": .object(snapshot)])
            }
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
            if movedToOtherTab || params["tab_id"] == .string("other-tab") {
                let tabID = params["tab_id"]!.string!
                let root: JSONValue
                if tabID == "t" { root = .object(["type": .string("pane"), "pane_id": .string("b")]) }
                else if movedToOtherTab {
                    root = .object(["type": .string("split"), "direction": .string("right"), "ratio": .number(0.5),
                                    "first": .object(["type": .string("pane"), "pane_id": .string("other")]),
                                    "second": .object(["type": .string("pane"), "pane_id": .string("a")])])
                } else { root = .object(["type": .string("pane"), "pane_id": .string("other")]) }
                return .object(["layout": .object(["tab_id": .string(tabID), "zoomed": .bool(false), "root": root])])
            }
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
