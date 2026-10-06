import Foundation

/// Quick Open's ranking. Every query character must appear in order in the
/// path (case-insensitive). Matches in the file name beat matches in folders;
/// consecutive characters and starts of words (after "/", "_", "-", ".", a
/// space or a lower-to-upper change) score extra.
public enum FuzzyMatcher {
    public struct Match: Equatable, Sendable {
        public let path: String
        public let score: Int
        /// Matched positions as offsets into the path's Characters, for highlighting.
        public let positions: [Int]
    }

    public static func match(_ query: String, _ path: String) -> Match? {
        let needle = Array(query.lowercased().filter { !$0.isWhitespace })
        guard !needle.isEmpty else { return Match(path: path, score: 0, positions: []) }
        let chars = Array(path)
        let lower = chars.map { $0.lowercased().first ?? $0 } // one Character each, so offsets line up
        let nameStart = (chars.lastIndex(of: "/").map { $0 + 1 }) ?? 0
        // Prefer a match that lies entirely in the file name; otherwise take the
        // leftmost match of the whole path.
        let positions = find(needle, in: lower, original: chars, from: nameStart) ?? find(needle, in: lower, original: chars, from: 0)
        guard let positions else { return nil }
        var score = 0
        for (i, position) in positions.enumerated() {
            score += 1
            if position >= nameStart { score += 2 }
            if i > 0, positions[i - 1] == position - 1 { score += 5 }
            if isWordStart(chars, position) { score += 4 }
        }
        if positions.first == nameStart { score += 6 }
        score -= chars.count / 12 // shorter paths win ties
        return Match(path: path, score: score, positions: positions)
    }

    /// Ranks paths for a query; `open` paths come first among equal matches
    /// (with an empty query every path scores 0, so open files lead).
    public static func rank(_ query: String, _ paths: [String], open: Set<String> = [], limit: Int = 50) -> [Match] {
        let matches = paths.compactMap { match(query, $0) }
        return Array(matches.sorted { a, b in
            let aOpen = open.contains(a.path), bOpen = open.contains(b.path)
            if a.score != b.score { return a.score > b.score }
            if aOpen != bOpen { return aOpen }
            return a.path.localizedStandardCompare(b.path) == .orderedAscending
        }.prefix(limit))
    }

    /// Greedy search for the needle, preferring word starts: each character
    /// first looks for a word-start occurrence before the next plain one would
    /// be used, as long as the rest of the needle still fits after it.
    private static func find(_ needle: [Character], in hay: [Character], original: [Character], from start: Int) -> [Int]? {
        var positions: [Int] = []
        var index = start
        for (n, c) in needle.enumerated() {
            guard let plain = hay[index...].firstIndex(of: c) else { return nil }
            var chosen = plain
            // A word start for this character, if the remaining needle still fits after it.
            if let boundary = hay[plain...].indices.first(where: { hay[$0] == c && isWordStart(original, $0) }),
               boundary != plain, fits(needle[(n + 1)...], in: hay, after: boundary),
               !(positions.last.map { $0 == plain - 1 } ?? false) {
                chosen = boundary
            }
            positions.append(chosen)
            index = chosen + 1
        }
        return positions
    }

    private static func fits(_ rest: ArraySlice<Character>, in hay: [Character], after position: Int) -> Bool {
        var index = position + 1
        for c in rest {
            guard index <= hay.count, let found = hay[index...].firstIndex(of: c) else { return false }
            index = found + 1
        }
        return true
    }

    private static func isWordStart(_ chars: [Character], _ position: Int) -> Bool {
        guard position > 0 else { return true }
        let previous = chars[position - 1]
        if "/_-. ".contains(previous) { return true }
        return previous.isLowercase && chars[position].isUppercase
    }
}
