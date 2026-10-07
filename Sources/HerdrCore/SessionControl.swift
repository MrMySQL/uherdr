import Foundation

/// Stops and deletes local herdr sessions through the herdr CLI, which owns
/// their lifecycle. A device's session is found by its socket in
/// `herdr session list`, never guessed from the path.
public enum SessionControl {
    /// Runs the herdr CLI and returns its output; throws with herdr's own error.
    public typealias Runner = @MainActor ([String]) async throws -> String

    @MainActor public static func runner(executable: String, environment: [String: String]? = nil) -> Runner {
        { arguments in
            var env = environment ?? ProcessInfo.processInfo.environment
            // A session name is explicit; an inherited session must not redirect it.
            env.removeValue(forKey: "HERDR_SESSION")
            env.removeValue(forKey: "HERDR_SOCKET_PATH")
            // `session list` can pass ManagedProcess's default 16 KB bound.
            let process = try ManagedProcess(executable: (executable as NSString).expandingTildeInPath,
                                             arguments: arguments, environment: env, outputLimit: 1 << 20)
            return try await process.result(timeout: 20)
        }
    }

    /// The listed session whose socket this device uses, if any.
    public static func session(for profile: DeviceProfile, in sessions: [HerdrSessionEntry]) -> HerdrSessionEntry? {
        guard profile.kind == .local else { return nil }
        let socket = SessionDiscovery.normalized(profile.socketPath)
        return sessions.first { SessionDiscovery.normalized($0.socketPath) == socket }
    }

    /// How to start a local device's server. herdr serves a named session
    /// only with `--session <name>`: a bare `herdr server` uses the default
    /// session's data whatever socket it listens on. Inherited `HERDR_*`
    /// variables (a herdr pane's session, socket and pane ids) are dropped,
    /// except `HERDR_CONFIG_PATH`.
    public struct ServerLaunch: Equatable, Sendable {
        public let arguments: [String]
        public let environment: [String: String]
        public init(arguments: [String], environment: [String: String]) {
            self.arguments = arguments
            self.environment = environment
        }
    }

    /// Nil for a remote device, or a herdr session socket missing from
    /// `sessions`: a bare server there would serve the default session's data.
    public static func serverLaunch(for profile: DeviceProfile, in sessions: [HerdrSessionEntry],
                                    environment: [String: String]) -> ServerLaunch? {
        guard profile.kind == .local else { return nil }
        // HERDR_CONFIG_PATH is the user's config override, not pane state.
        var env = environment.filter { !$0.key.hasPrefix("HERDR_") || $0.key == "HERDR_CONFIG_PATH" }
        if let entry = session(for: profile, in: sessions) {
            return ServerLaunch(arguments: entry.isDefault ? ["server"] : ["--session", entry.name, "server"], environment: env)
        }
        guard profile.pathSessionName == nil else { return nil }
        // A custom socket that herdr doesn't list as a session.
        env["HERDR_SOCKET_PATH"] = SessionDiscovery.normalized(profile.socketPath)
        return ServerLaunch(arguments: ["server"], environment: env)
    }

    /// herdr refuses to delete its default session.
    public static func canDelete(_ session: HerdrSessionEntry) -> Bool { !session.isDefault }

    @MainActor public static func list(_ run: Runner) async throws -> [HerdrSessionEntry] {
        try SessionDiscovery.parse(try await run(["session", "list", "--json"]))
    }

    @MainActor public static func stop(_ name: String, _ run: Runner) async throws {
        _ = try await run(["session", "stop", name])
    }

    /// Stops a running session first: herdr deletes only stopped sessions.
    @MainActor public static func delete(_ session: HerdrSessionEntry, _ run: Runner) async throws {
        guard canDelete(session) else { throw HerdrError.message("herdr can't delete its default session.") }
        if session.running { try await stop(session.name, run) }
        _ = try await run(["session", "delete", session.name])
    }
}
