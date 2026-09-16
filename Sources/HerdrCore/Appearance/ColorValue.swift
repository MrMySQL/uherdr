import Foundation

public enum AppearanceMode: String, Codable, Sendable {
    case system
    case light
    case dark
}

public enum ThemeVariant: String, Codable, Sendable {
    case light
    case dark
}

public enum ColorValue: Codable, Equatable, Sendable {
    case rgb(UInt8, UInt8, UInt8)
    case reset

    public static func parse(_ text: String) throws -> ColorValue {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if ["reset", "default", "none", "transparent"].contains(value) {
            return .reset
        }
        if value.hasPrefix("#") {
            return try parseHex(String(value.dropFirst()), original: text)
        }
        if value.hasPrefix("rgb(") && value.hasSuffix(")") {
            return try parseRGB(String(value.dropFirst(4).dropLast()), original: text)
        }
        if let named = namedColors[value.replacingOccurrences(of: "_", with: "").replacingOccurrences(of: "-", with: "")] {
            return named
        }
        throw ColorValueParseError.invalidColor(text)
    }

    private static func parseHex(_ hex: String, original: String) throws -> ColorValue {
        switch hex.count {
        case 3:
            let components = hex.map(String.init)
            guard components.count == 3,
                  let red = UInt8(components[0], radix: 16),
                  let green = UInt8(components[1], radix: 16),
                  let blue = UInt8(components[2], radix: 16)
            else { throw ColorValueParseError.invalidColor(original) }
            return .rgb(red * 17, green * 17, blue * 17)
        case 6:
            guard let red = UInt8(hex.prefix(2), radix: 16),
                  let green = UInt8(hex.dropFirst(2).prefix(2), radix: 16),
                  let blue = UInt8(hex.dropFirst(4).prefix(2), radix: 16)
            else { throw ColorValueParseError.invalidColor(original) }
            return .rgb(red, green, blue)
        default:
            throw ColorValueParseError.invalidColor(original)
        }
    }

    private static func parseRGB(_ body: String, original: String) throws -> ColorValue {
        let parts = body.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count == 3 else { throw ColorValueParseError.invalidColor(original) }
        let values = parts.compactMap { UInt8($0.trimmingCharacters(in: .whitespaces)) }
        guard values.count == 3 else { throw ColorValueParseError.invalidColor(original) }
        return .rgb(values[0], values[1], values[2])
    }

    // Fixed sRGB equivalents for Herdr's supported ANSI color names. The
    // symbolic `terminal` palette itself is resolved separately by its host.
    private static let namedColors: [String: ColorValue] = [
        "black": .rgb(0, 0, 0),
        "red": .rgb(128, 0, 0),
        "green": .rgb(0, 128, 0),
        "yellow": .rgb(128, 128, 0),
        "blue": .rgb(0, 0, 128),
        "magenta": .rgb(128, 0, 128),
        "purple": .rgb(128, 0, 128),
        "cyan": .rgb(0, 128, 128),
        "white": .rgb(192, 192, 192),
        "gray": .rgb(128, 128, 128),
        "grey": .rgb(128, 128, 128),
        "darkgray": .rgb(64, 64, 64),
        "darkgrey": .rgb(64, 64, 64),
        "lightred": .rgb(255, 0, 0),
        "lightgreen": .rgb(0, 255, 0),
        "lightyellow": .rgb(255, 255, 0),
        "lightblue": .rgb(0, 0, 255),
        "lightmagenta": .rgb(255, 0, 255),
        "lightcyan": .rgb(0, 255, 255),
    ]
}

public enum ColorValueParseError: Error, Equatable, Sendable, LocalizedError {
    case invalidColor(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidColor(value):
            return "Invalid color value: \(value)"
        }
    }
}
