import Foundation

struct PaneSearchMatches {
    let ranges: [NSRange]
    private(set) var selectedIndex = 0

    init(text: String = "", query: String = "") {
        let text = text as NSString
        var matches: [NSRange] = []
        if !query.isEmpty {
            var start = 0
            while start < text.length {
                let range = text.range(of: query, options: .caseInsensitive,
                                       range: NSRange(location: start, length: text.length - start))
                guard range.location != NSNotFound, range.length > 0 else { break }
                matches.append(range)
                start = NSMaxRange(range)
            }
        }
        ranges = matches
    }

    var selectedRange: NSRange? { ranges.isEmpty ? nil : ranges[selectedIndex] }

    mutating func move(by offset: Int) {
        guard !ranges.isEmpty else { return }
        selectedIndex = (selectedIndex + offset % ranges.count + ranges.count) % ranges.count
    }
}
