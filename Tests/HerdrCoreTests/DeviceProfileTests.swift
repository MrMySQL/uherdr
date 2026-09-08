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
