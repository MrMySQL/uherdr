import Foundation

/// What the right sidebar remembers per space (C03): its tab, the folders
/// open in Files (relative to the space folder), and the search with its
/// options. Kept per device; spaces herdr no longer lists are forgotten.
public struct SidebarMemory: Codable, Equatable, Sendable {
    public var tab: String
    public var expanded: [String]
    public var search: Search

    public struct Search: Codable, Equatable, Sendable {
        public var query = ""
        public var caseSensitive = false
        public var wholeWord = false
        public var include = ""
        public var exclude = ""
        public init(query: String = "", caseSensitive: Bool = false, wholeWord: Bool = false, include: String = "", exclude: String = "") {
            self.query = query; self.caseSensitive = caseSensitive; self.wholeWord = wholeWord; self.include = include; self.exclude = exclude
        }
    }

    public init(tab: String = "files", expanded: [String] = [], search: Search = Search()) {
        self.tab = tab; self.expanded = expanded; self.search = search
    }

    public static func key(profile: UUID) -> String { "sidebarMemory:\(profile.uuidString)" }

    public static func load(profile: UUID, from defaults: UserDefaults) -> [String: SidebarMemory] {
        guard let data = defaults.data(forKey: key(profile: profile)),
              let all = try? JSONDecoder().decode([String: SidebarMemory].self, from: data) else { return [:] }
        return all
    }

    /// Saves one space's memory (nil forgets it).
    public static func save(_ memory: SidebarMemory?, space: String, profile: UUID, to defaults: UserDefaults) {
        var all = load(profile: profile, from: defaults)
        guard all[space] != memory else { return }
        all[space] = memory
        if all.isEmpty { defaults.removeObject(forKey: key(profile: profile)); return }
        if let data = try? JSONEncoder().encode(all) { defaults.set(data, forKey: key(profile: profile)) }
    }

    /// Forgets spaces herdr no longer lists. Returns whether anything changed.
    @discardableResult
    public static func prune(keeping spaces: Set<String>, profile: UUID, in defaults: UserDefaults) -> Bool {
        let all = load(profile: profile, from: defaults)
        let kept = all.filter { spaces.contains($0.key) }
        guard kept.count != all.count else { return false }
        if kept.isEmpty { defaults.removeObject(forKey: key(profile: profile)) }
        else if let data = try? JSONEncoder().encode(kept) { defaults.set(data, forKey: key(profile: profile)) }
        return true
    }
}
