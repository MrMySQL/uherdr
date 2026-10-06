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
