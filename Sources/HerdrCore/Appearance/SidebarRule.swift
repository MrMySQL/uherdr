import Foundation

public enum SidebarCondition: Equatable, Sendable {
    case equals(String), contains(String), startsWith(String), gt(Double), lt(Double)
}

public struct SidebarRule: Equatable, Sendable {
    public var condition: SidebarCondition
    public var ignoreCase: Bool?
    public var style: SidebarStyle
    public var hide: Bool?

    public init(condition: SidebarCondition, ignoreCase: Bool? = nil, style: SidebarStyle = .init(), hide: Bool? = nil) {
        self.condition = condition; self.ignoreCase = ignoreCase; self.style = style; self.hide = hide
    }

    public func matches(_ value: String) -> Bool {
        func fold(_ text: String) -> [UInt8] {
            text.utf8.map { ignoreCase == true && (65...90).contains($0) ? $0 + 32 : $0 }
        }
        switch condition {
        case .equals(let expected): return fold(value) == fold(expected)
        case .contains(let expected):
            let needle = fold(expected), haystack = fold(value)
            guard !needle.isEmpty else { return true }
            guard needle.count <= haystack.count else { return false }
            return (0...(haystack.count - needle.count)).contains { haystack[$0..<($0 + needle.count)].elementsEqual(needle) }
        case .startsWith(let expected): return fold(value).starts(with: fold(expected))
        case .gt(let threshold): return Self.number(value).map { $0 > threshold } ?? false
        case .lt(let threshold): return Self.number(value).map { $0 < threshold } ?? false
        }
    }

    // Swift's Double also accepts hexadecimal literals; Rust's f64 parser does not.
    private static func number(_ value: String) -> Double? {
        guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) || [43,45,46,69,101].contains($0) }),
              let number = Double(value), number.isFinite else { return nil }
        return number
    }
}
