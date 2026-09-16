import Foundation

/// Owns files until the receiving pane accepts their paths. Local drops have
/// nothing to discard; rejected or cancelled remote drops remove their staging.
@MainActor
public struct PreparedFileDrop {
    public let paths: [String]
    private let discardAction: (() async -> Void)?

    public init(paths: [String], discard: (() async -> Void)? = nil) {
        self.paths = paths
        self.discardAction = discard
    }

    public func discard() async {
        guard let discardAction else { return }
        // Cleanup must run even when its caller is already cancelled.
        let cleanup = Task { await discardAction() }
        await cleanup.value
    }
}

/// Streams file bytes over a separate SSH channel; never writes shell commands
/// into the pane, whose foreground process may be an agent or an editor.
@MainActor
public final class RemoteFileTransfer {
    private let sshExecutable: String

    public init(sshExecutable: String = "/usr/bin/ssh") {
        self.sshExecutable = sshExecutable
    }

    public func upload(_ urls: [URL], to profile: DeviceProfile) async throws -> PreparedFileDrop {
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
        let sshExecutable = self.sshExecutable
        let discard: () async -> Void = {
            do {
                let child = try ManagedProcess(executable: sshExecutable,
                    arguments: options + ["--", profile.host, "rm -rf \(Self.quote(directory))"])
                _ = try await child.result(timeout: 12)
            } catch { /* Best effort if the remote device is unreachable. */ }
        }
        do {
            try await run("umask 077; mkdir \(Self.quote(directory))")
            var paths: [String] = []
            for (index, url) in urls.enumerated() {
                try Task.checkCancellation()
                let parent = directory + "/\(index)"
                let path = parent + "/" + url.lastPathComponent
                try await run("umask 077; mkdir \(Self.quote(parent)) && cat > \(Self.quote(path))", input: inputs[index])
                paths.append(path)
            }
            try Task.checkCancellation()
            return PreparedFileDrop(paths: paths, discard: discard)
        } catch {
            await PreparedFileDrop(paths: [], discard: discard).discard()
            throw error
        }
    }

    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
