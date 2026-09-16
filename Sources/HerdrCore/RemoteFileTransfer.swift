import Foundation

/// Streams file bytes over a separate SSH channel; never writes shell commands
/// into the pane, whose foreground process may be an agent or an editor.
@MainActor
public final class RemoteFileTransfer {
    private let sshExecutable: String

    public init(sshExecutable: String = "/usr/bin/ssh") {
        self.sshExecutable = sshExecutable
    }

    public func upload(_ urls: [URL], to profile: DeviceProfile) async throws -> [String] {
        let options = try profile.sshArguments()
        guard profile.kind == .ssh, !urls.isEmpty else {
            throw HerdrError.message("Choose files to upload to an SSH device.")
        }
        // Validate the whole batch before starting a remote transfer. Open handles
        // also keep source files available for the duration of the upload.
        var inputs: [FileHandle] = []
        defer { for input in inputs { try? input.close() } }
        for url in urls {
            guard url.isFileURL, url.path.rangeOfCharacter(from: .controlCharacters) == nil,
                  try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                throw HerdrError.message("Drop regular files with names that contain no control characters. Folders are not supported for remote uploads.")
            }
            inputs.append(try FileHandle(forReadingFrom: url))
        }
        try Task.checkCancellation()
        let directory = "/tmp/herdr-drop-\(UUID().uuidString)"
        func run(_ command: String, input: FileHandle = .nullDevice) async throws {
            let child = try ManagedProcess(executable: sshExecutable,
                arguments: options + ["--", profile.host, command], standardInput: input)
            _ = try await child.result(timeout: 300)
        }
        try await run("umask 077; mkdir \(Self.quote(directory))")
        do {
            var paths: [String] = []
            for (index, url) in urls.enumerated() {
                try Task.checkCancellation()
                let parent = directory + "/\(index)"
                let path = parent + "/" + url.lastPathComponent
                try await run("umask 077; mkdir \(Self.quote(parent)) && cat > \(Self.quote(path))", input: inputs[index])
                paths.append(path)
            }
            try Task.checkCancellation()
            return paths
        } catch {
            // This directory is exclusively owned by this upload. A fresh task
            // can clean it up even if the transfer task itself was cancelled.
            let cleanup = Task {
                let child = try ManagedProcess(executable: sshExecutable,
                    arguments: options + ["--", profile.host, "rm -rf \(Self.quote(directory))"])
                _ = try await child.result(timeout: 12)
            }
            _ = try? await cleanup.value
            throw error
        }
    }

    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
