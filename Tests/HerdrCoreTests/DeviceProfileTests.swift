import Foundation
import HerdrCore

enum DeviceProfileTests {
    @MainActor static func run() async throws {
        let profile = DeviceProfile(name: "Mac mini", host: "alex@mini.local", socketPath: "~/Library/Application Support/herdr.sock", executable: "/opt/homebrew/bin/herdr")
        XCTAssertEqual(profile.validationError, nil)
        XCTAssertEqual(try profile.resolvedRemoteSocket(home: "/Users/alex", discoveredSocket: "/tmp/default.sock"), "/Users/alex/Library/Application Support/herdr.sock")
        XCTAssertEqual(try JSONDecoder().decode(DeviceProfile.self, from: JSONEncoder().encode(profile)), profile)
        XCTAssertEqual(DeviceProfile.clientSocketPath(for: "/tmp/herdr.sock"), "/tmp/herdr-client.sock")
        XCTAssertEqual(DeviceProfile.clientSocketPath(for: "/tmp/custom.name.sock"), "/tmp/custom.name-client.sock")
        XCTAssertEqual(DeviceProfile.clientSocketPath(for: "/tmp/herdr"), "/tmp/herdr-client.sock")
        for host in ["-oProxyCommand=oops", "host;touch /tmp/oops", "host\nother", "$(whoami)", ""] {
            var invalid = profile; invalid.host = host
            XCTAssertTrue(invalid.validationError != nil)
        }
        for path in ["relative.sock", "/tmp/a:b.sock", "/tmp/a\nsock", "/tmp/a\0sock"] {
            var invalid = profile; invalid.socketPath = path
            XCTAssertTrue(invalid.validationError != nil)
        }
        var configured = profile
        configured.host = "work-mac"; configured.user = "alex"; configured.port = "2222"
        configured.identityFile = "/tmp/key with spaces"
        let args = try configured.sshArguments()
        XCTAssertTrue(args.contains("StrictHostKeyChecking=yes"))
        XCTAssertTrue(args.contains("BatchMode=yes"))
        XCTAssertTrue(args.contains("ForkAfterAuthentication=no"))
        XCTAssertEqual(Array(args.suffix(6)), ["-l", "alex", "-p", "2222", "-i", "/tmp/key with spaces"])
        // Control modes: exactly one ControlMaster and one ControlPath each (ssh keeps the first).
        func values(_ args: [String], _ option: String) -> [String] { args.filter { $0.hasPrefix(option + "=") } }
        XCTAssertEqual(values(args, "ControlMaster"), ["ControlMaster=no"])
        XCTAssertEqual(values(args, "ControlPath"), ["ControlPath=none"])
        let master = try configured.sshArguments(control: .master("/tmp/uh-x/c"))
        XCTAssertEqual(values(master, "ControlMaster"), ["ControlMaster=yes"])
        XCTAssertEqual(values(master, "ControlPath"), ["ControlPath=/tmp/uh-x/c"])
        XCTAssertEqual(values(master, "ControlPersist"), ["ControlPersist=no"])
        let client = try configured.sshArguments(control: .client("/tmp/uh-x/c"))
        XCTAssertEqual(values(client, "ControlMaster"), ["ControlMaster=no"])
        XCTAssertEqual(values(client, "ControlPath"), ["ControlPath=/tmp/uh-x/c"])
        XCTAssertTrue(client.contains("BatchMode=yes") && client.contains("StrictHostKeyChecking=yes"))
        let shellWords = RemoteShell(profile: configured, ssh: "/bin/echo", controlPath: "/tmp/uh-x/c")
        let echoed = try await shellWords.run("true", [])
        XCTAssertTrue(String(decoding: echoed.stdout, as: UTF8.self).contains("ControlPath=/tmp/uh-x/c"))
        XCTAssertTrue(SSHMaster(profile: configured).controlPath.utf8.count < 40)
        // Leftover socket folders: only empty uh-xxxxxxxx folders of this user go.
        let tmp = NSTemporaryDirectory() + "uherdr-stale-\(UUID().uuidString)"
        let fm = FileManager.default
        defer { try? fm.removeItem(atPath: tmp) }
        for name in ["uh-0a1b2c3d", "uh-deadbeef", "uh-nothex!!", "uh-12345", "other"] { try fm.createDirectory(atPath: tmp + "/" + name, withIntermediateDirectories: true) }
        fm.createFile(atPath: tmp + "/uh-deadbeef/c", contents: Data()) // a live master's socket
        // A folder made a moment ago may be another uHerdr's master still connecting.
        XCTAssertEqual(SSHMaster.removeStaleFolders(in: tmp), [])
        XCTAssertEqual(SSHMaster.removeStaleFolders(in: tmp, olderThan: 0), [tmp + "/uh-0a1b2c3d"])
        XCTAssertEqual(Set(try fm.contentsOfDirectory(atPath: tmp)), ["uh-deadbeef", "uh-nothex!!", "uh-12345", "other"])
        // The socket folder is private and really a folder: an existing one is
        // accepted only if it is ours, closed to others, and not a link.
        let owned = tmp + "/uh-00000001"
        XCTAssertTrue(SSHMaster.makePrivateFolder(owned) && SSHMaster.makePrivateFolder(owned))
        chmod(owned, 0o755)
        XCTAssertTrue(!SSHMaster.makePrivateFolder(owned))
        try fm.createSymbolicLink(atPath: tmp + "/uh-00000002", withDestinationPath: owned)
        chmod(owned, 0o700)
        XCTAssertTrue(!SSHMaster.makePrivateFolder(tmp + "/uh-00000002"))
        configured.port = "65536"; XCTAssertTrue(configured.validationError != nil)
        configured.port = "0"; XCTAssertTrue(configured.validationError != nil)
        let suiteName = "dev.herdr.profile-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("/tmp/old.sock", forKey: "socketPath")
        defaults.set("/tmp/herdr", forKey: "herdrExecutable")
        defaults.set("w1", forKey: "selectedSpace:/tmp/old.sock")
        let migrated = DeviceProfile.load(from: defaults, environment: [:], home: "/Users/test", executable: "/bin/herdr")
        XCTAssertEqual(migrated[0].kind, .local)
        XCTAssertEqual(migrated[0].socketPath, "/tmp/old.sock")
        XCTAssertEqual(migrated[0].executable, "/tmp/herdr")
        XCTAssertEqual(defaults.string(forKey: "selectedSpace:\(migrated[0].id.uuidString)"), "w1")
        let devices = migrated + [profile]
        defaults.set(try JSONEncoder().encode(devices), forKey: DeviceProfile.preferencesKey)
        XCTAssertEqual(DeviceProfile.load(from: defaults, environment: [:], home: "/unused", executable: "/unused"), devices)

        let output = try await ManagedProcess(executable: "/bin/sh", arguments: ["-c", "printf hello; printf diagnostic >&2"]).result()
        XCTAssertEqual(output, "hello")
        // Output keeps its last `outputLimit` bytes; a negative limit keeps none instead of trapping.
        XCTAssertEqual(try await ManagedProcess(executable: "/bin/sh", arguments: ["-c", "printf hello"], outputLimit: 3).result(), "llo")
        XCTAssertEqual(try await ManagedProcess(executable: "/bin/sh", arguments: ["-c", "printf hello"], outputLimit: -1).result(), "")
        do {
            _ = try await ManagedProcess(executable: "/bin/sh", arguments: ["-c", "printf 'Permission denied' >&2; exit 255"]).result()
            XCTFail("Nonzero exit must fail")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Permission denied")) }
        let slow = try ManagedProcess(executable: "/bin/sleep", arguments: ["10"])
        do { _ = try await slow.result(timeout: 0.05); XCTFail("Expected timeout") }
        catch { XCTAssertTrue(error.localizedDescription.contains("timed out")) }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(!slow.isRunning)
        let cancelled = try ManagedProcess(executable: "/bin/sleep", arguments: ["10"])
        let task = Task { try await cancelled.result() }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(!cancelled.isRunning)
        try await testTunnels()
        print("PASS: device profiles, migration, SSH validation, process output/errors, timeout and cancellation")
    }

    @MainActor static func testTunnels() async throws {
        let fixture = FileManager.default.currentDirectoryPath + "/Tests/Fixtures/ssh-fixture.py"
        let first = SSHTunnel(sshExecutable: fixture), second = SSHTunnel(sshExecutable: fixture)
        defer { first.stop(); second.stop() }
        var profile = DeviceProfile(name: "Fixture", host: "fixture.test", executable: "/tmp/herdr")
        let one = try await first.connect(profile)
        let two = try await second.connect(profile)
        XCTAssertTrue(one != two)
        XCTAssertTrue(FileManager.default.fileExists(atPath: DeviceProfile.clientSocketPath(for: one)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: DeviceProfile.clientSocketPath(for: two)))
        XCTAssertEqual(first.remoteHome, "/Users/remote")
        XCTAssertEqual(try await first.connect(profile), one)
        let permissions = try FileManager.default.attributesOfItem(atPath: (one as NSString).deletingLastPathComponent)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o700)
        first.stop()
        XCTAssertTrue(!FileManager.default.fileExists(atPath: one))
        XCTAssertTrue(!FileManager.default.fileExists(atPath: DeviceProfile.clientSocketPath(for: one)))
        XCTAssertTrue(second.isRunning)
        second.stop()
        XCTAssertTrue(!FileManager.default.fileExists(atPath: two))
        for (host, diagnostic) in [("denied.test", "Host key verification failed"), ("forward-failure.test", "local forwarding")] {
            profile.host = host
            do { _ = try await first.connect(profile); XCTFail("Expected fixture failure") }
            catch { XCTAssertTrue(error.localizedDescription.contains(diagnostic)) }
            XCTAssertEqual(first.localSocket, nil)
            XCTAssertTrue(!first.isRunning)
        }
        profile.host = "slow.test"
        let slowProfile = profile
        let pending = Task { try await first.connect(slowProfile) }
        try await Task.sleep(for: .milliseconds(100))
        pending.cancel(); first.stop()
        _ = try? await pending.value
        XCTAssertTrue(!first.isRunning)
        XCTAssertEqual(first.localSocket, nil)
        profile.host = "fixture.test"
        _ = try await first.connect(profile)
        XCTAssertTrue(first.isRunning)
        print("PASS: independent tunnels, reuse, private sockets, cleanup, SSH errors, cancellation and reconnect")
    }
}
