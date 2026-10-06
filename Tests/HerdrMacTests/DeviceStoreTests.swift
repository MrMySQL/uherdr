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
        try await testFileTransferCancellation(defaults: defaults)
        try await testSessionDiscovery(socketA: socketA, socketB: socketB, exe: exe)
        try testMachineGroups(exe: exe)
        testMachineActions(exe: exe)
        try await testSessionActionOrdering()
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
        let remoteTunnel = SSHTunnel(sshExecutable: fixture)
        var remotePower: DevicePowerStatus = .mains
        let remote = SessionStore(profile: DeviceProfile(name: "Remote fixture", host: "fixture.test", socketPath: socketB, executable: exe), defaults: defaults, tunnel: remoteTunnel, powerReader: { _ in remotePower })
        defer { remote.disconnect() }
        await remote.refresh()
        precondition(remote.connected && remote.isRemote)
        precondition(remote.defaultDirectory == "/Users/remote")
        precondition(remote.effectiveSocketPath != socketB && remote.effectiveSocketPath.hasPrefix("/tmp/uh-"))
        precondition(remote.workspaces.first { $0.id == b.id }?.label == "Renamed on B")
        for _ in 0..<80 where remote.powerStatus != .mains { try await Task.sleep(for: .milliseconds(10)) }
        precondition(remote.powerStatus == .mains)
        // A tunnel can restart between successful snapshots without a connection error.
        remotePower = .battery(percentage: 73, externallyPowered: true)
        remoteTunnel.stop()
        await remote.refresh()
        for _ in 0..<80 where remote.powerStatus != remotePower { try await Task.sleep(for: .milliseconds(10)) }
        precondition(remote.powerStatus == remotePower, "Replacing a tunnel must immediately refresh device power")
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
        try await testServerActions(socketA: socketA, socketB: socketB, exe: exe)
        // Last: this stops and deletes server A's session.
        try await testSessionActions(socketA: socketA, socketB: socketB, exe: exe)
    }

    @MainActor static func testFileTransferCancellation(defaults: UserDefaults) async throws {
        let root = URL(fileURLWithPath: "/tmp/herdr-device-upload-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("sample.txt")
        try Data("file bytes".utf8).write(to: source)
        let key = root.appendingPathComponent("fixture-key").path
        let marker = key + ".upload-path"
        let fixture = FileManager.default.currentDirectoryPath + "/Tests/Fixtures/ssh-upload-fixture.py"
        for disconnect in [true, false] {
            try? FileManager.default.removeItem(atPath: marker)
            let profile = DeviceProfile(name: "Upload cancellation", host: "slow.test", user: "tester",
                port: "2222", identityFile: key, executable: "/bin/herdr")
            let session = SessionStore(profile: profile, defaults: defaults, fileTransfer: RemoteFileTransfer(sshExecutable: fixture))
            let pending = Task { try await session.prepareDroppedFiles([source]) }
            defer { pending.cancel(); session.disconnect() }
            let deadline = Date().addingTimeInterval(5)
            while !FileManager.default.fileExists(atPath: marker), Date() < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            let directory = try String(contentsOfFile: marker, encoding: .utf8)
            defer { try? FileManager.default.removeItem(atPath: directory) }
            if disconnect { session.disconnect() } else { pending.cancel() }
            do {
                _ = try await pending.value
                throw HerdrError.message("An invalidated device upload returned paths")
            } catch is CancellationError { }
            guard !FileManager.default.fileExists(atPath: directory) else {
                throw HerdrError.message("Device/caller cancellation must remove remote staging")
            }
        }
        print("PASS: device disconnect and caller cancellation stop uploads and remove remote staging")
    }

    @MainActor static func testMachineGroups(exe: String) throws {
        let suiteName = "dev.herdr.group-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let local = DeviceProfile(name: "This Mac", kind: .local, socketPath: "/tmp/uh-groups/sessions/side-projects/herdr.sock", executable: exe)
        let mini = DeviceProfile(name: "Mac mini", host: "alex@mini.local", executable: exe)
        let discovered = DeviceProfile(name: "menqal", kind: .local, socketPath: "/tmp/uh-groups/sessions/menqal/herdr.sock", executable: exe)
        var miniWork = DeviceProfile(name: "Mini work", host: "ALEX@mini.local", executable: exe)
        miniWork.socketPath = "~/.config/herdr/sessions/work/herdr.sock"
        // Not started: grouping and shortcut order need no connection.
        let devices = DeviceStore(defaults: defaults, profiles: [local, mini, discovered, miniWork]) { _ in [] }
        let groups = devices.machineGroups
        precondition(groups.map(\.name) == ["This Mac", "Mac mini"])
        precondition(groups[0].sessions.map(\.profile.sessionName) == ["side-projects", "menqal"])
        precondition(groups[1].sessions.map(\.profile.sessionName) == ["default", "work"])
        precondition(devices.sessions[0].displayName == "side-projects" && devices.sessions[3].displayName == "Mini work · work")
        // ⌘1–9 follow the grouped sidebar order, not the order devices were added.
        func spaces(_ ids: [String]) throws -> [Workspace] {
            try ids.map { try JSONDecoder().decode(Workspace.self, from: Data(#"{"workspace_id":"\#($0)","label":"\#($0)","active_tab_id":"t","pane_count":1,"tab_count":1,"agent_status":"idle"}"#.utf8)) }
        }
        devices.sessions[0].workspaces = try spaces(["a1"])
        devices.sessions[1].workspaces = try spaces(["m1"])
        devices.sessions[2].workspaces = try spaces(["q1", "q2"])
        devices.sessions[3].workspaces = try spaces(["w1"])
        precondition(devices.workspaceShortcuts.map(\.workspace.id) == ["a1", "q1", "q2", "m1", "w1"])
        // An SSH profile with the user in Username and an explicit port 22 joins the same machine.
        let miniSplit = DeviceProfile(name: "Mini split", host: "mini.local", user: "alex", port: "22", executable: exe)
        let joined = DeviceStore(defaults: defaults, profiles: [local, mini, miniSplit]) { _ in [] }
        precondition(joined.machineGroups.map { $0.sessions.count } == [1, 2])
        // Search: a host or any device's name shows its session even with nothing else matching.
        func shown(_ text: String, _ mode: String = "agents") -> [String] {
            let search = SidebarSearch(text: text, mode: mode)
            return devices.machineGroups.flatMap { machine in
                let machineMatches = search.machineMatches(machine)
                return machine.sessions.filter { search.shows($0, machineMatches: machineMatches) }.map(\.profile.name)
            }
        }
        precondition(shown("") == ["This Mac", "menqal", "Mac mini", "Mini work"])
        precondition(shown("mini.local") == ["Mac mini", "Mini work"], "A host match shows sessions without agents")
        precondition(shown("Mini work") == ["Mini work"], "A device that is not first in its group is found by name")
        precondition(shown("q2", "spaces") == ["menqal"] && shown("q2") == [])
        precondition(SidebarSearch(text: "mini.local", mode: "spaces").spaces(devices.sessions[1], machineMatches: false).map(\.id) == ["m1"])
        print("PASS: sessions group by machine, take their names from sockets, and keep shortcuts in sidebar order; search finds hosts and every device name")
    }

    @MainActor static func testSessionDiscovery(socketA: String, socketB: String, exe: String) async throws {
        let suiteName = "dev.herdr.discovery-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        func entry(_ name: String, _ socket: String, running: Bool = true) -> String {
            #"{"default":false,"name":"\#(name)","running":\#(running),"session_dir":"/tmp","socket_path":"\#(socket)"}"#
        }
        var listing = #"{"sessions":[\#(entry("alpha", socketA)),\#(entry("beta", socketB)),\#(entry("stopped", "/tmp/uh-stopped/herdr.sock", running: false))]}"#
        var listerFails = false
        var askedExecutable: String?
        let first = DeviceProfile(name: "This Mac", kind: .local, socketPath: socketA, executable: exe)
        let devices = DeviceStore(defaults: defaults, profiles: [first]) { executable in
            askedExecutable = executable
            if listerFails { throw HerdrError.message("unknown command") }
            return try SessionDiscovery.parse(listing)
        }
        defer { devices.stop() }
        await devices.discoverSessions()
        precondition(askedExecutable == exe, "Discovery uses the local device's herdr CLI")
        // The saved device keeps its name; only the unseen running session is added.
        precondition(devices.sessions.map(\.profile.name) == ["This Mac", "beta"])
        let beta = devices.sessions[1]
        precondition(!beta.isRemote && beta.profile.socketPath == socketB)
        for _ in 0..<80 where !beta.connected { try await Task.sleep(for: .milliseconds(50)) }
        precondition(beta.connected, "A discovered session connects like any device")
        // Rescanning is idempotent and survives a relaunch from saved preferences.
        await devices.discoverSessions()
        precondition(devices.sessions.count == 2)
        let reloaded = DeviceStore(defaults: defaults) { _ in try SessionDiscovery.parse(listing) }
        precondition(reloaded.sessions.map(\.profile) == devices.sessions.map(\.profile))
        reloaded.stop()
        // Removing a discovered session keeps it out of automatic rescans.
        devices.remove(beta.profile.id)
        precondition(devices.sessions.count == 1 && !beta.connected)
        await devices.discoverSessions()
        precondition(devices.sessions.count == 1, "A removed session must not come back on its own")
        // The last device can never be removed.
        devices.remove(devices.sessions[0].profile.id)
        precondition(devices.sessions.count == 1)
        // An explicit discovery brings dismissed sessions back.
        await devices.discoverSessions(includeDismissed: true)
        precondition(devices.sessions.map(\.profile.name) == ["This Mac", "beta"])
        // An explicit discovery during a periodic scan is queued, not dropped.
        devices.remove(devices.sessions[1].profile.id)
        precondition(devices.sessions.count == 1)
        var gate: CheckedContinuation<Void, Never>?
        let held = DeviceStore(defaults: defaults, profiles: [first]) { _ in
            if gate == nil { await withCheckedContinuation { gate = $0 } }
            return try SessionDiscovery.parse(listing)
        }
        defer { held.stop() }
        let periodic = Task { await held.discoverSessions() }
        for _ in 0..<80 where gate == nil { try await Task.sleep(for: .milliseconds(10)) }
        precondition(gate != nil, "The periodic scan must be in flight")
        await held.discoverSessions(includeDismissed: true)
        gate?.resume()
        await periodic.value
        precondition(held.sessions.map(\.profile.name) == ["This Mac", "beta"], "A queued explicit discovery restores dismissed sessions")
        held.stop()
        await devices.discoverSessions(includeDismissed: true)
        precondition(devices.sessions.map(\.profile.name) == ["This Mac", "beta"])
        // A failing or older CLI changes nothing and raises no error.
        listerFails = true
        listing = #"{"sessions":[]}"#
        await devices.discoverSessions()
        precondition(devices.sessions.count == 2 && devices.activeSession.operationError == nil)
        print("PASS: session discovery adds running sessions once, keeps saved devices, honours removal, queues explicit discovery, and ignores CLI failures")
    }

    @MainActor static func testMachineActions(exe: String) {
        let suiteName = "dev.herdr.machine-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let local = DeviceProfile(name: "This Mac", kind: .local, socketPath: "/tmp/uh-machine/herdr.sock", executable: exe)
        let mini = DeviceProfile(name: "Mac mini", host: "alex@mini.invalid", executable: exe)
        var miniWork = DeviceProfile(name: "Mini work", host: "alex@mini.invalid", executable: exe)
        miniWork.socketPath = "~/.config/herdr/sessions/work/herdr.sock"
        let devices = DeviceStore(defaults: defaults, profiles: [local, mini, miniWork]) { _ in [] }
        defer { devices.stop() }
        let ssh = devices.machineGroups[1].id
        precondition(!devices.canRemoveMachine(devices.machineGroups[0].id), "This Mac is never removed as a machine")
        // Any device confirmation blocks app commands.
        precondition(!devices.isPresenting)
        devices.pendingSessionAction = .stop(local.id); precondition(devices.isPresenting); devices.pendingSessionAction = nil
        devices.pendingMachineRemoval = ssh; precondition(devices.isPresenting); devices.pendingMachineRemoval = nil
        devices.pendingRemoval = local.id; precondition(devices.isPresenting); devices.pendingRemoval = nil
        devices.editor = DeviceEditorTarget(profile: local); precondition(devices.isPresenting); devices.editor = nil
        // Editing the machine's connection applies it to every session on it.
        var edited = mini; edited.host = "alex@mini2.invalid"; edited.port = "2222"
        devices.save(edited, machine: ssh)
        precondition(devices.sessions.filter(\.isRemote).allSatisfy { $0.profile.host == "alex@mini2.invalid" && $0.profile.port == "2222" })
        precondition(devices.sessions[2].profile.socketPath == miniWork.socketPath, "A machine edit keeps each session's own socket")
        // Removing the machine removes all its sessions and hides nothing locally.
        let machine = devices.machineGroups[1].id
        precondition(devices.canRemoveMachine(machine))
        devices.removeMachine(machine)
        precondition(devices.sessions.map(\.profile.id) == [local.id])
        precondition((defaults.stringArray(forKey: SessionDiscovery.dismissedKey) ?? []).isEmpty)
        // A machine holding every device can't be removed.
        let onlySSH = DeviceStore(defaults: defaults, profiles: [mini, miniWork]) { _ in [] }
        defer { onlySSH.stop() }
        precondition(!onlySSH.canRemoveMachine(onlySSH.machineGroups[0].id))
        onlySSH.removeMachine(onlySSH.machineGroups[0].id)
        precondition(onlySSH.sessions.count == 2)
        print("PASS: machine edits apply to every session, and removing a machine keeps at least one device")
    }

    /// Stop/Remove against a fake herdr CLI, racing an older discovery.
    @MainActor static func testSessionActionOrdering() async throws {
        let suiteName = "dev.herdr.session-order-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let root = "/tmp/uh-session-order-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }
        let defaultSocket = "\(root)/herdr/herdr.sock", workSocket = "\(root)/herdr/sessions/work/herdr.sock"
        func listing(work: Bool?) -> String {
            let entry = work.map { #",{"default":false,"name":"work","running":\#($0),"socket_path":"\#(workSocket)"}"# } ?? ""
            return #"{"sessions":[{"default":true,"name":"default","running":false,"socket_path":"\#(defaultSocket)"}\#(entry)]}"#
        }
        // /usr/bin/true stands in for `herdr server`, so Start never launches a real server.
        let first = DeviceProfile(name: "default", kind: .local, socketPath: defaultSocket, executable: "/usr/bin/true")
        let second = DeviceProfile(name: "work", kind: .local, socketPath: workSocket, executable: "/usr/bin/true")
        var state = listing(work: true)
        var holdNext = false
        var held: CheckedContinuation<Void, Never>?
        let run: SessionControl.Runner = { args in
            if args == ["session", "stop", "work"] { state = listing(work: false) }
            if args == ["session", "delete", "work"] { state = listing(work: nil) }
            return args == ["session", "list", "--json"] ? state : ""
        }
        let devices = DeviceStore(defaults: defaults, profiles: [first, second], sessionLister: { _ in
            let snapshot = state
            if holdNext { holdNext = false; await withCheckedContinuation { held = $0 } }
            return try SessionDiscovery.parse(snapshot)
        }, sessionRunner: { _ in run })
        defer { devices.stop() }
        await devices.discoverSessions()
        let work = devices.sessions[1]
        precondition(devices.herdrSession(for: work)?.running == true)
        // A discovery that listed before Stop finishes after it and must not win.
        holdNext = true
        let staleStop = Task { await devices.discoverSessions() }
        while held == nil { await Task.yield() }
        await devices.stopHerdrSession(work)
        precondition(devices.activeSession.operationError == nil, devices.activeSession.operationError ?? "")
        precondition(work.suspended && !work.connected, "A stopped session's device is disconnected")
        held?.resume(); held = nil
        await staleStop.value
        precondition(devices.herdrSession(for: work)?.running == false, "An older listing overwrote the stop")
        // Nor may an older listing bring back a removed session.
        state = listing(work: true)
        await devices.discoverSessions()
        holdNext = true
        let staleRemove = Task { await devices.discoverSessions() }
        while held == nil { await Task.yield() }
        await devices.removeHerdrSession(work)
        held?.resume(); held = nil
        await staleRemove.value
        precondition(devices.sessions.map(\.profile.id) == [first.id], "An older listing re-added the removed session")
        // Starting the default server reconnects its device.
        let defaultDevice = devices.sessions[0]
        defaultDevice.disconnect()
        precondition(devices.canStartDefaultServer)
        devices.startDefaultServer()
        precondition(!defaultDevice.suspended, "Start herdr server must reconnect the default session")
        print("PASS: Stop disconnects its device, older discoveries never overwrite an action, and Start reconnects")
    }

    /// Stops and deletes server A's real session through herdr's CLI.
    @MainActor static func testSessionActions(socketA: String, socketB: String, exe: String) async throws {
        let suiteName = "dev.herdr.session-action-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        // socketA is <root>/config/herdr/sessions/<name>/herdr.sock.
        let root = URL(fileURLWithPath: socketA).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var env = ProcessInfo.processInfo.environment
        env["XDG_CONFIG_HOME"] = root.appendingPathComponent("config").path
        env["XDG_STATE_HOME"] = root.appendingPathComponent("state").path
        let run = SessionControl.runner(executable: exe, environment: env)
        let first = DeviceProfile(name: "A", kind: .local, socketPath: socketA, executable: exe)
        let second = DeviceProfile(name: "B", kind: .local, socketPath: socketB, executable: exe)
        let devices = DeviceStore(defaults: defaults, profiles: [first, second],
                                  sessionLister: { _ in try await SessionControl.list(run) },
                                  sessionRunner: { _ in run })
        defer { devices.stop() }
        await devices.discoverSessions()
        let a = devices.sessions[0], b = devices.sessions[1]
        precondition(devices.herdrSession(for: a)?.name == "native-client-test" && devices.herdrSession(for: a)?.running == true)
        precondition(devices.herdrSession(for: b) == nil, "B lives under another config, so this CLI can't stop or delete it")
        precondition(devices.canRemoveHerdrSession(a) && !devices.canRemoveHerdrSession(b))
        // A session herdr doesn't list reports an error instead of acting.
        await devices.stopHerdrSession(b)
        precondition(devices.activeSession.operationError != nil)
        devices.activeSession.operationError = nil
        // Stop: the server ends, the device stays listed.
        await devices.stopHerdrSession(a)
        precondition(devices.activeSession.operationError == nil, devices.activeSession.operationError ?? "")
        precondition(!FileManager.default.fileExists(atPath: socketA), "Stopping must end server A")
        precondition(devices.herdrSession(for: a)?.running == false && devices.sessions.count == 2)
        precondition(a.suspended, "A stopped session's device is disconnected")
        // Remove: herdr deletes the session directory and the device goes away.
        let sessionDir = URL(fileURLWithPath: socketA).deletingLastPathComponent().path
        precondition(FileManager.default.fileExists(atPath: sessionDir))
        await devices.removeHerdrSession(a)
        precondition(devices.activeSession.operationError == nil, devices.activeSession.operationError ?? "")
        precondition(!FileManager.default.fileExists(atPath: sessionDir), "herdr must delete the session")
        let remaining = try await SessionControl.list(run)
        precondition(remaining.allSatisfy { $0.name != "native-client-test" })
        precondition(devices.sessions.map(\.profile.id) == [second.id])
        // The last device can't be removed, even through a herdr session.
        precondition(!devices.canRemoveHerdrSession(devices.sessions[0]))
        print("PASS: Stop ends a real herdr session and keeps its device; Remove deletes it in herdr and here")
    }

    /// Reconnect/Disconnect all act on every session of a machine.
    @MainActor static func testServerActions(socketA: String, socketB: String, exe: String) async throws {
        let suiteName = "dev.herdr.server-action-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let devices = DeviceStore(defaults: defaults, profiles: [
            DeviceProfile(name: "A", kind: .local, socketPath: socketA, executable: exe),
            DeviceProfile(name: "B", kind: .local, socketPath: socketB, executable: exe),
        ]) { _ in [] }
        defer { devices.stop() }
        let a = devices.sessions[0], b = devices.sessions[1]
        await a.refresh(); await b.refresh()
        precondition(a.connected && b.connected)
        let machine = devices.machineGroups[0].id
        devices.disconnectAll(machine)
        precondition(!a.connected && !b.connected && a.suspended && b.suspended)
        devices.reconnectAll(machine)
        for _ in 0..<80 where !(a.connected && b.connected) { try await Task.sleep(for: .milliseconds(50)) }
        precondition(a.connected && b.connected, "Reconnect all must bring every session back")
        print("PASS: Reconnect and Disconnect all act on every session of a machine")
    }
}
