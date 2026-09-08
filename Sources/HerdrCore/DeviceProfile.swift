import Foundation

public struct DeviceProfile: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable { case local, ssh }
    public var id: UUID
    public var name: String
    public var kind: Kind
    public var host: String
    public var user: String
    public var port: String
    public var identityFile: String
    /// Empty for SSH means discover the remote user's default socket.
    public var socketPath: String
    public var executable: String

    public init(id: UUID = UUID(), name: String, kind: Kind = .ssh, host: String = "", user: String = "", port: String = "", identityFile: String = "", socketPath: String = "", executable: String) {
        self.id = id; self.name = name; self.kind = kind; self.host = host
        self.user = user; self.port = port; self.identityFile = identityFile
        self.socketPath = socketPath; self.executable = executable
    }

    public var validationError: String? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Enter a device name." }
        if !executable.hasPrefix("/") && !executable.hasPrefix("~/") { return "Enter the local herdr executable's full path." }
        if executable.contains(where: { $0.isNewline || $0 == "\0" }) { return "Invalid executable path." }
        if kind == .local {
            if !socketPath.hasPrefix("/") && !socketPath.hasPrefix("~/") { return "Enter the local socket's full path." }
        } else {
            if host.range(of: #"^[A-Za-z0-9_][A-Za-z0-9_.:@%\[\]-]*$"#, options: .regularExpression) == nil { return "Enter an SSH host or alias, such as alex@mac-mini.local." }
            if !user.isEmpty && user.range(of: #"^[A-Za-z0-9_][A-Za-z0-9_.-]*$"#, options: .regularExpression) == nil { return "Enter a valid SSH username." }
            if !user.isEmpty && host.contains("@") { return "Set the username either in the host or in Username, not both." }
            if !port.isEmpty && (Int(port).map { (1...65535).contains($0) } != true) { return "SSH port must be between 1 and 65535." }
            if !identityFile.isEmpty && !identityFile.hasPrefix("/") && !identityFile.hasPrefix("~/") { return "Enter the identity file's full local path." }
            if identityFile.contains(where: { $0.isNewline || $0 == "\0" }) { return "Invalid identity file path." }
            if !socketPath.isEmpty && !socketPath.hasPrefix("/") && !socketPath.hasPrefix("~/") { return "Use an absolute remote socket path, ~/…, or leave it empty for automatic discovery." }
            if socketPath.contains(":") { return "The forwarded socket path cannot contain a colon." }
        }
        if socketPath.contains(where: { $0.isNewline || $0 == "\0" }) { return "Invalid socket path." }
        return nil
    }

    public func sshArguments() throws -> [String] {
        if let error = validationError { throw HerdrError.message(error) }
        var args = ["-T", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
                    "-o", "ConnectTimeout=8", "-o", "ConnectionAttempts=1",
                    "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=2",
                    "-o", "ControlMaster=no", "-o", "ControlPath=none",
                    "-o", "ForkAfterAuthentication=no", "-o", "PermitLocalCommand=no",
                    "-o", "ForwardAgent=no", "-o", "ForwardX11=no", "-o", "RemoteCommand=none"]
        if !user.isEmpty { args += ["-l", user] }
        if !port.isEmpty { args += ["-p", port] }
        if !identityFile.isEmpty { args += ["-i", (identityFile as NSString).expandingTildeInPath] }
        return args
    }

    public func resolvedRemoteSocket(home: String, discoveredSocket: String) throws -> String {
        let path = socketPath.isEmpty ? discoveredSocket : socketPath
        let resolved = path.hasPrefix("~/") ? home + String(path.dropFirst()) : path
        guard resolved.hasPrefix("/"), !resolved.contains(":"), !resolved.contains(where: { $0.isNewline || $0 == "\0" }), resolved.utf8.count < 104, Self.clientSocketPath(for: resolved).utf8.count < 104 else {
            throw HerdrError.message("The remote socket must be an absolute Unix socket path shorter than 104 bytes, without colons.")
        }
        return resolved
    }

    /// Herdr derives its binary terminal socket from the API filename's stem.
    public static func clientSocketPath(for apiSocket: String) -> String {
        (apiSocket as NSString).deletingPathExtension + "-client.sock"
    }

    public static let preferencesKey = "deviceProfiles.v1"

    public static func load(from defaults: UserDefaults, environment: [String: String], home: String, executable: String) -> [DeviceProfile] {
        if let data = defaults.data(forKey: preferencesKey),
           let profiles = try? JSONDecoder().decode([DeviceProfile].self, from: data),
           !profiles.isEmpty, Set(profiles.map(\.id)).count == profiles.count {
            return profiles
        }
        let configHome = environment["XDG_CONFIG_HOME"] ?? home + "/.config"
        let socket = environment["HERDR_SOCKET_PATH"] ?? defaults.string(forKey: "socketPath") ?? configHome + "/herdr/herdr.sock"
        let local = DeviceProfile(name: "This Mac", kind: .local, socketPath: socket, executable: defaults.string(forKey: "herdrExecutable") ?? executable)
        // Preserve selection when migrating the original single-device preferences.
        for key in ["selectedSpace", "selectedTab"] {
            if let value = defaults.string(forKey: "\(key):\(socket)") { defaults.set(value, forKey: "\(key):\(local.id.uuidString)") }
        }
        return [local]
    }
}
