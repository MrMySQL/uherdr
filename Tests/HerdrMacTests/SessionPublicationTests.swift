import Foundation
import Combine
import HerdrCore

@main struct SessionPublicationTests {
    @MainActor static func main() async throws {
        for empty in [false, true] {
            let suite = "dev.herdr.publication-tests.\(UUID())"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let client = FixtureClient(empty: empty)
            let store = SessionStore(profile: DeviceProfile(name: "Fixture", kind: .local,
                socketPath: "/tmp/nonexistent-probe.sock", executable: "/tmp/unused"), defaults: defaults, client: client)
            await store.refresh()
            var notifications = 0
            let observation = store.objectWillChange.sink { notifications += 1 }
            defer { observation.cancel() }
            for _ in 0..<10 { await store.refresh() }
            guard notifications == 0 else {
                fatalError("Unchanged \(empty ? "empty" : "populated") polls emitted \(notifications) notifications")
            }
            await client.setVersion("changed")
            await store.refresh()
            guard store.version == "changed", notifications == 1 else {
                fatalError("A changed version must publish exactly once")
            }
            await client.setFailing(true)
            await store.refresh()
            guard !store.connected, store.connectionError != nil else {
                fatalError("Connection failure was not published")
            }
            await client.setFailing(false)
            await store.refresh()
            guard store.connected, !store.connecting, store.connectionError == nil else {
                fatalError("Connection recovery was not published")
            }
        }
        print("PASS: unchanged populated/empty polls stay silent; version, failure and recovery publish")
    }
}

private actor FixtureClient: HerdrRequesting {
    let empty: Bool
    var version = "test"
    var failing = false
    init(empty: Bool) { self.empty = empty }
    func setVersion(_ value: String) { version = value }
    func setFailing(_ value: Bool) { failing = value }

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
        if failing { throw HerdrError.message("Fixture failure") }
        switch method {
        case "session.snapshot":
            return .object(["snapshot": .object([
                "version": .string(version), "protocol": .number(20),
                "workspaces": .array(empty ? [] : [Self.workspace]),
                "tabs": .array(empty ? [] : [Self.tab]),
                "panes": .array(empty ? [] : [Self.pane]), "agents": .array([])
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
