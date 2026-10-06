import Foundation

/// Asks Git which entries of one folder its ignore rules cover, so the tree
/// can dim them (or hide them when Ignored is off). Outside a repository, or
/// without Git, nothing is ignored.
public enum GitIgnoreCheck {
    public static let gitPath = "/usr/bin/git"

    /// The environment for every Git command the sidebar runs: the user's
    /// GIT_* variables (GIT_DIR, GIT_INDEX_FILE, …) could point Git at another
    /// repository, and a pager or fsmonitor must never start.
    public static func environment(_ base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var env = base.filter { !$0.key.hasPrefix("GIT_") }
        env["GIT_PAGER"] = "cat"
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_OPTIONAL_LOCKS"] = "0"
        return env
    }

    public static func ignoredNames(_ names: [String], in directory: String, git: String = gitPath) async -> Set<String> {
        let candidates = names.filter { !$0.contains("\0") && !$0.isEmpty }
        guard !candidates.isEmpty, FileManager.default.isExecutableFile(atPath: git) else { return [] }
        var input = Data()
        for name in candidates { input.append(Data(name.utf8)); input.append(0) }
        guard let result = try? await StreamingProcess.run(
            executable: git,
            arguments: ["--no-pager", "-c", "core.fsmonitor=false", "-C", directory, "check-ignore", "-z", "--stdin"],
            environment: environment(), input: input, maxBytes: 16 << 20, timeout: .seconds(10)),
              result.status == 0 else { return [] } // 1: nothing ignored; 128: not a repository
        let paths = result.stdout.split(separator: 0, omittingEmptySubsequences: true).map { String(decoding: $0, as: UTF8.self) }
        return Set(paths).intersection(candidates)
    }

    /// Args: the folder. Names arrive on stdin, NUL-separated. No Git or no
    /// repository means nothing is ignored (exit 0, empty output).
    static let remoteScript = GitChangesReader.preamble.replacingOccurrences(of: "|| exit 20", with: "|| exit 0") + "\n" + #"""
    cd "$1" 2>/dev/null || exit 0
    git --no-pager -c core.fsmonitor=false check-ignore -z --stdin
    s=$?
    [ "$s" -le 1 ] && exit 0
    exit 0
    """#

    /// The same on an SSH device, in one call per folder.
    public static func ignoredNames(_ names: [String], in directory: String, shell: RemoteShell) async -> Set<String> {
        let candidates = names.filter { !$0.contains("\0") && !$0.isEmpty }
        guard !candidates.isEmpty else { return [] }
        var input = Data()
        for name in candidates { input.append(Data(name.utf8)); input.append(0) }
        guard let result = try? await shell.run(remoteScript, [directory], input: input, maxBytes: 16 << 20, timeout: .seconds(15)),
              result.status == 0 else { return [] }
        let paths = result.stdout.split(separator: 0, omittingEmptySubsequences: true).map { String(decoding: $0, as: UTF8.self) }
        return Set(paths).intersection(candidates)
    }
}
