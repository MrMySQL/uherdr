import Foundation
import HerdrCore

@main struct WorkspaceRootStoreTests {
    @MainActor static func main() async throws {
        let suiteName = "dev.herdr.workspace-root-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let profile = DeviceProfile(name: "Roots fixture", kind: .local,
                                    socketPath: "/tmp/uherdr-roots-fixture.sock", executable: "/tmp/herdr")

        // A space created here remembers the folder it was created in, and keeps it across launches.
        let client = RootsClient()
        let store = SessionStore(profile: profile, defaults: defaults, client: client)
        store.connected = true
        store.createSpace(label: "project", cwd: "/tmp/project")
        try await settle(store)
        precondition(store.selectedSpace == "w5")
        precondition(store.currentRoot == "/tmp/project", "createSpace must remember its folder")
        precondition(SessionStore(profile: profile, defaults: defaults, client: client).workspaceRoots.root(for: "w5") == "/tmp/project",
                     "The folder must survive a relaunch")

        // A space herdr no longer lists loses its folder on the next refresh.
        await client.setWorkspaces(["w1"])
        await store.refresh()
        precondition(store.workspaceRoots.root(for: "w5") == nil, "A closed space must not keep its folder")

        // A snapshot taken before a folder was remembered must not prune it.
        await client.setWorkspaces(["w1"], delay: .milliseconds(200))
        let slow = Task { await store.refresh() }
        try await Task.sleep(for: .milliseconds(50))
        store.setRoot("/tmp/late", for: "w7")
        await slow.value
        precondition(store.workspaceRoots.root(for: "w7") == "/tmp/late", "A stale snapshot pruned a newly remembered folder")
        await client.setWorkspaces(["w1"])
        await store.refresh()
        precondition(store.workspaceRoots.root(for: "w7") == nil, "The next current snapshot still prunes")

        // Two devices keep separate folders for the same workspace ID.
        let other = DeviceProfile(name: "Other", kind: .local, socketPath: "/tmp/uherdr-roots-other.sock", executable: "/tmp/herdr")
        let a = SessionStore(profile: profile, defaults: defaults, client: client)
        let b = SessionStore(profile: other, defaults: defaults, client: client)
        a.setRoot("/a", for: "w1")
        b.setRoot("/b", for: "w1")
        precondition(SessionStore(profile: profile, defaults: defaults, client: client).workspaceRoots.root(for: "w1") == "/a")
        precondition(SessionStore(profile: other, defaults: defaults, client: client).workspaceRoots.root(for: "w1") == "/b")
        print("PASS: space folders: remembered on create, kept across launches, pruned when closed, safe from stale snapshots, per device")
    }

    @MainActor static func settle(_ store: SessionStore) async throws {
        try await Task.sleep(for: .milliseconds(30))
        for _ in 0..<100 {
            if !store.busy { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        fatalError("Request did not finish")
    }
}

private actor RootsClient: HerdrRequesting {
    var workspaceIDs = ["w1", "w5"]
    var snapshotDelay: Duration = .zero

    func setWorkspaces(_ ids: [String], delay: Duration = .zero) {
        workspaceIDs = ids
        snapshotDelay = delay
    }

    static func workspace(_ id: String) -> JSONValue {
        .object(["workspace_id": .string(id), "label": .string(id), "active_tab_id": .string("\(id):t1"),
                 "pane_count": .number(1), "tab_count": .number(1), "agent_status": .string("unknown")])
    }

    func request(_ method: String, params: [String: JSONValue], timeout: Int) async throws -> JSONValue {
        switch method {
        case "workspace.create":
            return .object(["workspace": Self.workspace("w5"), "tab": .object(["tab_id": .string("w5:t1")]),
                            "root_pane": .object(["pane_id": .string("w5:p1")])])
        case "session.snapshot":
            let ids = workspaceIDs
            if snapshotDelay > .zero { try await Task.sleep(for: snapshotDelay) }
            return .object(["snapshot": .object([
                "version": .string("test"), "protocol": .number(20),
                "workspaces": .array(ids.map(Self.workspace)), "tabs": .array([]),
                "panes": .array([]), "agents": .array([])
            ])])
        default: throw HerdrError.message("Unexpected request: \(method)")
        }
    }
}
