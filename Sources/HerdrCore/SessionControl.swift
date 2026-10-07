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
