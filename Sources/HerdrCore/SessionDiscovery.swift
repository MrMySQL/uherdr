import Foundation

/// One entry of `herdr session list --json`.
public struct HerdrSessionEntry: Decodable, Equatable, Sendable {
    public let name: String
    public let running: Bool
    public let socketPath: String
    public let isDefault: Bool
    enum CodingKeys: String, CodingKey {
        case name, running, socketPath = "socket_path", isDefault = "default"
    }
}

public enum SessionDiscovery {
    public static let dismissedKey = "dismissedSessionSockets.v1"

    public static func parse(_ output: String) throws -> [HerdrSessionEntry] {
        struct Listing: Decodable { let sessions: [HerdrSessionEntry] }
        return try JSONDecoder().decode(Listing.self, from: Data(output.utf8)).sessions
    }

    /// Asks the local herdr CLI for its named sessions and their sockets.
    /// The listing is read whole (up to 1 MB): a truncated one cannot be parsed.
    @MainActor public static func list(executable: String) async throws -> [HerdrSessionEntry] {
        let process = try ManagedProcess(executable: (executable as NSString).expandingTildeInPath,
                                         arguments: ["session", "list", "--json"], outputLimit: 1 << 20)
        return try parse(try await process.result(timeout: 8))
    }

    /// Socket paths compare after tilde expansion and standardization.
    public static func normalized(_ socket: String) -> String {
        ((socket as NSString).expandingTildeInPath as NSString).standardizingPath
    }

    /// Local profiles for running sessions that no saved device already uses.
    /// Existing profiles are never renamed or changed.
    public static func newProfiles(for sessions: [HerdrSessionEntry], existing: [DeviceProfile],
                                   dismissed: Set<String>, executable: String) -> [DeviceProfile] {
        var used = Set(existing.filter { $0.kind == .local }.map { normalized($0.socketPath) })
        used.formUnion(dismissed.map(normalized))
        var names = Set(existing.map(\.name))
        var result: [DeviceProfile] = []
        for session in sessions where session.running {
            let socket = normalized(session.socketPath)
            guard socket.hasPrefix("/"), used.insert(socket).inserted else { continue }
            var name = session.name, clash = 1
            while names.contains(name) { name = "\(session.name) session\(clash == 1 ? "" : " \(clash)")"; clash += 1 }
            names.insert(name)
            let profile = DeviceProfile(name: name, kind: .local, socketPath: socket, executable: executable)
            if profile.validationError == nil { result.append(profile) }
        }
        return result
    }
}
