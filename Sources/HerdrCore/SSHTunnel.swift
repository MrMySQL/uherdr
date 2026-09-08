import Foundation

@MainActor
public final class SSHTunnel {
    public private(set) var localSocket: String?
    public private(set) var remoteHome: String?
    private var process: ManagedProcess?
    private var probe: ManagedProcess?
    private var directory: URL?
    private var generation = UUID()
    private let sshExecutable: String

    public init(sshExecutable: String = "/usr/bin/ssh") { self.sshExecutable = sshExecutable }
    public var isRunning: Bool { process?.isRunning == true }

    public func connect(_ profile: DeviceProfile) async throws -> String {
        if isRunning, let localSocket { return localSocket }
        stop()
        let token = generation
        let options = try profile.sshArguments()
        do {
            // A fixed command: no user-provided path or hostname is interpolated into a shell.
            let command = #"printf '\nUHERDR_HOME=%s\nUHERDR_SOCKET=%s\n' "$HOME" "${HERDR_SOCKET_PATH:-${XDG_CONFIG_HOME:-$HOME/.config}/herdr/herdr.sock}""#
            let discovery = try ManagedProcess(executable: sshExecutable, arguments: options + ["--", profile.host, command])
            probe = discovery
            let output = try await discovery.result()
            try Task.checkCancellation()
            guard generation == token else { throw CancellationError() }
            probe = nil
            let lines = output.components(separatedBy: .newlines)
            guard let homeLine = lines.last(where: { $0.hasPrefix("UHERDR_HOME=/") }),
                  let socketLine = lines.last(where: { $0.hasPrefix("UHERDR_SOCKET=/") }) else {
                throw HerdrError.message("Could not discover the remote herdr socket. Check the SSH account's shell configuration.")
            }
            let home = String(homeLine.dropFirst("UHERDR_HOME=".count))
            let socket = try profile.resolvedRemoteSocket(home: home, discoveredSocket: String(socketLine.dropFirst("UHERDR_SOCKET=".count)))
            let dir = URL(fileURLWithPath: "/tmp/uh-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            directory = dir
            let local = dir.appendingPathComponent("herdr.sock").path
            let localClient = DeviceProfile.clientSocketPath(for: local)
            let remoteClient = DeviceProfile.clientSocketPath(for: socket)
            let child = try ManagedProcess(executable: sshExecutable, arguments: options + [
                "-N", "-o", "ExitOnForwardFailure=yes", "-o", "StreamLocalBindMask=0177",
                "-L", "\(local):\(socket)", "-L", "\(localClient):\(remoteClient)", "--", profile.host
            ])
            process = child
            let deadline = Date().addingTimeInterval(12)
            while !FileManager.default.fileExists(atPath: local) || !FileManager.default.fileExists(atPath: localClient) {
                try Task.checkCancellation()
                guard generation == token else { throw CancellationError() }
                guard child.isRunning else {
                    // Let the pipe reader publish the final diagnostic.
                    try await Task.sleep(for: .milliseconds(50))
                    throw HerdrError.message(child.errorText.isEmpty ? "SSH tunnel closed." : child.errorText)
                }
                guard Date() < deadline else { throw HerdrError.message("SSH tunnel timed out.") }
                try await Task.sleep(for: .milliseconds(50))
            }
            guard generation == token else { throw CancellationError() }
            localSocket = local; remoteHome = home
            return local
        } catch {
            if generation == token { stop() }
            throw error
        }
    }

    public func stop() {
        generation = UUID()
        probe?.stop(); probe = nil
        process?.stop(); process = nil
        localSocket = nil; remoteHome = nil
        // Only this instance's newly created private directory is ever removed.
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
    }
}
