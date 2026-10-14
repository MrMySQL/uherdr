import Foundation
import HerdrCore

enum SessionControlTests {
    @MainActor static func run() async throws {
        let sessions = try SessionDiscovery.parse(SessionDiscoveryTests.listing)
        let exe = "/opt/homebrew/bin/herdr"
        func local(_ socket: String) -> DeviceProfile { DeviceProfile(name: "x", kind: .local, socketPath: socket, executable: exe) }
        // The session is found by socket, including a differently written path.
        XCTAssertEqual(SessionControl.session(for: local("/Users/alex/.config/herdr/sessions/../sessions/menqal/herdr.sock"), in: sessions)?.name, "menqal")
        XCTAssertEqual(SessionControl.session(for: local("/Users/alex/.config/herdr/herdr.sock"), in: sessions)?.name, "default")
        XCTAssertTrue(SessionControl.session(for: local("/tmp/custom.sock"), in: sessions) == nil)
        var remote = DeviceProfile(name: "mini", host: "mini.local", executable: exe)
        remote.socketPath = "/Users/alex/.config/herdr/sessions/menqal/herdr.sock"
        // SSH devices are never stopped or deleted locally.
        XCTAssertTrue(SessionControl.session(for: remote, in: sessions) == nil)

        var calls: [[String]] = []
        var failOn: String?
        let run: SessionControl.Runner = { args in
            calls.append(args)
            if let failOn, args.contains(failOn) { throw HerdrError.message("session \(failOn) failed") }
            return args == ["session", "list", "--json"] ? SessionDiscoveryTests.listing : ""
        }
        XCTAssertEqual(try await SessionControl.list(run).map(\.name), sessions.map(\.name))
        calls = []
        try await SessionControl.stop("menqal", run)
        XCTAssertEqual(calls, [["session", "stop", "menqal"]])
        // A running session is stopped before it is deleted; a stopped one is only deleted.
        calls = []
        try await SessionControl.delete(sessions.first { $0.name == "menqal" }!, run)
        XCTAssertEqual(calls, [["session", "stop", "menqal"], ["session", "delete", "menqal"]])
        calls = []
        try await SessionControl.delete(sessions.first { $0.name == "test" }!, run)
        XCTAssertEqual(calls, [["session", "delete", "test"]])
        // The default session is never deleted, and a failed stop never deletes.
        calls = []
        var threw = false
        do { try await SessionControl.delete(sessions[0], run) } catch { threw = true }
        XCTAssertTrue(threw && calls.isEmpty && !SessionControl.canDelete(sessions[0]))
        // Live handoff addresses the default session bare and others by name.
        var status = #"{"server":{"running":true,"capabilities":{"live_handoff":true}}}"#
        let statusRun: SessionControl.Runner = { args in
            calls.append(args)
            return args.suffix(2) == ["status", "--json"] ? status : ""
        }
        calls = []
        XCTAssertTrue(try await SessionControl.supportsLiveHandoff(sessions[0], statusRun))
        XCTAssertTrue(try await SessionControl.supportsLiveHandoff(sessions.first { $0.name == "menqal" }!, statusRun))
        try await SessionControl.liveHandoff(sessions.first { $0.name == "menqal" }!, statusRun)
        XCTAssertEqual(calls, [["status", "--json"], ["--session", "menqal", "status", "--json"], ["--session", "menqal", "server", "live-handoff"]])
        // Older servers report no capability; a stopped one can't hand off; unreadable status throws.
        status = #"{"server":{"running":true,"capabilities":{}}}"#
        XCTAssertTrue(!(try await SessionControl.supportsLiveHandoff(sessions[0], statusRun)))
        status = #"{"server":{"running":false,"capabilities":{"live_handoff":true}}}"#
        XCTAssertTrue(!(try await SessionControl.supportsLiveHandoff(sessions[0], statusRun)))
        status = "not json"
        threw = false
        do { _ = try await SessionControl.supportsLiveHandoff(sessions[0], statusRun) } catch { threw = true }
        XCTAssertTrue(threw)
        calls = []; threw = false; failOn = "stop"
        do { try await SessionControl.delete(sessions.first { $0.name == "menqal" }!, run) } catch { threw = true }
        XCTAssertTrue(threw)
        XCTAssertEqual(calls, [["session", "stop", "menqal"]])
        // Starting a server names its session; a bare `herdr server` would use the default
        // session's data on any socket. Inherited herdr pane variables never reach it.
        let inherited = ["PATH": "/usr/bin", "XDG_CONFIG_HOME": "/Users/alex/.config", "HERDR_SESSION": "side-projects",
                         "HERDR_SOCKET_PATH": "/x/herdr.sock", "HERDR_PANE_ID": "p1", "HERDR_ENV": "1", "HERDR_CLIENT_SOCKET_PATH": "/y",
                         "HERDR_CONFIG_PATH": "/Users/alex/herdr.toml"]
        // HERDR_CONFIG_PATH is the user's config override, so it is kept.
        let clean = ["PATH": "/usr/bin", "XDG_CONFIG_HOME": "/Users/alex/.config", "HERDR_CONFIG_PATH": "/Users/alex/herdr.toml"]
        XCTAssertEqual(SessionControl.serverLaunch(for: local("/Users/alex/.config/herdr/sessions/menqal/herdr.sock"), in: sessions, environment: inherited),
                       SessionControl.ServerLaunch(arguments: ["--session", "menqal", "server"], environment: clean))
        XCTAssertEqual(SessionControl.serverLaunch(for: local("/Users/alex/.config/herdr/herdr.sock"), in: sessions, environment: inherited),
                       SessionControl.ServerLaunch(arguments: ["server"], environment: clean))
        XCTAssertEqual(SessionControl.serverLaunch(for: local("/tmp/custom.sock"), in: sessions, environment: inherited),
                       SessionControl.ServerLaunch(arguments: ["server"], environment: clean.merging(["HERDR_SOCKET_PATH": "/tmp/custom.sock"]) { $1 }))
        XCTAssertTrue(SessionControl.serverLaunch(for: remote, in: sessions, environment: inherited) == nil)
        // A herdr session socket herdr doesn't list never starts bare; only a custom socket does.
        XCTAssertTrue(SessionControl.serverLaunch(for: local("/Users/alex/.config/herdr/sessions/gone/herdr.sock"), in: sessions, environment: inherited) == nil)
        XCTAssertTrue(SessionControl.serverLaunch(for: local("/Users/alex/.config/herdr/sessions/menqal/herdr.sock"), in: [], environment: inherited) == nil)
        XCTAssertTrue(SessionControl.serverLaunch(for: local("/tmp/xdg/herdr/herdr.sock"), in: sessions, environment: inherited) == nil)
        // `..` can't make a session socket look custom.
        XCTAssertTrue(SessionControl.serverLaunch(for: local("/Users/alex/.config/herdr/sessions/old/../gone/herdr.sock"), in: sessions, environment: inherited) == nil)
        XCTAssertTrue(SessionControl.serverLaunch(for: local("/Users/alex/.config/herdr/sessions/gone/../../herdr.sock"), in: [], environment: inherited) == nil)
        XCTAssertEqual(local("/Users/alex/.config/herdr/sessions/old/../gone/herdr.sock").pathSessionName, "gone")
        XCTAssertEqual(SessionControl.serverLaunch(for: local("/tmp/uh/herdr.sock"), in: [], environment: inherited),
                       SessionControl.ServerLaunch(arguments: ["server"], environment: clean.merging(["HERDR_SOCKET_PATH": "/tmp/uh/herdr.sock"]) { $1 }))
        // A new session is created by serving it by name, with the same environment rules.
        XCTAssertEqual(SessionControl.newSessionLaunch(name: "work-2", environment: inherited),
                       SessionControl.ServerLaunch(arguments: ["--session", "work-2", "server"], environment: clean))
        // Names follow herdr's rule (checked against herdr 0.9.3), and must be free.
        for valid in ["work-2", "UPPER.dot_x", "a", "-dash"] {
            precondition(SessionControl.newSessionNameProblem(valid, existing: sessions) == nil, valid)
        }
        for invalid in ["", ".", "..", "has space", "bad/name", "café", "menqal", "default"] {
            precondition(SessionControl.newSessionNameProblem(invalid, existing: sessions) != nil, invalid)
        }
        print("PASS: session stop and delete use herdr's CLI, stop before delete, and never delete default; new session names follow herdr's rule")
        try await runRemote(sessions)
    }

    /// herdr on an SSH device's machine, through a fake SSH that runs the remote command here.
    @MainActor static func runRemote(_ sessions: [HerdrSessionEntry]) async throws {
        let exe = "/opt/homebrew/bin/herdr"
        func remote(_ socket: String) -> DeviceProfile { DeviceProfile(name: "mini", host: "mini.local", socketPath: socket, executable: exe) }
        // An empty socket is the default session; a session socket names its session; a custom one matches by path.
        XCTAssertEqual(SessionControl.remoteSession(for: remote(""), home: nil, in: sessions)?.name, "default")
        XCTAssertEqual(SessionControl.remoteSession(for: remote("~/.config/herdr/sessions/menqal/herdr.sock"), home: nil, in: sessions)?.name, "menqal")
        XCTAssertTrue(SessionControl.remoteSession(for: remote("~/.config/herdr/sessions/gone/herdr.sock"), home: nil, in: sessions) == nil)
        let custom = try SessionDiscovery.parse(#"{"sessions":[{"default":false,"name":"odd","running":true,"socket_path":"/Users/alex/sockets/odd.sock"}]}"#)
        XCTAssertEqual(SessionControl.remoteSession(for: remote("~/sockets/./odd.sock"), home: "/Users/alex", in: custom)?.name, "odd")
        XCTAssertTrue(SessionControl.remoteSession(for: remote("~/sockets/odd.sock"), home: nil, in: custom) == nil)
        XCTAssertTrue(SessionControl.remoteSession(for: DeviceProfile(name: "x", kind: .local, socketPath: "/Users/alex/.config/herdr/herdr.sock", executable: exe), home: nil, in: sessions) == nil)

        let home = FileManager.default.temporaryDirectory.appendingPathComponent("uh-remote-herdr-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: home) }
        let fake = home + "/.local/bin/herdr"
        try FileManager.default.createDirectory(atPath: home + "/.local/bin", withIntermediateDirectories: true)
        try "#!/bin/sh\nprintf '%s\\n' \"$@\" | tee \"$HOME/args\"\n".write(toFile: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake)
        setenv("UHERDR_TEST_HOME", home, 1)
        let ssh = FileManager.default.currentDirectoryPath + "/Tests/Fixtures/ssh-herdr-fixture.sh"
        // herdr is found off PATH, gets each argument intact, and the login banner is dropped.
        let run = SessionControl.remoteRunner(profile: remote(""), sshExecutable: ssh)
        XCTAssertEqual(try await run(["--session", "it's $HOME", "status", "--json"]), "--session\nit's $HOME\nstatus\n--json\n")
        // A detached server returns at once and keeps running after SSH ends.
        try FileManager.default.removeItem(atPath: home + "/args")
        XCTAssertEqual(try await SessionControl.remoteRunner(profile: remote(""), run: .detached, sshExecutable: ssh)(["--session", "work", "server"]), "")
        for _ in 0..<100 where (try? String(contentsOfFile: home + "/args", encoding: .utf8)) != "--session\nwork\nserver\n" {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(try String(contentsOfFile: home + "/args", encoding: .utf8), "--session\nwork\nserver\n")
        // Without herdr, the error says so rather than a shell's "command not found".
        try FileManager.default.removeItem(atPath: fake)
        if !["/home/linuxbrew/.linuxbrew/bin/herdr", "/opt/homebrew/bin/herdr", "/usr/local/bin/herdr"].contains(where: FileManager.default.isExecutableFile(atPath:)) {
            do { _ = try await run(["--version"]); XCTFail("Expected a missing herdr to throw") }
            catch { XCTAssertTrue(error.localizedDescription.contains("herdr wasn’t found")) }
        }
        unsetenv("UHERDR_TEST_HOME")
        print("PASS: SSH devices find their herdr session, and run herdr over SSH with quoted arguments, detached servers, and a clear error when it's missing")
    }
}
