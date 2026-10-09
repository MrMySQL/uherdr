import Foundation
import HerdrCore

enum LineDiffTests {
    static func run() {
        typealias L = LineDiff.Line
        XCTAssertEqual(LineDiff.compare("a\nb\nc\n", "a\nb\nc\n"), [L(.same, "a", old: 1, new: 1), L(.same, "b", old: 2, new: 2), L(.same, "c", old: 3, new: 3)])
        XCTAssertEqual(LineDiff.compare("a\nb\nc\n", "a\nX\nc\nd\n"), [
            L(.same, "a", old: 1, new: 1), L(.removed, "b", old: 2, new: nil), L(.added, "X", old: nil, new: 2),
            L(.same, "c", old: 3, new: 3), L(.added, "d", old: nil, new: 4),
        ])
        XCTAssertEqual(LineDiff.compare("", "x"), [L(.added, "x", old: nil, new: 1)])
        XCTAssertEqual(LineDiff.compare("x\r\ny", "x\ny"), [L(.same, "x", old: 1, new: 1), L(.same, "y", old: 2, new: 2)])
        // Property check against a plain LCS on many random inputs: removed and
        // added lines rebuild both texts, and the number of kept lines is maximal.
        var seed: UInt64 = 42
        func random(_ bound: Int) -> Int { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int((seed >> 33) % UInt64(bound)) }
        func lcs(_ a: [String], _ b: [String]) -> Int {
            var table = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
            for i in 0..<a.count { for j in 0..<b.count { table[i + 1][j + 1] = a[i] == b[j] ? table[i][j] + 1 : max(table[i][j + 1], table[i + 1][j]) } }
            return table[a.count][b.count]
        }
        for _ in 0..<300 {
            let a = (0..<random(12)).map { _ in ["p", "q", "r", "s"][random(4)] }
            let b = (0..<random(12)).map { _ in ["p", "q", "r", "s"][random(4)] }
            let diff = LineDiff.compare(a.joined(separator: "\n"), b.joined(separator: "\n"))
            XCTAssertEqual(diff.filter { $0.kind != .added }.map(\.text), a)
            XCTAssertEqual(diff.filter { $0.kind != .removed }.map(\.text), b)
            XCTAssertEqual(diff.filter { $0.kind == .same }.count, lcs(a, b))
            XCTAssertEqual(diff.compactMap(\.old), Array(1...max(1, a.count)).prefix(a.count).map { $0 })
            XCTAssertEqual(diff.compactMap(\.new), Array(1...max(1, b.count)).prefix(b.count).map { $0 })
        }
        // Too different: falls back to removed-then-added, still complete.
        let fallback = LineDiff.compare("a\nb", "c\nd", maxEdits: 1)
        XCTAssertEqual(fallback.map(\.kind), [.removed, .removed, .added, .added])
        // Budgets force the complete fallback before trace/work growth.
        for budget in [LineDiff.Budget(traceBytes: 240), LineDiff.Budget(steps: 1)] {
            let result = LineDiff.compare("same\nx", "same\ny", budget: budget)
            XCTAssertEqual(result.map(\.kind), [.removed, .removed, .added, .added])
        }
        XCTAssertEqual(LineDiff.compare("x", "y", isCancelled: { true }), [])
        XCTAssertEqual(LineDiff.compare(String(repeating: "x\n", count: LineDiff.maximumLines + 1), "y"), [])
        let large = LineDiff.compare((0..<10_000).map { "old\($0)" }.joined(separator: "\n"),
                                     (0..<10_000).map { "new\($0)" }.joined(separator: "\n"))
        XCTAssertEqual(large.count, 20_000)
        XCTAssertTrue(large.prefix(10_000).allSatisfy { $0.kind == .removed })
        print("PASS: line diff: equal, changed, added, empty, CRLF, 300 random cases rebuild both texts with a maximal common part, fallback")
    }
}
