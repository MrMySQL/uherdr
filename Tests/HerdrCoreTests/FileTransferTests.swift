import Foundation
import HerdrCore

enum FileTransferTests {
    @MainActor static func run() async throws {
        let root = URL(fileURLWithPath: "/tmp/herdr-transfer-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let name = "it's $draft; café.png"
        let first = root.appendingPathComponent(name)
        let secondDir = root.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: secondDir, withIntermediateDirectories: false)
        let second = secondDir.appendingPathComponent(name)
        let bytes = Data((0..<262144).map { UInt8($0 % 256) })
        try bytes.write(to: first)
        try Data("second file".utf8).write(to: second)
        let transfer = RemoteFileTransfer(sshExecutable: FileManager.default.currentDirectoryPath + "/Tests/Fixtures/ssh-upload-fixture.py")
        let profile = DeviceProfile(name: "Upload fixture", host: "upload.test", user: "tester", port: "2222", executable: "/bin/herdr")
        let paths = try await transfer.upload([first, second], to: profile)
        defer { try? FileManager.default.removeItem(at: URL(fileURLWithPath: paths[0]).deletingLastPathComponent().deletingLastPathComponent()) }
        precondition(paths.count == 2 && paths[0] != paths[1], "Duplicate filenames must not overwrite each other")
        precondition(paths[0] != first.path, "Remote drops must transfer bytes, not return the local path")
        let uploadedBytes = try Data(contentsOf: URL(fileURLWithPath: paths[0]))
        let uploadedText = try String(contentsOfFile: paths[1])
        precondition(uploadedBytes == bytes)
        precondition(uploadedText == "second file")
        precondition(URL(fileURLWithPath: paths[0]).lastPathComponent == name)
        let attributes = try FileManager.default.attributesOfItem(atPath: paths[0])
        precondition((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        for urls in [[root], [first, root.appendingPathComponent("missing")], [URL(fileURLWithPath: "/tmp/bad\nname")]] {
            do { _ = try await transfer.upload(urls, to: profile); preconditionFailure("Invalid files must fail") }
            catch { precondition(!(error is CancellationError)) }
        }
        var denied = profile; denied.host = "denied.test"
        do { _ = try await transfer.upload([first], to: denied); preconditionFailure("SSH failures must be reported") }
        catch { precondition(error.localizedDescription.contains("Host key verification failed")) }
        var slow = profile; slow.host = "slow.test"
        let slowProfile = slow
        let task = Task { try await transfer.upload([first], to: slowProfile) }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        do { _ = try await task.value; preconditionFailure("Cancelled transfers must not return paths") }
        catch { precondition(error is CancellationError) }
        print("PASS: remote file bytes, duplicate names, shell quoting, private permissions, invalid files, SSH errors and cancellation")
    }
}
