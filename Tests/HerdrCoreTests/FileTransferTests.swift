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
        let prepared = try await transfer.upload([first, second], to: profile)
        let paths = prepared.paths
        defer { try? FileManager.default.removeItem(at: URL(fileURLWithPath: paths[0]).deletingLastPathComponent().deletingLastPathComponent()) }
        precondition(paths.count == 2 && paths[0] != paths[1], "Duplicate filenames must not overwrite each other")
        precondition(paths[0] != first.path, "Remote drops must transfer bytes, not return the local path")
        let uploadedBytes = try Data(contentsOf: URL(fileURLWithPath: paths[0]))
        let uploadedText = try String(contentsOfFile: paths[1], encoding: .utf8)
        precondition(uploadedBytes == bytes)
        precondition(uploadedText == "second file")
        precondition(URL(fileURLWithPath: paths[0]).lastPathComponent == name)
        let attributes = try FileManager.default.attributesOfItem(atPath: paths[0])
        precondition((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        await prepared.discard()
        precondition(!FileManager.default.fileExists(atPath: paths[0]), "Rejected completed uploads must be removable")
        for urls in [[root], [first, root.appendingPathComponent("missing")], [URL(fileURLWithPath: "/tmp/bad\nname")]] {
            do { _ = try await transfer.upload(urls, to: profile); preconditionFailure("Invalid files must fail") }
            catch { precondition(!(error is CancellationError)) }
        }
        var denied = profile; denied.host = "denied.test"
        do { _ = try await transfer.upload([first], to: denied); preconditionFailure("SSH failures must be reported") }
        catch { precondition(error.localizedDescription.contains("Host key verification failed")) }
        var interrupted = profile; interrupted.host = "setup-failure.test"
        do { _ = try await transfer.upload([first], to: interrupted); preconditionFailure("Setup must fail") }
        catch {
            let prefix = "SETUP_DIRECTORY="
            guard let start = error.localizedDescription.range(of: prefix) else { throw error }
            let directory = String(error.localizedDescription[start.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            defer { try? FileManager.default.removeItem(atPath: directory) }
            guard !FileManager.default.fileExists(atPath: directory) else {
                throw HerdrError.message("Interrupted root creation left an upload directory behind")
            }
        }
        var slow = profile; slow.host = "slow.test"
        slow.identityFile = root.appendingPathComponent("fixture-key").path
        let marker = slow.identityFile + ".upload-path"
        let slowProfile = slow
        let task = Task { try await transfer.upload([first], to: slowProfile) }
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: marker), Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        precondition(FileManager.default.fileExists(atPath: marker), "Fixture must create its remote directory")
        let directory = try String(contentsOfFile: marker, encoding: .utf8)
        task.cancel()
        do { _ = try await task.value; preconditionFailure("Cancelled transfers must not return paths") }
        catch { precondition(error is CancellationError) }
        precondition(!FileManager.default.fileExists(atPath: directory), "Cancelled setup must remove its directory")
        print("PASS: remote file bytes, duplicate names, shell quoting, private permissions, invalid files, SSH errors and cancellation")
    }
}
