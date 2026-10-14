import Foundation

/// Stops and deletes herdr sessions through the herdr CLI, which owns
/// their lifecycle. A device's session is found by its socket in
/// `herdr session list`, never guessed from the path.
public enum SessionControl {
    /// Runs the herdr CLI and returns its output; throws with herdr's own error.
    public typealias Runner = @MainActor ([String]) async throws -> String

    @MainActor public static func runner(executable: String, environment: [String: String]? = nil, timeout: TimeInterval = 20) -> Runner {
        { arguments in
            var env = environment ?? ProcessInfo.processInfo.environment
            // A session name is explicit; an inherited session must not redirect it.
            env.removeValue(forKey: "HERDR_SESSION")
            env.removeValue(forKey: "HERDR_SOCKET_PATH")
            // `session list` can pass ManagedProcess's default 16 KB bound.
            let process = try ManagedProcess(executable: (executable as NSString).expandingTildeInPath,
                                             arguments: arguments, environment: env, outputLimit: 1 << 20)
            return try await process.result(timeout: timeout)
        }
    }

    /// How herdr runs on an SSH device's machine: returning its output,
    /// given ten minutes for `herdr update`, or detached so a server outlives SSH.
    public enum RemoteRun: Sendable { case command, update, detached }

    /// Runs the herdr CLI on an SSH device's machine. A non-interactive SSH
    /// shell often lacks herdr's install directory on PATH, so this also looks
    /// where herdr's installers put it, as herdr's own remote attach does.
    @MainActor public static func remoteRunner(profile: DeviceProfile, run: RemoteRun = .command, sshExecutable: String = "/usr/bin/ssh") -> Runner {
        { arguments in
            let process = try ManagedProcess(executable: sshExecutable,
                                             arguments: try profile.sshArguments() + ["--", profile.host, remoteCommand(arguments, detached: run == .detached)],
                                             outputLimit: 1 << 20)
            let output = try await process.result(timeout: run == .update ? 600 : 30)
            // Drops what the remote shell printed before herdr ran, such as a login banner.
            guard let marker = output.range(of: remoteOutputMarker + "\n") else {
                throw HerdrError.message("herdr’s output over SSH wasn’t readable.")
            }
            return String(output[marker.upperBound...])
        }
    }

    static let remoteOutputMarker = "UHERDR_HERDR_OUTPUT"

    /// A fixed script on one line, so any login shell passes it to `sh`; only
    /// herdr's arguments vary, and they arrive quoted as its positional parameters.
    static func remoteCommand(_ arguments: [String], detached: Bool) -> String {
        let candidates = [#""$(command -v herdr 2>/dev/null)""#, #""$HOME/.local/bin/herdr""#, "/home/linuxbrew/.linuxbrew/bin/herdr",
                          "/opt/homebrew/bin/herdr", "/usr/local/bin/herdr", #""$HOME/.nix-profile/bin/herdr""#,
                          #""/etc/profiles/per-user/$USER/bin/herdr""#, "/nix/var/nix/profiles/default/bin/herdr", "/run/current-system/sw/bin/herdr"]
        let action = detached ? #"nohup "$h" "$@" </dev/null >/dev/null 2>&1 & exit 0"# : #"exec "$h" "$@""#
        let script = "for h in \(candidates.joined(separator: " ")); do case \"$h\" in */mise/shims/herdr) ;; /*) if [ -x \"$h\" ]; then echo \(remoteOutputMarker); \(action); fi ;; esac; done; "
            + "echo \"herdr wasn’t found on this machine. Install it, or add it to the SSH shell’s PATH.\" >&2; exit 127"
        return (["sh", "-c", shellQuote(script), "herdr"] + arguments.map(shellQuote)).joined(separator: " ")
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The listed session whose socket this device uses, if any.
    public static func session(for profile: DeviceProfile, in sessions: [HerdrSessionEntry]) -> HerdrSessionEntry? {
        guard profile.kind == .local else { return nil }
        let socket = SessionDiscovery.normalized(profile.socketPath)
        return sessions.first { SessionDiscovery.normalized($0.socketPath) == socket }
    }

    /// The session an SSH device uses, in its machine's `herdr session list`.
    /// An empty socket is the default session; a herdr session socket names
    /// its session; a custom one is matched by path, `~/` meaning `home`.
    public static func remoteSession(for profile: DeviceProfile, home: String?, in sessions: [HerdrSessionEntry]) -> HerdrSessionEntry? {
        guard profile.kind == .ssh else { return nil }
        if profile.socketPath.isEmpty { return sessions.first(where: \.isDefault) }
        if let name = profile.pathSessionName { return sessions.first { $0.name == name } }
        guard let home, let socket = try? profile.resolvedRemoteSocket(home: home, discoveredSocket: "") else { return nil }
        let path = (socket as NSString).standardizingPath
        return sessions.first { ($0.socketPath as NSString).standardizingPath == path }
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
        var env = serverEnvironment(environment)
        if let entry = session(for: profile, in: sessions) {
            return ServerLaunch(arguments: entry.isDefault ? ["server"] : ["--session", entry.name, "server"], environment: env)
        }
        guard profile.pathSessionName == nil else { return nil }
        // A custom socket that herdr doesn't list as a session.
        env["HERDR_SOCKET_PATH"] = SessionDiscovery.normalized(profile.socketPath)
        return ServerLaunch(arguments: ["server"], environment: env)
    }

    /// `herdr --session <name> server` creates the named session and serves it.
    public static func newSessionLaunch(name: String, environment: [String: String]) -> ServerLaunch {
        ServerLaunch(arguments: ["--session", name, "server"], environment: serverEnvironment(environment))
    }

    /// HERDR_CONFIG_PATH is the user's config override, not pane state.
    static func serverEnvironment(_ environment: [String: String]) -> [String: String] {
        environment.filter { !$0.key.hasPrefix("HERDR_") || $0.key == "HERDR_CONFIG_PATH" }
    }

    /// Why herdr would refuse `name` for a new session, or nil. herdr allows
    /// ASCII letters, digits, '.', '_' and '-', but not "." or "..".
    public static func newSessionNameProblem(_ name: String, existing: [HerdrSessionEntry]) -> String? {
        if name.isEmpty { return "Enter a name for the session." }
        if name == "." || name == ".." { return "A session can’t be named “\(name)”." }
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard name.allSatisfy(allowed.contains) else { return "Use only letters, numbers, “.”, “_” and “-”." }
        if existing.contains(where: { $0.name == name }) { return "A session named “\(name)” already exists." }
        return nil
    }

    /// herdr refuses to delete its default session.
    public static func canDelete(_ session: HerdrSessionEntry) -> Bool { !session.isDefault }

    @MainActor public static func list(_ run: Runner) async throws -> [HerdrSessionEntry] {
        try SessionDiscovery.parse(try await run(["session", "list", "--json"]))
    }

    @MainActor public static func stop(_ name: String, _ run: Runner) async throws {
        _ = try await run(["session", "stop", name])
    }

    /// herdr addresses the default session without `--session`.
    public static func sessionArguments(_ session: HerdrSessionEntry) -> [String] {
        session.isDefault ? [] : ["--session", session.name]
    }

    /// Whether the session's running server can hand its live panes to a new
    /// one; servers from before live handoff don't report the capability.
    @MainActor public static func supportsLiveHandoff(_ session: HerdrSessionEntry, _ run: Runner) async throws -> Bool {
        struct Status: Decodable {
            struct Server: Decodable {
                struct Capabilities: Decodable { let live_handoff: Bool? }
                let running: Bool?
                let capabilities: Capabilities?
            }
            let server: Server
        }
        let output = try await run(sessionArguments(session) + ["status", "--json"])
        guard let status = try? JSONDecoder().decode(Status.self, from: Data(output.utf8)) else {
            throw HerdrError.message("herdr’s status output wasn’t readable.")
        }
        return status.server.running == true && status.server.capabilities?.live_handoff == true
    }

    /// Replaces the session's server with one from the installed herdr. Its
    /// shells and agents keep running; herdr gives their panes new terminal IDs.
    @MainActor public static func liveHandoff(_ session: HerdrSessionEntry, _ run: Runner) async throws {
        _ = try await run(sessionArguments(session) + ["server", "live-handoff"])
    }

    /// Stops a running session first: herdr deletes only stopped sessions.
    @MainActor public static func delete(_ session: HerdrSessionEntry, _ run: Runner) async throws {
        guard canDelete(session) else { throw HerdrError.message("herdr can't delete its default session.") }
        if session.running { try await stop(session.name, run) }
        _ = try await run(["session", "delete", session.name])
    }
}
