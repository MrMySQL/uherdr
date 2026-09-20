import Foundation
import HerdrCore

@main struct DevicePowerPollingTests {
    @MainActor static func main() async throws {
        let suite = "dev.herdr.power-tests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let profile = DeviceProfile(name: "Power test", kind: .local, socketPath: "/tmp/power-test.sock", executable: "/tmp/unused")
        let client = PowerSnapshotClient()
        var reading: DevicePowerStatus? = .battery(percentage: 42, externallyPowered: false)
        var queryCount = 0
        var failPower = false
        var pending: CheckedContinuation<DevicePowerStatus?, Error>?
        var delay = false
        let store = SessionStore(profile: profile, defaults: defaults, client: client, powerReader: { requestedProfile in
            precondition(requestedProfile.id == profile.id)
            queryCount += 1
            if delay { return try await withCheckedThrowingContinuation { pending = $0 } }
            if failPower { throw HerdrError.message("Power query failed") }
            return reading
        })
        defer { store.disconnect() }
        await store.refresh()
        try await wait { store.powerStatus == reading }
        precondition(queryCount == 1, "Connection must query immediately")
        for _ in 0..<5 { await store.refresh() }
        precondition(queryCount == 1, "Workspace polls must not query power repeatedly")
        let future = Date().addingTimeInterval(61)
        reading = .battery(percentage: 41, externallyPowered: false)
        store.refreshPowerIfNeeded(now: future)
        try await wait { store.powerStatus == reading }
        precondition(queryCount == 2)
        store.refreshPowerIfNeeded(now: future.addingTimeInterval(59))
        precondition(queryCount == 2, "Do not query before the next minute")
        reading = .mains
        store.refreshPowerIfNeeded(now: future.addingTimeInterval(60))
        try await wait { store.powerStatus == .mains }
        failPower = true
        store.refreshPowerIfNeeded(now: future.addingTimeInterval(120))
        try await wait { store.powerStatus == nil }
        precondition(store.connected && store.connectionError == nil, "Power failures must not disconnect the device")
        failPower = false
        await client.setFailing(true)
        await store.refresh()
        precondition(!store.connected && store.powerStatus == nil)
        await client.setFailing(false)
        await store.refresh()
        try await wait { store.powerStatus == .mains }
        precondition(queryCount == 5, "Automatic recovery must refresh immediately")

        delay = true
        store.refreshPowerIfNeeded(now: future.addingTimeInterval(180))
        try await wait { pending != nil }
        store.disconnect()
        precondition(store.powerStatus == nil)
        delay = false
        reading = .battery(percentage: 88, externallyPowered: true)
        store.reconnect()
        try await wait { store.powerStatus == reading }
        pending?.resume(returning: .battery(percentage: 1, externallyPowered: false))
        pending = nil
        for _ in 0..<10 { await Task.yield() }
        precondition(store.powerStatus == reading, "An old query must not overwrite a reconnected device")
        store.disconnect()
        let count = queryCount
        store.refreshPowerIfNeeded(now: future.addingTimeInterval(240))
        for _ in 0..<10 { await Task.yield() }
        precondition(store.powerStatus == nil && queryCount == count, "Disconnected devices must stop querying")
        print("PASS: immediate and minute refresh, throttling, failure isolation, recovery, reconnect, stale-result rejection and disconnect")
    }

    @MainActor static func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        precondition(condition(), "Timed out waiting for power status")
    }
}

private actor PowerSnapshotClient: HerdrRequesting {
    var failing = false
    func setFailing(_ value: Bool) { failing = value }
    func request(_ method: String, params: [String: JSONValue], timeout: Int) async throws -> JSONValue {
        precondition(method == "session.snapshot")
        if failing { throw HerdrError.message("Connection lost") }
        return .object(["snapshot": .object([
            "version": .string("test"), "protocol": .number(20),
            "workspaces": .array([]), "tabs": .array([]), "panes": .array([]), "agents": .array([])
        ])])
    }
}
