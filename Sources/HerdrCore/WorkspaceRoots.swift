import Foundation

/// The folder each space's Files, Changes and Search work in. herdr keeps no
/// workspace directory (a pane's cwd follows `cd`), so uHerdr remembers it
/// itself, one list per device profile.
public struct WorkspaceRoots: Codable, Equatable, Sendable {
    public static func preferencesKey(profile: UUID) -> String { "workspaceRoots:\(profile.uuidString)" }

    private var paths: [String: String] = [:]

    public init() {}

    public func root(for workspaceID: String) -> String? { paths[workspaceID] }

    /// Stored exactly as given: a folder's name may end in a space.
    public mutating func remember(_ path: String, for workspaceID: String) {
        guard !path.isEmpty else { return }
        paths[workspaceID] = path
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
    /// outside a repository), the folder itself and the home folder with
    /// links resolved, NUL-separated.
    static let script = #"""
    for v in $(env | sed -n 's/^\(GIT_[A-Za-z0-9_]*\)=.*/\1/p'); do unset "$v"; done
    export GIT_OPTIONAL_LOCKS=0 LC_ALL=C
    cd "$1" 2>/dev/null || exit 21
    t=""
    command -v git >/dev/null 2>&1 && t=$(git -c core.fsmonitor=false rev-parse --show-toplevel 2>/dev/null && echo .) && t=${t%?.}
    p=$(pwd -P && echo .); p=${p%?.}
    h=$(cd "$HOME" 2>/dev/null && pwd -P && echo .); h=${h%?.}
    printf '%s\0%s\0%s' "$t" "$p" "$h"
    """#

    public static func folder(for directory: String, home: String, runner: ScriptRunner) async -> String? {
        guard directory.hasPrefix("/"),
              let result = try? await runner.run(script, [directory], maxBytes: 64 << 10, timeout: .seconds(15)),
              result.status == 0 else { return nil }
        let parts = result.stdout.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        guard parts.count == 3 else { return nil }
        // The guesses have links resolved; so must home, or a linked home
        // (/home → /usr/home) would pass as an ordinary folder.
        let homes = [home, parts[2]].filter { !$0.isEmpty }
        return [parts[0], parts[1]].first { guess in !guess.isEmpty && !homes.contains { isTooBroad(guess, home: $0) } }
    }

    /// "/", the home folder, or any folder that contains home.
    public static func isTooBroad(_ path: String, home: String) -> Bool {
        let path = normalize(path), home = normalize(home)
        return path == "/" || path == home || home.hasPrefix(path + "/")
    }

    /// Removes "." and resolves ".." lexically.
    static func normalize(_ path: String) -> String {
        var parts: [Substring] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." { if !parts.isEmpty { parts.removeLast() }; continue }
            parts.append(part)
        }
        return "/" + parts.joined(separator: "/")
    }
}
