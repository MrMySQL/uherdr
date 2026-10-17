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
        // Renaming a device keeps its folders; pointing it at another session drops
        // them, because that session reuses the same space ids for other spaces.
        var renamed = profile
        renamed.name = "Renamed"
        a.updateProfile(renamed)
        precondition(a.workspaceRoots.root(for: "w1") == "/a", "A rename must keep the device's folders")
        var moved = renamed
        moved.socketPath = "/tmp/uherdr-roots-elsewhere.sock"
        a.updateProfile(moved)
        precondition(a.workspaceRoots.root(for: "w1") == nil, "Another session must not inherit the old one's folders")
        precondition(SessionStore(profile: moved, defaults: defaults, client: client).workspaceRoots.root(for: "w1") == nil)
        a.disconnect()

        // A typed `~/…` folder is remembered as herdr resolved it, or not at all.
        let typed = RootsClient()
        let typedStore = SessionStore(profile: DeviceProfile(name: "Typed", kind: .local, socketPath: "/tmp/uherdr-typed.sock", executable: "/tmp/herdr"),
                                      defaults: defaults, client: typed)
        typedStore.connected = true
        await typed.setCreatedPaneFolder("/Users/me/project")
        typedStore.createSpace(label: "project", cwd: "~/project")
        try await settle(typedStore)
        precondition(typedStore.workspaceRoots.root(for: "w5") == "/Users/me/project", "The new pane's folder is the space's folder")
        await typed.setCreatedPaneFolder(nil)
        typedStore.setRoot("/tmp/reset", for: "w5")
        typedStore.createSpace(label: "project", cwd: "project")
        try await settle(typedStore)
        precondition(typedStore.workspaceRoots.root(for: "w5") == "/tmp/reset", "A relative folder herdr didn't resolve is not remembered")
        // Spaces with no folder take one from their first terminal: the Git repository
        // around it, never the home folder; a chosen folder always wins.
        let fm = FileManager.default
        let base = PathBoundary.canonical(NSTemporaryDirectory())! + "/uherdr-guess-store-\(UUID().uuidString)"
        defer { try? fm.removeItem(atPath: base) }
        try fm.createDirectory(atPath: base + "/app/Sources", withIntermediateDirectories: true)
        let git = Process()
        git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        git.arguments = ["-C", base + "/app", "init", "-q"]
        git.standardOutput = FileHandle.nullDevice
        try git.run(); git.waitUntilExit()
        let guessing = RootsClient()
        await guessing.setWorkspaces(["w1", "w2", "w3"])
        await guessing.setTerminalFolders(["w1": base + "/app/Sources", "w2": NSHomeDirectory(), "w3": base + "/app"])
        let guessed = SessionStore(profile: DeviceProfile(name: "Guess", kind: .local, socketPath: "/tmp/uherdr-guess.sock", executable: "/tmp/herdr"),
                                   defaults: defaults, client: guessing)
        guessed.setRoot("/chosen", for: "w3")
        guessed.connected = true
        await guessed.refresh()
        for _ in 0..<100 where guessed.workspaceRoots.root(for: "w1") == nil { try await Task.sleep(for: .milliseconds(20)) }
        precondition(guessed.workspaceRoots.root(for: "w1") == base + "/app", "A space takes the repository around its first terminal")
        try await Task.sleep(for: .milliseconds(200))
        precondition(guessed.workspaceRoots.root(for: "w2") == nil, "A terminal in the home folder gives no folder; the sidebar asks")
        precondition(guessed.workspaceRoots.root(for: "w3") == "/chosen", "A chosen folder is never replaced")
        print("PASS: space folders: remembered on create (as herdr resolved it), kept across launches, forgotten when the device points elsewhere, pruned when closed, safe from stale snapshots, per device, guessed from the first terminal (never home, never over a choice)")
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
    /// The starting folder of each space's first terminal (no entry: no terminals listed).
    var terminalFolders: [String: String] = [:]
    /// The folder herdr reports for a new space's first pane.
    var createdPaneFolder: String?

    func setWorkspaces(_ ids: [String], delay: Duration = .zero) {
        workspaceIDs = ids
        snapshotDelay = delay
    }

    func setTerminalFolders(_ folders: [String: String]) { terminalFolders = folders }
    func setCreatedPaneFolder(_ folder: String?) { createdPaneFolder = folder }

    static func workspace(_ id: String) -> JSONValue {
        .object(["workspace_id": .string(id), "label": .string(id), "active_tab_id": .string("\(id):t1"),
                 "pane_count": .number(1), "tab_count": .number(1), "agent_status": .string("unknown")])
    }

    func request(_ method: String, params: [String: JSONValue], timeout: Int) async throws -> JSONValue {
        switch method {
        case "workspace.create":
            return .object(["workspace": Self.workspace("w5"), "tab": .object(["tab_id": .string("w5:t1")]),
                            "root_pane": .object(["pane_id": .string("w5:p1")].merging(createdPaneFolder.map { ["cwd": .string($0)] } ?? [:]) { $1 })])
        case "session.snapshot":
            let ids = workspaceIDs
            if snapshotDelay > .zero { try await Task.sleep(for: snapshotDelay) }
            return .object(["snapshot": .object([
                "version": .string("test"), "protocol": .number(20),
                "workspaces": .array(ids.map(Self.workspace)),
                "tabs": .array(ids.filter { terminalFolders[$0] != nil }.map { id in
                    .object(["tab_id": .string("\(id):t1"), "workspace_id": .string(id), "label": .string("1"),
                             "pane_count": .number(1), "agent_status": .string("unknown")])
                }),
                "panes": .array(ids.compactMap { id in terminalFolders[id].map { folder in
                    .object(["pane_id": .string("\(id):p1"), "terminal_id": .string("term-\(id)"), "workspace_id": .string(id),
                             "tab_id": .string("\(id):t1"), "cwd": .string(folder), "agent_status": .string("unknown")])
                } }),
                "agents": .array([])
            ])])
        default: throw HerdrError.message("Unexpected request: \(method)")
        }
    }
}
