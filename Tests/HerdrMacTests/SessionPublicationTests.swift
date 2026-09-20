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
                socketPath: "/tmp/nonexistent-probe.sock", executable: "/tmp/unused"), defaults: defaults, client: client, powerReader: { _ in nil })
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
        try await resizeDuringPoll()
        try await queuedResizes()
    }

    @MainActor static func resizeDuringPoll() async throws {
        for pollStartsDuringCommit in [false, true] {
            let suite = "dev.herdr.resize-poll-tests.\(UUID())"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let client = ResizePollClient()
            let store = SessionStore(profile: DeviceProfile(name: "Resize fixture", kind: .local,
                socketPath: "/tmp/resize-poll.sock", executable: "/tmp/unused"), defaults: defaults, client: client, powerReader: { _ in nil })
            await store.refresh()
            await client.prepareRace(holdCommit: pollStartsDuringCommit)
            if pollStartsDuringCommit {
                store.setRatio(tabID: "new-tab", path: [], ratio: 0.75)
                for _ in 0..<100 {
                    if await client.commitPaused { break }
                    try await Task.sleep(for: .milliseconds(10))
                }
                guard await client.commitPaused else { throw HerdrError.message("Resize request did not start") }
            }
            var poll: Task<Void, Never>?
            if pollStartsDuringCommit {
                var finished = false
                let attempt = Task { await store.refresh(); finished = true }
                for _ in 0..<100 {
                    let paused = await client.pollPaused
                    if finished || paused { break }
                    try await Task.sleep(for: .milliseconds(10))
                }
                let paused = await client.pollPaused
                let suppressed = finished && !paused
                await client.releasePoll()
                await attempt.value
                guard suppressed else { throw HerdrError.message("Polling must wait for pending resize commits") }
                await client.releaseCommit()
            } else {
                poll = Task { await store.refresh() }
                for _ in 0..<100 {
                    if await client.pollPaused { break }
                    try await Task.sleep(for: .milliseconds(10))
                }
                guard await client.pollPaused else { throw HerdrError.message("Poll did not reach layout export") }
                store.setRatio(tabID: "new-tab", path: [], ratio: 0.75)
            }
            let expected = LayoutNode.split(.right, 0.75, .pane("new-pane"), .pane("second-pane"))
            for _ in 0..<100 {
                if store.currentLayout?.root == expected { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let committedWhilePolling = store.currentLayout?.root == expected
            await client.releasePoll()
            await poll?.value
            guard committedWhilePolling, store.currentLayout?.root == expected else {
                throw HerdrError.message("Resize response must publish immediately and survive an older in-flight layout export")
            }
        }
        print("PASS: resize commits publish immediately, discard stale exports, and hold new polls until completion")
    }

    @MainActor static func queuedResizes() async throws {
        let suite = "dev.herdr.resize-queue-tests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let client = ResizePollClient()
        let store = SessionStore(profile: DeviceProfile(name: "Resize queue", kind: .local,
            socketPath: "/tmp/resize-queue.sock", executable: "/tmp/unused"), defaults: defaults, client: client, powerReader: { _ in nil })
        await store.refresh()
        guard store.paneDragPayload(for: "new-pane") != nil else { throw HerdrError.message("Fixture pane must initially allow dragging") }
        var published: [LayoutNode] = []
        let observation = store.$layouts.dropFirst().sink { if let root = $0["new-tab"]?.root { published.append(root) } }
        defer { observation.cancel() }
        await client.prepareRace(holdCommit: true)
        store.setRatio(tabID: "new-tab", path: [], ratio: 0.75)
        store.setRatio(tabID: "new-tab", path: [], ratio: 0.5)
        guard store.paneDragPayload(for: "new-pane") == nil else {
            throw HerdrError.message("Pane moves must not change split paths while resize commits are queued")
        }
        for _ in 0..<100 {
            if await client.commitPaused { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard await client.commitPaused else { throw HerdrError.message("Queued resize did not start") }
        await client.releaseCommit()
        for _ in 0..<100 {
            if await client.committedRatios.count == 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard await client.committedRatios == [0.75, 0.5] else {
            throw HerdrError.message("Resize requests must commit in pointer-release order")
        }
        guard !published.contains(.split(.right, 0.75, .pane("new-pane"), .pane("second-pane"))) else {
            throw HerdrError.message("An intermediate queued resize must not replace the latest local size")
        }
        await client.setExternalRatio(0.4)
        let external = LayoutNode.split(.right, 0.4, .pane("new-pane"), .pane("second-pane"))
        for _ in 0..<100 {
            await store.refresh()
            if store.currentLayout?.root == external { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard store.currentLayout?.root == external else {
            throw HerdrError.message("Returning to the original ratio must not block later server layout changes")
        }
        guard store.paneDragPayload(for: "new-pane") != nil else { throw HerdrError.message("Pane moves must resume after resize commits finish") }
        print("PASS: queued resizes retain the final ratio without suppressing later server changes")
    }
}

private actor ResizePollClient: HerdrRequesting {
    private let snapshotClient = FixtureClient(empty: false)
    private var ratio = 0.5
    private var holdPoll = false
    private var holdCommit = false
    private var pollContinuation: CheckedContinuation<Void, Never>?
    private var commitContinuation: CheckedContinuation<Void, Never>?
    private(set) var committedRatios: [Double] = []
    var pollPaused: Bool { pollContinuation != nil }
    var commitPaused: Bool { commitContinuation != nil }

    func prepareRace(holdCommit: Bool) { ratio = 0.6; holdPoll = true; self.holdCommit = holdCommit }
    func releasePoll() { pollContinuation?.resume(); pollContinuation = nil }
    func releaseCommit() { commitContinuation?.resume(); commitContinuation = nil }
    func setExternalRatio(_ value: Double) { ratio = value; holdPoll = false }

    func request(_ method: String, params: [String: JSONValue], timeout: Int) async throws -> JSONValue {
        if method == "session.snapshot" { return try await snapshotClient.request(method, params: params, timeout: timeout) }
        if method == "layout.set_split_ratio" {
            if holdCommit { holdCommit = false; await withCheckedContinuation { commitContinuation = $0 } }
            guard case .number(let value) = params["ratio"] else { throw HerdrError.message("Missing resize ratio") }
            ratio = value
            committedRatios.append(value)
        }
        let result: JSONValue = .object(["layout": .object([
            "tab_id": .string("new-tab"), "zoomed": .bool(false), "focused_pane_id": .string("new-pane"),
            "root": .object(["type": .string("split"), "direction": .string("right"), "ratio": .number(ratio),
                "first": .object(["type": .string("pane"), "pane_id": .string("new-pane")]),
                "second": .object(["type": .string("pane"), "pane_id": .string("second-pane")])])
        ])])
        if method == "layout.export", holdPoll {
            holdPoll = false
            await withCheckedContinuation { pollContinuation = $0 }
        }
        return result
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
