import Foundation
import HerdrCore

enum SessionDiscoveryTests {
    // Shape captured from `herdr session list --json` on herdr 0.9.3.
    static let listing = #"{"sessions":[{"default":true,"name":"default","running":true,"session_dir":"/Users/alex/.config/herdr","socket_path":"/Users/alex/.config/herdr/herdr.sock"},{"default":false,"name":"menqal","running":true,"session_dir":"/Users/alex/.config/herdr/sessions/menqal","socket_path":"/Users/alex/.config/herdr/sessions/menqal/herdr.sock"},{"default":false,"name":"side-projects","running":true,"session_dir":"/Users/alex/.config/herdr/sessions/side-projects","socket_path":"/Users/alex/.config/herdr/sessions/side-projects/herdr.sock"},{"default":false,"name":"test","running":false,"session_dir":"/Users/alex/.config/herdr/sessions/test","socket_path":"/Users/alex/.config/herdr/sessions/test/herdr.sock"}]}"#

    @MainActor static func run() async throws {
        let sessions = try SessionDiscovery.parse(listing)
        XCTAssertEqual(sessions.map(\.name), ["default", "menqal", "side-projects", "test"])
        XCTAssertEqual(sessions.map(\.running), [true, true, true, false])
        XCTAssertTrue(sessions[0].isDefault && !sessions[1].isDefault)
        XCTAssertThrowsError(try SessionDiscovery.parse("name status\n"))

        let exe = "/opt/homebrew/bin/herdr"
        func local(_ name: String, _ socket: String) -> DeviceProfile { DeviceProfile(name: name, kind: .local, socketPath: socket, executable: exe) }
        // Only running sessions are added, named after the session.
        let fresh = SessionDiscovery.newProfiles(for: sessions, existing: [], dismissed: [], executable: exe)
        XCTAssertEqual(fresh.map(\.name), ["default", "menqal", "side-projects"])
        XCTAssertTrue(fresh.allSatisfy { $0.kind == .local && $0.executable == exe && $0.validationError == nil })
        XCTAssertEqual(fresh[1].socketPath, "/Users/alex/.config/herdr/sessions/menqal/herdr.sock")

        // A saved device on the same socket (written differently) is kept as is and not duplicated.
        let saved = DeviceProfile(name: "This Mac", kind: .local, socketPath: "/Users/alex/.config/herdr/sessions/../sessions/side-projects/herdr.sock", executable: exe)
        let remote = DeviceProfile(name: "menqal", host: "mini.local", socketPath: "/Users/alex/.config/herdr/herdr.sock", executable: exe)
        let added = SessionDiscovery.newProfiles(for: sessions, existing: [saved, remote], dismissed: [], executable: exe)
        // A remote socket path never matches a local one; a clashing name gets a suffix.
        XCTAssertEqual(added.map(\.name), ["default", "menqal session"])
        // The suffix repeats until the name is free.
        let clashing = try SessionDiscovery.parse(#"{"sessions":[{"default":false,"name":"menqal","running":true,"session_dir":"x","socket_path":"/tmp/uh-a/herdr.sock"},{"default":false,"name":"menqal","running":true,"session_dir":"x","socket_path":"/tmp/uh-b/herdr.sock"}]}"#)
        let suffixed = SessionDiscovery.newProfiles(for: clashing, existing: [remote, local("menqal session", "/tmp/uh-c/herdr.sock")], dismissed: [], executable: exe)
        XCTAssertEqual(suffixed.map(\.name), ["menqal session 2", "menqal session 3"])

        // Dismissed sockets stay out until discovery is asked to include them.
        let dismissed: Set<String> = ["/Users/alex/.config/herdr/herdr.sock"]
        XCTAssertEqual(SessionDiscovery.newProfiles(for: sessions, existing: [saved], dismissed: dismissed, executable: exe).map(\.name), ["menqal"])

        // A home-relative path matches its expanded form.
        let home = NSHomeDirectory()
        let tilde = DeviceProfile(name: "Mine", kind: .local, socketPath: "~/.config/herdr/herdr.sock", executable: exe)
        let mine = try SessionDiscovery.parse(#"{"sessions":[{"default":true,"name":"default","running":true,"session_dir":"x","socket_path":"\#(home)/.config/herdr/herdr.sock"}]}"#)
        XCTAssertEqual(SessionDiscovery.newProfiles(for: mine, existing: [tilde], dismissed: [], executable: exe).count, 0)

        // The CLI is asked for JSON; a failing CLI throws instead of returning nothing.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("uh-discovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = dir.appendingPathComponent("herdr").path
        try "#!/bin/sh\n[ \"$*\" = 'session list --json' ] || exit 3\nprintf '%s' '\(listing)'\n".write(toFile: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake)
        XCTAssertEqual(try await SessionDiscovery.list(executable: fake), sessions)
        // A listing past ManagedProcess's default 16 KB bound is still read whole.
        let many = (0..<300).map { #"{"default":false,"name":"s\#($0)","running":true,"session_dir":"/tmp/uh-many/sessions/s\#($0)","socket_path":"/tmp/uh-many/sessions/s\#($0)/herdr.sock"}"# }
        let large = #"{"sessions":["# + many.joined(separator: ",") + "]}"
        XCTAssertTrue(large.utf8.count > 32768)
        try large.write(toFile: dir.appendingPathComponent("large.json").path, atomically: true, encoding: .utf8)
        let big = dir.appendingPathComponent("big").path
        try "#!/bin/sh\ncat \"$(dirname \"$0\")/large.json\"\n".write(toFile: big, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: big)
        XCTAssertEqual(try await SessionDiscovery.list(executable: big).count, 300)
        XCTAssertEqual(try await SessionControl.list(SessionControl.runner(executable: big)).count, 300)
        let failing = dir.appendingPathComponent("broken").path
        try "#!/bin/sh\necho 'unknown command' >&2\nexit 2\n".write(toFile: failing, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: failing)
        var threw = false
        do { _ = try await SessionDiscovery.list(executable: failing) } catch { threw = true }
        XCTAssertTrue(threw)
        // Session names come from the socket path; other paths keep the device name.
        XCTAssertEqual(local("This Mac", "/Users/alex/.config/herdr/sessions/side-projects/herdr.sock").sessionName, "side-projects")
        XCTAssertEqual(local("This Mac", "~/.config/herdr/herdr.sock").sessionName, "default")
        XCTAssertEqual(local("Custom", "/tmp/uh-test/custom.sock").sessionName, "Custom")
        XCTAssertEqual(local("Odd", "/tmp/sessions/herdr.sock").sessionName, "Odd")
        let mini = DeviceProfile(name: "Mac mini", host: "alex@mini.local", executable: exe)
        XCTAssertEqual(mini.sessionName, "default")
        var named = mini; named.socketPath = "~/.config/herdr/sessions/work/herdr.sock"
        XCTAssertEqual(named.sessionName, "work")
        // Grouping: all local devices together; SSH devices by host, user and port.
        XCTAssertEqual(local("a", "/tmp/a.sock").machineKey, local("b", "/tmp/b.sock").machineKey)
        XCTAssertEqual(named.machineKey, mini.machineKey)
        var otherPort = mini; otherPort.port = "2222"
        XCTAssertTrue(otherPort.machineKey != mini.machineKey && mini.machineKey != local("a", "/tmp/a.sock").machineKey)
        // The user may sit in the host or in Username; no port means 22.
        let split = DeviceProfile(name: "Mini", host: "Mini.Local", user: "alex", port: "22", executable: exe)
        XCTAssertEqual(split.machineKey, mini.machineKey)
        var otherUser = split; otherUser.user = "sam"
        XCTAssertTrue(otherUser.machineKey != mini.machineKey)
        print("PASS: session listing, running filter, socket dedupe, dismissed sockets, repeated name clashes, large listings, machine keys and CLI errors")
    }
}
