import Foundation
import HerdrCore

@main struct DeviceStoreTests {
    @MainActor static func main() async throws {
        guard CommandLine.arguments.count == 4 else { fatalError("Pass two disposable sockets and the herdr executable") }
        let socketA = CommandLine.arguments[1], socketB = CommandLine.arguments[2], exe = CommandLine.arguments[3]
        for socket in [socketA, socketB] {
            precondition(socket.hasPrefix("/tmp/"), "Tests only accept disposable /tmp sockets")
            precondition(socket.contains("native-client-test"))
        }
        let suiteName = "dev.herdr.device-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let firstProfile = DeviceProfile(name: "First Mac", kind: .local, socketPath: socketA, executable: exe)
        let secondProfile = DeviceProfile(name: "Second Mac", kind: .local, socketPath: socketB, executable: exe)
        let devices = DeviceStore(defaults: defaults, profiles: [firstProfile, secondProfile])
        defer { devices.stop() }
        let first = devices.sessions[0], second = devices.sessions[1]
        // The script starts two fresh servers. Create one workspace on each so their IDs overlap.
        let clientA = HerdrClient(socketPath: socketA), clientB = HerdrClient(socketPath: socketB)
        let aResult = try await clientA.request("workspace.create", params: ["label": .string("Only on A"), "cwd": .string("/tmp"), "focus": .bool(true)])
        let bResult = try await clientB.request("workspace.create", params: ["label": .string("Only on B"), "cwd": .string("/tmp"), "focus": .bool(true)])
        let a = try aResult["workspace"].decode(Workspace.self), b = try bResult["workspace"].decode(Workspace.self)
        precondition(a.id == b.id, "Fixture must exercise overlapping server IDs")
        await first.refresh(); await second.refresh()
        precondition(first.connected && second.connected)
        devices.select(second, workspace: b)
        precondition(devices.activeSession === second)
        precondition(first.connectionGeneration != second.connectionGeneration)
        second.rename(ResourceTarget(kind: "workspace", id: b.id, label: b.label), label: "Renamed on B")
        for _ in 0..<80 {
            let result = try await clientB.request("session.snapshot")
            let snapshot = try result["snapshot"].decode(SessionSnapshot.self)
            if snapshot.workspaces.first(where: { $0.id == b.id })?.label == "Renamed on B" { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        await second.refresh(); await first.refresh()
        precondition(first.workspaces.first { $0.id == a.id }?.label == "Only on A")
        precondition(second.workspaces.first { $0.id == b.id }?.label == "Renamed on B")
        let selectedTab = second.selectedTab
        devices.select(first, workspace: a); devices.select(second)
        precondition(second.selectedTab == selectedTab)
        let reloaded = DeviceStore(defaults: defaults)
        precondition(reloaded.sessions.map(\.profile) == [firstProfile, secondProfile])
        precondition(reloaded.selectedDeviceID == secondProfile.id)
        reloaded.stop()
        // Cancel in the same actor turn before perform's queued task can dispatch.
        first.rename(ResourceTarget(kind: "workspace", id: a.id, label: a.label), label: "Stale mutation")
        first.disconnect()
        try await Task.sleep(for: .milliseconds(100))
        precondition(!first.busy, "A stale queued action must not leave the session busy")
        let afterDisconnect = try await clientA.request("session.snapshot")["snapshot"].decode(SessionSnapshot.self)
        precondition(afterDisconnect.workspaces.first { $0.id == a.id }?.label == "Only on A", "A queued action must not dispatch after disconnect")
        await first.refresh()
        precondition(!first.connected && first.suspended && second.connected)
        first.rename(ResourceTarget(kind: "workspace", id: a.id, label: a.label), label: "Must not run")
        precondition(first.workspaces.first { $0.id == a.id }?.label == "Only on A")
        first.reconnect()
        for _ in 0..<80 where !first.connected { try await Task.sleep(for: .milliseconds(50)) }
        precondition(first.connected)

        // Exercise the remote SessionStore with a controlled SSH process forwarding to server B.
        let fixture = FileManager.default.currentDirectoryPath + "/Tests/Fixtures/ssh-fixture.py"
        let remote = SessionStore(profile: DeviceProfile(name: "Remote fixture", host: "fixture.test", socketPath: socketB, executable: exe), defaults: defaults, tunnel: SSHTunnel(sshExecutable: fixture))
        defer { remote.disconnect() }
        await remote.refresh()
        precondition(remote.connected && remote.isRemote)
        precondition(remote.defaultDirectory == "/Users/remote")
        precondition(remote.effectiveSocketPath != socketB && remote.effectiveSocketPath.hasPrefix("/tmp/uh-"))
        precondition(remote.workspaces.first { $0.id == b.id }?.label == "Renamed on B")
        // The normal terminal stream integration suite also runs through the forwarded socket.
        let testSocket = URL(fileURLWithPath: socketB).deletingLastPathComponent().appendingPathComponent("forwarded.sock").path
        try FileManager.default.createSymbolicLink(atPath: testSocket, withDestinationPath: remote.effectiveSocketPath)
        try FileManager.default.createSymbolicLink(atPath: DeviceProfile.clientSocketPath(for: testSocket), withDestinationPath: DeviceProfile.clientSocketPath(for: remote.effectiveSocketPath))
        let terminalTest = Process()
        terminalTest.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        terminalTest.arguments = ["python3", "scripts/test-terminal-stream.py", testSocket, exe]
        try terminalTest.run()
        while terminalTest.isRunning { try await Task.sleep(for: .milliseconds(50)) }
        precondition(terminalTest.terminationStatus == 0)
        let forwardedSocket = remote.effectiveSocketPath
        remote.disconnect()
        precondition(!FileManager.default.fileExists(atPath: forwardedSocket))
        let stillAlive = try await clientB.request("session.snapshot")
        let remaining = try stillAlive["snapshot"].decode(SessionSnapshot.self)
        precondition(remaining.workspaces.contains { $0.id == b.id })
        await second.refresh()
        precondition(second.connected)
        print("PASS: two-device ID isolation, action routing, selection, persistence, disconnect/reconnect, remote paths, forwarded terminal stream and detach preservation")
    }
}
