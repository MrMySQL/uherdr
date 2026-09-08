import Foundation
import HerdrCore

@main struct AgentWorktreeTests {
    @MainActor static func main() async throws {
        let suiteName = "dev.herdr.agent-worktree-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let profile = DeviceProfile(name: "Agent fixture", kind: .local,
                                    socketPath: "/tmp/uherdr-agent-worktree-fixture.sock", executable: "/tmp/herdr")
        for failure in ["", "worktree.create", "agent.start"] {
            let client = FixtureClient(failure: failure)
            let store = SessionStore(profile: profile, defaults: defaults, client: client)
            store.connected = true
            store.panes = [try FixtureClient.source.decode(Pane.self)]
            store.selectedSpace = "other-space"
            store.selectedPane = "other-pane"
            store.startAgent(paneID: "source-pane", kind: "codex", name: "test-agent")
            try await settle(store)
            let calls = await client.calls
            guard let first = calls.first else { fatalError("No launch request") }
            precondition(first.method == "worktree.create", "Must create a worktree before starting the agent")
            precondition(first.params["cwd"] == .string("/tmp/project/subdir"), "Use the requested pane's foreground directory")
            precondition(first.params["workspace_id"] == nil, "Do not combine cwd and workspace_id")
            precondition(first.params["focus"] == .bool(true))
            let launches = calls.filter { $0.method == "agent.start" }
            if failure == "worktree.create" {
                precondition(launches.isEmpty, "Creation failure must not launch in the original pane")
                precondition(store.selectedPane == "other-pane")
            } else {
                precondition(launches.count == 1)
                precondition(launches[0].params["pane_id"] == .string("new-pane"))
                precondition(launches[0].params["kind"] == .string("codex"))
                precondition(launches[0].params["name"] == .string("test-agent"))
                precondition(store.selectedSpace == "new-space")
                precondition(store.selectedTab == "new-tab")
                precondition(store.selectedPane == "new-pane")
                precondition(store.workspaces.contains { $0.id == "new-space" }, "Refresh the created space even if agent launch fails")
            }
            precondition((store.operationError != nil) == !failure.isEmpty)
            precondition(!store.busy)
        }
        let client = FixtureClient(failure: "")
        let store = SessionStore(profile: profile, defaults: defaults, client: client)
        store.connected = true
        store.startAgent(paneID: "missing-pane", kind: "claude", name: "test-agent")
        try await settle(store)
        let calls = await client.calls
        precondition(calls.isEmpty, "Never fall back to the runtime's active workspace for a missing pane")
        precondition(store.operationError != nil)
        let cancelledClient = FixtureClient(failure: "")
        let cancelled = SessionStore(profile: profile, defaults: defaults, client: cancelledClient)
        cancelled.connected = true
        cancelled.panes = [try FixtureClient.source.decode(Pane.self)]
        cancelled.startAgent(paneID: "source-pane", kind: "codex", name: "cancelled-agent")
        cancelled.disconnect()
        try await settle(cancelled)
        let cancelledCalls = await cancelledClient.calls
        precondition(cancelledCalls.isEmpty, "A queued agent launch must not create a worktree after disconnect")
        precondition(!cancelled.busy)
        print("PASS: worktree agent launch, source pane targeting, creation/launch failures, and missing pane")
    }

    @MainActor static func settle(_ store: SessionStore) async throws {
        try await Task.sleep(for: .milliseconds(30))
        for _ in 0..<100 {
            if !store.busy { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        fatalError("Launch did not finish")
    }
}

private actor FixtureClient: HerdrRequesting {
    struct Call: Sendable {
        let method: String
        let params: [String: JSONValue]
    }
    let failure: String
    var calls: [Call] = []
    init(failure: String) { self.failure = failure }

    static let source: JSONValue = .object([
        "pane_id": .string("source-pane"), "terminal_id": .string("source-terminal"),
        "workspace_id": .string("source-space"), "tab_id": .string("source-tab"),
        "cwd": .string("/tmp/project"), "foreground_cwd": .string("/tmp/project/subdir"),
        "agent_status": .string("unknown")
    ])
    static let workspace: JSONValue = .object([
        "workspace_id": .string("new-space"), "label": .string("test-agent"),
        "active_tab_id": .string("new-tab"), "pane_count": .number(1),
        "tab_count": .number(1), "agent_status": .string("unknown")
    ])
    static let tab: JSONValue = .object([
        "tab_id": .string("new-tab"), "workspace_id": .string("new-space"),
        "label": .string("Terminal"), "pane_count": .number(1), "agent_status": .string("unknown")
    ])
    static let pane: JSONValue = .object([
        "pane_id": .string("new-pane"), "terminal_id": .string("new-terminal"),
        "workspace_id": .string("new-space"), "tab_id": .string("new-tab"),
        "cwd": .string("/tmp/worktree"), "agent_status": .string("unknown")
    ])

    func request(_ method: String, params: [String: JSONValue], timeout: Int) async throws -> JSONValue {
        calls.append(Call(method: method, params: params))
        if method == failure { throw HerdrError.message("Fixture failure: \(method)") }
        switch method {
        case "worktree.create":
            return .object(["type": .string("worktree_created"), "workspace": Self.workspace, "tab": Self.tab,
                            "root_pane": Self.pane, "worktree": .object([:])])
        case "agent.start": return .object(["type": .string("ok")])
        case "session.snapshot":
            return .object(["snapshot": .object([
                "version": .string("test"), "protocol": .number(20),
                "workspaces": .array([Self.workspace]), "tabs": .array([Self.tab]),
                "panes": .array([Self.pane]), "agents": .array([])
            ])])
        case "layout.export":
            return .object(["layout": .object([
                "tab_id": .string("new-tab"), "zoomed": .bool(false),
                "focused_pane_id": .string("new-pane"),
                "root": .object(["type": .string("pane"), "pane_id": .string("new-pane")])
            ])])
        default: throw HerdrError.message("Unexpected request: \(method)")
        }
    }
}
