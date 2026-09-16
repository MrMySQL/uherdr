import Foundation
import TOMLKit

/// A read-only, normalized appearance snapshot. Unrelated TOML is never rewritten.
public struct HerdrAppearanceConfig: Codable, Equatable, Sendable {
    public static let maximumBytes = 1_048_576
    public static let colorRoles = [
        "accent", "panel_bg", "sidebar_bg", "active_row_bg", "selection_bg",
        "surface0", "surface1", "surface_dim", "overlay0", "overlay1", "text",
        "subtext0", "mauve", "green", "yellow", "red", "blue", "teal", "peach",
    ]
    public var themeName: String
    public var autoSwitch: Bool
    public var lightName: String?
    public var darkName: String?
    public var commonOverrides: ThemeOverrides
    public var lightOverrides: ThemeOverrides
    public var darkOverrides: ThemeOverrides
    public var sidebar: SidebarConfiguration?
    public var diagnostics: [String]?

    public init(themeName: String, autoSwitch: Bool = true, commonOverrides: ThemeOverrides = [:],
                lightOverrides: ThemeOverrides = [:], darkOverrides: ThemeOverrides = [:],
                lightName: String? = nil, darkName: String? = nil,
                sidebar: SidebarConfiguration? = nil, diagnostics: [String]? = nil) {
        self.themeName = themeName
        self.autoSwitch = autoSwitch
        self.commonOverrides = commonOverrides
        self.lightOverrides = lightOverrides
        self.darkOverrides = darkOverrides
        self.lightName = lightName
        self.darkName = darkName
        self.sidebar = sidebar
        self.diagnostics = diagnostics
    }

    public static func validateThemeName(_ name: String) throws {
        if name.lowercased() == "terminal" { return }
        guard name.lowercased() != "uherdr" else { throw BuiltInThemeError.unknownTheme(name) }
        _ = try BuiltInThemes.palette(named: name)
    }

    public static func parse(_ text: String) throws -> Self {
        guard text.utf8.count <= maximumBytes else { throw failure("file", "exceeds the 1 MiB limit") }
        let root: TOMLTable
        do { root = try TOMLTable(string: text) }
        catch { throw failure("TOML", String(describing: error)) }
        var messages: [String] = []
        func section(_ table: TOMLTable, _ key: String, _ path: String) throws -> TOMLTable {
            guard let value = table[key] else { return TOMLTable() }
            // TOMLKit 0.5.0 table accessors require a type guard before the C cast.
            guard value.type == .table, let result = value.table else { throw failure(path, "expected a table") }
            return result
        }
        let theme = try section(root, "theme", "theme")
        func name(_ key: String) throws -> String? {
            guard let value = theme[key] else { return nil }
            guard let string = value.string else { throw failure("theme.\(key)", "expected a theme name") }
            do { try validateThemeName(string) }
            catch { throw failure("theme.\(key)", error.localizedDescription) }
            return string
        }
        for (key, _) in theme where !["name", "auto_switch", "light_name", "dark_name", "custom"].contains(key) {
            messages.append("Unsupported theme.\(key); ignored.")
        }
        var autoSwitch = false
        if let raw = theme["auto_switch"] {
            guard let value = raw.bool else { throw failure("theme.auto_switch", "expected a boolean") }
            autoSwitch = value
        }
        let custom = try section(theme, "custom", "theme.custom")
        func overrides(_ table: TOMLTable, _ path: String, modes: Bool = false) throws -> ThemeOverrides {
            var result: ThemeOverrides = [:]
            for (key, value) in table {
                if modes && ["light", "dark"].contains(key) { continue }
                guard colorRoles.contains(key) else { messages.append("Unsupported \(path).\(key); ignored."); continue }
                guard let string = value.string else { throw failure("\(path).\(key)", "expected a color string") }
                do { result[key] = try ColorValue.parse(string) }
                catch { throw failure("\(path).\(key)", error.localizedDescription) }
            }
            return result
        }
        let common = try overrides(custom, "theme.custom", modes: true)
        let light = try overrides(section(custom, "light", "theme.custom.light"), "theme.custom.light")
        let dark = try overrides(section(custom, "dark", "theme.custom.dark"), "theme.custom.dark")
        var sidebar: SidebarConfiguration?
        if let rawUI = root["ui"], rawUI.type == .table, let ui = rawUI.table, let raw = ui["sidebar"] {
            guard raw.type == .table, let table = raw.table else { throw failure("ui.sidebar", "expected a table") }
            let rawSidebar = jsonValue(table)
            sidebar = try SidebarConfiguration.parse(rawSidebar, diagnostics: &messages)
        }
        return try Self(themeName: name("name") ?? "catppuccin", autoSwitch: autoSwitch,
                        commonOverrides: common, lightOverrides: light, darkOverrides: dark,
                        lightName: name("light_name"), darkName: name("dark_name"),
                        sidebar: sidebar, diagnostics: messages.sorted())
    }

    private static func failure(_ path: String, _ message: String) -> HerdrError {
        .message("\(path): \(message)")
    }

    /// Bridges TOML without JSONEncoder so non-finite values reach the typed validator.
    /// TOML date/time values remain non-strings, ensuring supported fields reject them.
    private static func jsonValue(_ value: TOMLValueConvertible) -> JSONValue {
        switch value.type {
        case .table:
            var fields: [String: JSONValue] = [:]
            for (key, value) in value.table! { fields[key] = jsonValue(value) }
            return .object(fields)
        case .array: return .array(value.array!.map(jsonValue))
        case .string: return .string(value.string!)
        case .int: return .number(Double(value.int!))
        case .double: return .number(value.double!)
        case .bool: return .bool(value.bool!)
        case .date, .time, .dateTime: return .null
        }
    }

}
