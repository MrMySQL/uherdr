import Foundation

/// A line-by-line comparison of two texts (Myers' algorithm, as `git diff`
/// uses), for the save conflict's Compare view.
public enum LineDiff {
    public enum Kind: Equatable, Sendable { case same, removed, added }

    public struct Line: Equatable, Sendable {
        public let kind: Kind
        public let text: String
        /// 1-based numbers in the old and the new text; nil where the line doesn't exist.
        public let old: Int?
        public let new: Int?
        public init(_ kind: Kind, _ text: String, old: Int?, new: Int?) {
            self.kind = kind; self.text = text; self.old = old; self.new = new
        }
    }

    public static func lines(of text: String) -> [String] {
        var result = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if result.last == "" { result.removeLast() }
        return result
    }

    /// Every line of both texts in order. Very different inputs (edit distance
    /// above `maxEdits`) fall back to "all removed, then all added".
    public struct Budget: Sendable {
        public var traceBytes: Int
        public var steps: Int
        public init(traceBytes: Int = 16 << 20, steps: Int = 1_000_000) {
            self.traceBytes = traceBytes; self.steps = steps
        }
    }

    public static func compare(_ old: String, _ new: String, maxEdits: Int = 20_000,
                               budget: Budget = Budget(), isCancelled: () -> Bool = { false }) -> [Line] {
        guard !isCancelled() else { return [] }
        let a = lines(of: old), b = lines(of: new)
        let n = a.count, m = b.count
        let maxD = min(n + m, max(0, maxEdits))
        func fallback() -> [Line] {
            a.enumerated().map { Line(.removed, $1, old: $0 + 1, new: nil) }
                + b.enumerated().map { Line(.added, $1, old: nil, new: $0 + 1) }
        }
        let vectorBytes = (2 * maxD + 3) * MemoryLayout<Int>.stride
        guard vectorBytes <= budget.traceBytes / 2, budget.steps > 0 else { return fallback() }
        var steps = 0
        let offset = maxD + 1
        var v = [Int](repeating: 0, count: 2 * maxD + 3)
        var trace: [[Int]] = []
        var found = false
        search: for d in 0...maxD {
            guard !isCancelled() else { return [] }
            guard trace.count + 2 <= budget.traceBytes / vectorBytes else { return fallback() }
            trace.append(v)
            for k in stride(from: -d, through: d, by: 2) {
                guard steps < budget.steps else { return fallback() }
                steps += 1
                var x = (k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1])) ? v[offset + k + 1] : v[offset + k - 1] + 1
                var y = x - k
                while x < n && y < m && a[x] == b[y] {
                    guard !isCancelled() else { return [] }
                    guard steps < budget.steps else { return fallback() }
                    steps += 1; x += 1; y += 1
                }
                v[offset + k] = x
                if x >= n && y >= m { found = true; break search }
            }
        }
        guard found else { return fallback() }
        // Walk the trace back from the end to recover the edit script.
        var result: [Line] = []
        var x = n, y = m
        for d in stride(from: trace.count - 1, through: 0, by: -1) {
            let v = trace[d]
            let k = x - y
            let previousK = (k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1])) ? k + 1 : k - 1
            let previousX = d == 0 ? 0 : v[offset + previousK]
            let previousY = previousX - previousK
            while x > previousX && y > previousY {
                result.append(Line(.same, a[x - 1], old: x, new: y))
                x -= 1; y -= 1
            }
            if d > 0 {
                if x == previousX { result.append(Line(.added, b[y - 1], old: nil, new: y)) }
                else { result.append(Line(.removed, a[x - 1], old: x, new: nil)) }
            }
            x = previousX; y = previousY
        }
        return result.reversed()
    }
}
