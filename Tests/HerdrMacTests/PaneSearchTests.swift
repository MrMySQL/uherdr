import Foundation

@main
struct PaneSearchTests {
    static func main() {
        var search = PaneSearchMatches(text: "😀 Error error\nERROR .*", query: "error")
        precondition(search.ranges == [NSRange(location: 3, length: 5), NSRange(location: 9, length: 5), NSRange(location: 15, length: 5)], "Matches must ignore case and use UTF-16 offsets for AppKit")
        precondition(search.selectedRange == NSRange(location: 3, length: 5))
        search.move(by: -1)
        precondition(search.selectedRange == NSRange(location: 15, length: 5), "Previous wraps to the last match")
        search.move(by: 1)
        precondition(search.selectedIndex == 0, "Next wraps to the first match")
        precondition(PaneSearchMatches(text: "a .* b", query: ".*").ranges == [NSRange(location: 2, length: 2)], "Queries are literal, not regular expressions")
        precondition(PaneSearchMatches(text: "abc", query: "").ranges.isEmpty)
        var missing = PaneSearchMatches(text: "abc", query: "z")
        missing.move(by: 1)
        precondition(missing.selectedRange == nil)
        precondition(PaneSearchMatches(text: "café cafe\u{301}", query: "café").ranges.count == 2, "Canonical Unicode forms match")
        print("PASS: pane search matching, Unicode offsets, literal queries, empty results, and navigation wrap")
    }
}
