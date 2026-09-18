import Foundation
import Combine
import HerdrCore

@main struct TabDragTests {
    @MainActor static func main() async throws {
        let suite = "dev.herdr.tab-drag-tests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let profile = DeviceProfile(name: "Tab fixture", kind: .local,
                                    socketPath: "/tmp/uherdr-tab-drag.sock", executable: "/tmp/herdr")
        defaults.set(["w": ["c", "a", "b"]], forKey: "tabOrder:\(profile.id.uuidString)")
        let client = TabFixtureClient()
        let store = SessionStore(profile: profile, defaults: defaults, client: client)
        await store.refresh()
        precondition(store.visibleTabs.map(\.id) == ["c", "a", "b"], "Restore the saved display order instead of the server order")
        let selectedTab = store.selectedTab, selectedPane = store.selectedPane
        let layout = store.currentLayout
        let source = store.tabDragPayload(for: "c")!
        precondition(store.moveTab(source, relativeTo: "b", after: true))
        precondition(store.visibleTabs.map(\.id) == ["a", "b", "c"], "Move the first tab to the end")
        precondition(store.moveTab(source, relativeTo: "a", after: false))
        precondition(store.visibleTabs.map(\.id) == ["c", "a", "b"], "Move the last tab to the front")
        precondition(store.moveTab(source, relativeTo: "a", after: true))
        precondition(store.visibleTabs.map(\.id) == ["a", "c", "b"], "Insert at a middle boundary")
        precondition(store.selectedTab == selectedTab && store.selectedPane == selectedPane && store.currentLayout == layout,
                     "Reordering must preserve terminal selection and layout")
        var notifications = 0
        let observation = store.objectWillChange.sink { notifications += 1 }
        precondition(store.moveTab(source, relativeTo: "b", after: false))
        precondition(notifications == 0, "Dropping at the current position must not publish")
        for _ in 0..<3 { await store.refresh() }
        precondition(store.visibleTabs.map(\.id) == ["a", "c", "b"], "Polling must preserve custom order")
        precondition(notifications == 0, "Unchanged polls must remain silent after reordering")
        observation.cancel()
        let restored = SessionStore(profile: profile, defaults: defaults, client: client)
        await restored.refresh()
        precondition(restored.visibleTabs.map(\.id) == ["a", "c", "b"], "Reordering must persist across launches")
        await client.setIDs(["a", "b", "d"])
        await store.refresh()
        precondition(store.visibleTabs.map(\.id) == ["a", "b", "d"], "Closed tabs disappear and new tabs append")
        precondition(!store.moveTab(source, relativeTo: "a", after: false), "Closed sources are rejected")
        let valid = store.tabDragPayload(for: "b")!
        for target in ["b", "missing", "other"] {
            precondition(!store.moveTab(valid, relativeTo: target, after: false), "Reject self, missing and cross-workspace targets")
        }
        let foreign = TabDragPayload(deviceID: UUID(), connectionGeneration: valid.connectionGeneration, workspaceID: "w", tabID: "b")
        let stale = TabDragPayload(deviceID: profile.id, connectionGeneration: UUID(), workspaceID: "w", tabID: "b")
        for invalid in [foreign, stale] {
            precondition(!store.moveTab(invalid, relativeTo: "a", after: false), "Reject foreign devices and stale connections")
        }
        store.selectedSpace = "w2"
        precondition(!store.moveTab(valid, relativeTo: "a", after: false), "Reject drags after changing workspace")
        precondition(store.visibleTabs.map(\.id) == ["other"], "Other workspace order is independent")
        store.selectedSpace = "w"
        store.busy = true
        precondition(!store.moveTab(valid, relativeTo: "a", after: false))
        store.busy = false
        precondition(store.moveTab(valid, relativeTo: "a", after: false))
        let otherProfile = DeviceProfile(name: "Other", kind: .local, socketPath: profile.socketPath, executable: profile.executable)
        let otherStore = SessionStore(profile: otherProfile, defaults: defaults, client: client)
        await otherStore.refresh()
        precondition(otherStore.visibleTabs.map(\.id) == ["a", "b", "d"], "Overlapping IDs on different devices must not share order")
        store.updateProfile(otherProfile)
        store.disconnect() // Stop the automatic polling started by updateProfile.
        store.selectedSpace = "w"
        store.tabs = otherStore.tabs
        precondition(store.visibleTabs.map(\.id) == ["a", "b", "d"], "Profile updates load the new device’s order")
        precondition(!store.moveTab(valid, relativeTo: "a", after: false), "Disconnected sessions reject drops")
        print("PASS: tab insertion, selection, persistence, polling, additions/removals, device/workspace isolation, and invalid drops")
    }
}

private actor TabFixtureClient: HerdrRequesting {
    var ids = ["a", "b", "c"]
    func setIDs(_ value: [String]) { ids = value }

    func request(_ method: String, params: [String: JSONValue], timeout: Int) async throws -> JSONValue {
        switch method {
        case "session.snapshot":
            let tabs = try (ids.map { ($0, "w") } + [("other", "w2")]).map { id, workspace in
                try parse("""
                {"tab_id":"\(id)","workspace_id":"\(workspace)","label":"\(id)","pane_count":1,"agent_status":"idle"}
                """)
            }
            return .object(["snapshot": .object([
                "version": .string("test"), "protocol": .number(20),
                "workspaces": .array(try ["w", "w2"].map { id in
                    try parse("""
                    {"workspace_id":"\(id)","label":"\(id)","active_tab_id":"\(id == "w" ? "a" : "other")","pane_count":3,"tab_count":3,"agent_status":"idle"}
                    """)
                }),
                "tabs": .array(tabs), "panes": .array([try parse("""
                {"pane_id":"p","terminal_id":"terminal","workspace_id":"w","tab_id":"a","agent_status":"idle"}
                """)]), "agents": .array([])
            ])])
        case "layout.export":
            return try parse("""
            {"layout":{"tab_id":"\(params["tab_id"]!.string!)","zoomed":false,"focused_pane_id":"p","root":{"type":"pane","pane_id":"p"}}}
            """)
        default: throw HerdrError.message("Unexpected request: \(method)")
        }
    }
}

private func parse(_ value: String) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: Data(value.utf8))
}
