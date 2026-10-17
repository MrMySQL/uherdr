import Foundation

/// The folder each space's Files, Changes and Search work in. herdr keeps no
/// workspace directory (a pane's cwd follows `cd`), so uHerdr remembers it
/// itself, one list per device profile.
public struct WorkspaceRoots: Codable, Equatable, Sendable {
    public static func preferencesKey(profile: UUID) -> String { "workspaceRoots:\(profile.uuidString)" }

    private var paths: [String: String] = [:]

    public init() {}

    public func root(for workspaceID: String) -> String? { paths[workspaceID] }

    public mutating func remember(_ path: String, for workspaceID: String) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        paths[workspaceID] = trimmed
    }

    public mutating func forget(_ workspaceID: String) { paths[workspaceID] = nil }

    /// Keeps only spaces the server still lists. herdr never reuses a
    /// workspace ID within a session, so a missing ID is gone for good;
    /// dropping it stops a re-created session's `w1` from inheriting the old
    /// `w1` folder. Returns true when something was dropped.
    @discardableResult
    public mutating func prune(keeping workspaceIDs: Set<String>) -> Bool {
        let before = paths.count
        paths = paths.filter { workspaceIDs.contains($0.key) }
        return paths.count != before
    }

    public static func load(profile: UUID, from defaults: UserDefaults) -> WorkspaceRoots {
        guard let data = defaults.data(forKey: preferencesKey(profile: profile)),
              let roots = try? JSONDecoder().decode(WorkspaceRoots.self, from: data) else { return WorkspaceRoots() }
        return roots
    }

    public func save(profile: UUID, to defaults: UserDefaults) {
        if paths.isEmpty {
            defaults.removeObject(forKey: Self.preferencesKey(profile: profile))
        } else if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: Self.preferencesKey(profile: profile))
        }
    }
}

/// A folder for a space that has none yet (one herdr made, or one from before
/// uHerdr remembered folders): the Git repository around its first terminal's
/// folder, or that folder itself. Never the home folder, "/", or anything
/// above home: a whole home tree is too broad to list and search, and macOS
/// would ask for access to Documents and Desktop.
public enum FolderGuess {
    /// Args: the terminal's folder. Prints the repository's top folder (empty
    /// outside a repository) and the folder itself, NUL-separated.
    static let script = #"""
    for v in $(env | sed -n 's/^\(GIT_[A-Za-z0-9_]*\)=.*/\1/p'); do unset "$v"; done
    export GIT_OPTIONAL_LOCKS=0 LC_ALL=C
    cd "$1" 2>/dev/null || exit 21
    t=""
    command -v git >/dev/null 2>&1 && t=$(git rev-parse --show-toplevel 2>/dev/null && echo .) && t=${t%?.}
    p=$(pwd -P && echo .); p=${p%?.}
    printf '%s\0%s' "$t" "$p"
    """#

    public static func folder(for directory: String, home: String, runner: ScriptRunner) async -> String? {
        guard directory.hasPrefix("/"),
              let result = try? await runner.run(script, [directory], maxBytes: 64 << 10, timeout: .seconds(15)),
              result.status == 0 else { return nil }
        let parts = result.stdout.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        guard parts.count == 2 else { return nil }
        return [parts[0], parts[1]].first { !$0.isEmpty && !isTooBroad($0, home: home) }
    }

    /// "/", the home folder, or any folder that contains home.
    public static func isTooBroad(_ path: String, home: String) -> Bool {
        let path = MarkdownLink.normalize(path), home = MarkdownLink.normalize(home)
        return path == "/" || path == home || home.hasPrefix(path + "/")
    }
}
