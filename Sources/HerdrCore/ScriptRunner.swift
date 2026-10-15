import Foundation

/// Runs one of uHerdr's fixed POSIX scripts on the space's device: through
/// `/bin/sh` on this Mac, or over SSH. Both get the same script and arguments,
/// so a feature behaves the same locally and remotely.
public enum ScriptRunner: Sendable {
    case local
    case remote(RemoteShell)

    public func run(_ script: String, _ arguments: [String], maxBytes: Int = 16 << 20,
                    timeout: Duration = .seconds(30)) async throws -> StreamingProcess.Result {
        switch self {
        case .local:
            guard !arguments.contains(where: { $0.contains("\0") }) else { throw HerdrError.message("A path contains a NUL character.") }
            return try await StreamingProcess.run(executable: "/bin/sh", arguments: ["-c", script, "uherdr"] + arguments,
                                                  environment: Self.localEnvironment, maxBytes: maxBytes, timeout: timeout)
        case let .remote(shell):
            return try await shell.run(script, arguments, maxBytes: maxBytes, timeout: timeout)
        }
    }

    /// Output as it arrives; ending the stream early stops the script. stdin
    /// stays open meanwhile, so a script can watch it: over SSH, ending the
    /// stream closes the session and the remote job sees end-of-file.
    public func events(_ script: String, _ arguments: [String], maxBytes: Int = 16 << 20,
                       timeout: Duration = .seconds(30)) throws -> AsyncThrowingStream<StreamingProcess.Event, Error> {
        switch self {
        case .local:
            guard !arguments.contains(where: { $0.contains("\0") }) else { throw HerdrError.message("A path contains a NUL character.") }
            return StreamingProcess.events(executable: "/bin/sh", arguments: ["-c", script, "uherdr"] + arguments,
                                           environment: Self.localEnvironment, keepInputOpen: true, maxBytes: maxBytes, timeout: timeout)
        case let .remote(shell):
            return try shell.events(script, arguments, maxBytes: maxBytes, timeout: timeout)
        }
    }

    static var localEnvironment: [String: String] {
        var environment = GitIgnoreCheck.environment()
        environment["LC_ALL"] = "C"
        return environment
    }
}
