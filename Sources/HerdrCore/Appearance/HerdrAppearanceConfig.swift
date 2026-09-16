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
    /// Intermediate representation: Task 5 supplies complete typed sidebar validation.
    public var sidebar: JSONValue?
    public var diagnostics: [String]?

    public init(themeName: String, autoSwitch: Bool = true, commonOverrides: ThemeOverrides = [:],
                lightOverrides: ThemeOverrides = [:], darkOverrides: ThemeOverrides = [:],
                lightName: String? = nil, darkName: String? = nil,
                sidebar: JSONValue? = nil, diagnostics: [String]? = nil) {
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
        var sidebar: JSONValue?
        if let rawUI = root["ui"], rawUI.type == .table, let ui = rawUI.table, let raw = ui["sidebar"] {
            guard raw.type == .table, let table = raw.table else { throw failure("ui.sidebar", "expected a table") }
            sidebar = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(table))
            try validateSidebar(sidebar!, diagnostics: &messages)
            messages.append("Sidebar styles are not applied in this build.")
        }
        return try Self(themeName: name("name") ?? "catppuccin", autoSwitch: autoSwitch,
                        commonOverrides: common, lightOverrides: light, darkOverrides: dark,
                        lightName: name("light_name"), darkName: name("dark_name"),
                        sidebar: sidebar, diagnostics: messages.sorted())
    }

    private static func failure(_ path: String, _ message: String) -> HerdrError {
        .message("\(path): \(message)")
    }

    private static func validateSidebar(_ value: JSONValue, diagnostics: inout [String]) throws {
        func object(_ value: JSONValue, _ path: String) throws -> [String: JSONValue] {
            guard case .object(let result) = value else { throw failure(path, "expected a table") }
            return result
        }
        func rows(_ value: JSONValue, _ path: String) throws {
            guard case .array(let rows) = value, rows.count <= 16 else { throw failure(path, "expected at most 16 rows") }
            for (i, row) in rows.enumerated() {
                let path = "\(path)[\(i)]"
                guard case .array(let tokens) = row, tokens.count <= 16 else { throw failure(path, "expected at most 16 tokens") }
                for (j, token) in tokens.enumerated() {
                    if case .string = token { continue }
                    let path = "\(path)[\(j)]"
                    let fields = try object(token, path)
                    guard fields["token"]?.string != nil else { throw failure(path, "expected token string") }
                    guard Set(fields.keys).isSubset(of: ["token", "fg", "bold", "dim", "rules"]) else {
                        throw failure(path, "unsupported token style key")
                    }
                    try style(fields, path)
                    if let rules = fields["rules"] {
                        guard case .array(let values) = rules, values.count <= 16 else { throw failure(path, "expected at most 16 rules") }
                        for (index, value) in values.enumerated() {
                            let path = "\(path).rules[\(index)]"
                            let rule = try object(value, path)
                            let conditions = ["equals", "contains", "starts_with", "gt", "lt"].filter { rule[$0] != nil }
                            guard conditions.count == 1,
                                  Set(rule.keys).isSubset(of: ["equals", "contains", "starts_with", "gt", "lt", "ignore_case", "fg", "bold", "dim", "hide"]) else {
                                throw failure(path, "expected exactly one supported condition and supported style keys")
                            }
                            let condition = conditions[0]
                            if ["gt", "lt"].contains(condition) {
                                guard case .number(let n) = rule[condition], n.isFinite, rule["ignore_case"] == nil else {
                                    throw failure(path, "numeric condition requires a finite number and no ignore_case")
                                }
                            } else if rule[condition]?.string == nil { throw failure(path, "text condition requires a string") }
                            try style(rule, path)
                        }
                    }
                }
            }
        }
        for (section, raw) in try object(value, "ui.sidebar") {
            let path = "ui.sidebar.\(section)"
            guard ["agents", "spaces"].contains(section) else { diagnostics.append("Unsupported \(path); ignored."); continue }
            for (key, value) in try object(raw, path) {
                switch key {
                case "rows": try rows(value, "\(path).rows")
                case "row_gap":
                    guard case .number(let n) = value, n >= 0, n <= 65535, n.rounded() == n else {
                        throw failure("\(path).row_gap", "expected an unsigned 16-bit integer")
                    }
                case "rows_by_agent" where section == "agents":
                    for (agent, layout) in try object(value, "\(path).rows_by_agent") { try rows(layout, "\(path).rows_by_agent.\(agent)") }
                default: diagnostics.append("Unsupported \(path).\(key); ignored.")
                }
            }
        }
    }

    private static func style(_ fields: [String: JSONValue], _ path: String) throws {
        for key in ["bold", "dim", "hide", "ignore_case"] {
            if let value = fields[key], case .bool = value {} else if fields[key] != nil {
                throw failure("\(path).\(key)", "expected a boolean")
            }
        }
        if let value = fields["fg"] {
            guard let string = value.string, string.hasPrefix("#"), [4, 7].contains(string.utf8.count),
                  (try? ColorValue.parse(string)) != nil else { throw failure("\(path).fg", "expected #RGB or #RRGGBB") }
        }
    }
}
