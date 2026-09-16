import Foundation

public struct SidebarStyle: Equatable, Sendable {
    public var foreground: ColorValue?
    public var bold: Bool?
    public var dim: Bool?
    public init(foreground: ColorValue? = nil, bold: Bool? = nil, dim: Bool? = nil) {
        self.foreground = foreground; self.bold = bold; self.dim = dim
    }
    public static func resolve(value: String?, base: Self, rules: [SidebarRule]) -> Self? {
        guard let value else { return nil }
        guard let match = rules.first(where: { $0.matches(value) }) else { return base }
        guard match.hide != true else { return nil }
        return Self(foreground: match.style.foreground ?? base.foreground,
                    bold: match.style.bold ?? base.bold, dim: match.style.dim ?? base.dim)
    }
}

public struct SidebarOccurrence: Equatable, Sendable {
    public var token: String
    public var style: SidebarStyle
    public var rules: [SidebarRule]
    public init(token: String, style: SidebarStyle = .init(), rules: [SidebarRule] = []) {
        self.token = token; self.style = style; self.rules = rules
    }
}

public struct SidebarTokenRun: Equatable, Sendable {
    public let token: String
    public let value: String
    public let style: SidebarStyle
    public let status: AgentStatus
}

public struct SidebarSection: Equatable, Sendable {
    /// nil preserves the native default layout; an explicit empty array hides all content.
    public var rows: [[SidebarOccurrence]]?
    public var rowsByAgent: [String: [[SidebarOccurrence]]]
    public var rowGap: UInt16
    public init(rows: [[SidebarOccurrence]]? = nil, rowsByAgent: [String: [[SidebarOccurrence]]] = [:], rowGap: UInt16 = 0) {
        self.rows = rows; self.rowsByAgent = rowsByAgent; self.rowGap = rowGap
    }
    public func layout(agent: String? = nil) -> [[SidebarOccurrence]]? {
        agent.flatMap { rowsByAgent[$0] } ?? rows
    }
    public func resolve(values: [String: String], status: AgentStatus, agent: String? = nil) -> [[SidebarTokenRun]] {
        (layout(agent: agent) ?? []).compactMap { row in
            let runs = row.compactMap { occurrence -> SidebarTokenRun? in
                let value = occurrence.token == "state_icon" ? status.label : values[occurrence.token]
                guard let value, !value.isEmpty,
                      let style = SidebarStyle.resolve(value: value, base: occurrence.style, rules: occurrence.rules) else { return nil }
                return SidebarTokenRun(token: occurrence.token, value: value, style: style, status: status)
            }
            return runs.isEmpty ? nil : runs
        }
    }
}

/// Encodes the upstream JSON shape, including Task 4's persisted intermediate shape.
/// Decoding and import share one validator, so invalid stored layouts cannot bypass validation.
public struct SidebarConfiguration: Codable, Equatable, Sendable {
    public var agents: SidebarSection?
    public var spaces: SidebarSection?
    public init(agents: SidebarSection? = nil, spaces: SidebarSection? = nil) { self.agents = agents; self.spaces = spaces }
    public static let agentTokens = ["state_icon", "state_text", "machine", "workspace", "tab", "pane", "agent", "terminal_title", "terminal_title_stripped"]
    public static let spaceTokens = ["state_icon", "state_text", "workspace", "branch", "git_status"]
    public static let canonicalAgents = ["pi", "claude", "codex", "gemini", "cursor", "devin", "agy", "cline", "omp", "mastracode", "opencode", "copilot", "kimi", "kiro", "droid", "amp", "grok", "hermes", "kilo", "qodercli", "qwen", "letta", "maki", "muse"]
    public init(from decoder: Decoder) throws {
        var diagnostics: [String] = []
        self = try Self.parse(JSONValue(from: decoder), diagnostics: &diagnostics)
    }
    public func encode(to encoder: Encoder) throws { try json.encode(to: encoder) }
    public func validated() throws -> Self {
        var diagnostics: [String] = []
        return try Self.parse(json, diagnostics: &diagnostics)
    }
    public static func parse(_ value: JSONValue, diagnostics: inout [String]) throws -> Self {
        func fail(_ path: String, _ reason: String) -> HerdrError { .message("\(path): \(reason)") }
        func object(_ value: JSONValue, _ path: String) throws -> [String: JSONValue] {
            guard case .object(let fields) = value else { throw fail(path, "expected a table") }; return fields
        }
        func boolean(_ fields: [String: JSONValue], _ key: String, _ path: String) throws -> Bool? {
            guard let raw = fields[key] else { return nil }
            guard case .bool(let value) = raw else { throw fail(path + "." + key, "expected a boolean") }; return value
        }
        func style(_ fields: [String: JSONValue], _ path: String) throws -> SidebarStyle {
            var color: ColorValue?
            if let raw = fields["fg"] {
                guard let text = raw.string, text.hasPrefix("#"), [4,7].contains(text.utf8.count),
                      text.dropFirst().utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else {
                    throw fail(path + ".fg", "expected #RGB or #RRGGBB")
                }
                color = try ColorValue.parse(text)
            }
            return try SidebarStyle(foreground: color, bold: boolean(fields, "bold", path), dim: boolean(fields, "dim", path))
        }
        func rule(_ value: JSONValue, _ path: String) throws -> SidebarRule {
            let fields = try object(value, path)
            let keys = ["equals", "contains", "starts_with", "gt", "lt"].filter { fields[$0] != nil }
            guard keys.count == 1, Set(fields.keys).isSubset(of: ["equals", "contains", "starts_with", "gt", "lt", "ignore_case", "fg", "bold", "dim", "hide"]) else { throw fail(path, "expected exactly one supported condition and supported style keys") }
            let key = keys[0]
            let condition: SidebarCondition
            if key == "gt" || key == "lt" {
                guard case .number(let number) = fields[key], number.isFinite, fields["ignore_case"] == nil else { throw fail(path, "numeric condition requires a finite number and no ignore_case") }
                condition = key == "gt" ? .gt(number) : .lt(number)
            } else {
                guard let text = fields[key]?.string else { throw fail(path, "text condition requires a string") }
                condition = key == "equals" ? .equals(text) : key == "contains" ? .contains(text) : .startsWith(text)
            }
            return try SidebarRule(condition: condition, ignoreCase: boolean(fields, "ignore_case", path), style: style(fields, path), hide: boolean(fields, "hide", path))
        }
        func rows(_ value: JSONValue, _ path: String, _ agent: Bool) throws -> [[SidebarOccurrence]] {
            guard case .array(let rows) = value, rows.count <= 16 else { throw fail(path, "expected at most 16 rows") }
            return try rows.enumerated().map { i, row in
                guard case .array(let tokens) = row, tokens.count <= 16 else { throw fail("\(path)[\(i)]", "expected at most 16 tokens") }
                return try tokens.enumerated().map { j, value in
                    let path = "\(path)[\(i)][\(j)]"
                    let fields = try value.string.map { ["token": JSONValue.string($0)] } ?? object(value, path)
                    guard let token = fields["token"]?.string, Set(fields.keys).isSubset(of: ["token", "fg", "bold", "dim", "rules"]) else { throw fail(path, "expected token and supported style keys") }
                    let name = token.dropFirst()
                    let custom = token.hasPrefix("$") && (1...32).contains(name.utf8.count) && name.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 95 || $0 == 45 }
                    guard (agent ? agentTokens : spaceTokens).contains(token) || custom else { throw fail(path, "unknown token \(token)") }
                    var rules: [SidebarRule] = []
                    if let raw = fields["rules"] {
                        guard case .array(let values) = raw, values.count <= 16 else { throw fail(path, "expected at most 16 rules") }
                        guard values.isEmpty || !["state_icon", "git_status"].contains(token) else { throw fail(path, "rules require a text-valued token") }
                        rules = try values.enumerated().map { try rule($1, "\(path).rules[\($0)]") }
                    }
                    return try SidebarOccurrence(token: token, style: style(fields, path), rules: rules)
                }
            }
        }
        var result = Self()
        for (key, value) in try object(value, "ui.sidebar") {
            let path = "ui.sidebar.\(key)"
            guard ["agents", "spaces"].contains(key) else { diagnostics.append("Unsupported \(path); ignored."); continue }
            let agent = key == "agents"
            var section = SidebarSection()
            for (key, value) in try object(value, path) {
                switch key {
                case "rows": section.rows = try rows(value, path + ".rows", agent)
                case "rows_by_agent" where agent:
                    for (id, layout) in try object(value, path + ".rows_by_agent") {
                        guard canonicalAgents.contains(id) else { throw fail(path + ".rows_by_agent.\(id)", "unknown canonical agent ID") }
                        section.rowsByAgent[id] = try rows(layout, path + ".rows_by_agent.\(id)", true)
                    }
                case "row_gap":
                    guard case .number(let number) = value, number >= 0, number <= 65535, number.rounded() == number else { throw fail(path + ".row_gap", "expected an unsigned 16-bit integer") }
                    section.rowGap = UInt16(number)
                default: diagnostics.append("Unsupported \(path).\(key); ignored.")
                }
            }
            if agent { result.agents = section } else { result.spaces = section }
        }
        return result
    }

    private var json: JSONValue {
        func style(_ style: SidebarStyle) -> [String: JSONValue] {
            var fields: [String: JSONValue] = [:]
            if let color = style.foreground {
                if case .rgb(let r, let g, let b) = color { fields["fg"] = .string(String(format: "#%02x%02x%02x", r, g, b)) }
                else { fields["fg"] = .string("reset") } // Rejected by validated(), never silently discarded.
            }
            if let bold = style.bold { fields["bold"] = .bool(bold) }
            if let dim = style.dim { fields["dim"] = .bool(dim) }
            return fields
        }
        func rows(_ rows: [[SidebarOccurrence]]) -> JSONValue {
            .array(rows.map { .array($0.map { occurrence in
                var fields = style(occurrence.style); fields["token"] = .string(occurrence.token)
                fields["rules"] = .array(occurrence.rules.map { rule in
                    var fields = style(rule.style)
                    switch rule.condition {
                    case .equals(let value): fields["equals"] = .string(value)
                    case .contains(let value): fields["contains"] = .string(value)
                    case .startsWith(let value): fields["starts_with"] = .string(value)
                    case .gt(let value): fields["gt"] = .number(value)
                    case .lt(let value): fields["lt"] = .number(value)
                    }
                    if let ignore = rule.ignoreCase { fields["ignore_case"] = .bool(ignore) }
                    if let hide = rule.hide { fields["hide"] = .bool(hide) }
                    return .object(fields)
                })
                return .object(fields)
            }) })
        }
        func section(_ section: SidebarSection) -> JSONValue {
            var fields: [String: JSONValue] = ["row_gap": .number(Double(section.rowGap))]
            if let layout = section.rows { fields["rows"] = rows(layout) }
            if !section.rowsByAgent.isEmpty { fields["rows_by_agent"] = .object(section.rowsByAgent.mapValues(rows)) }
            return .object(fields)
        }
        var fields: [String: JSONValue] = [:]
        if let agents { fields["agents"] = section(agents) }
        if let spaces { fields["spaces"] = section(spaces) }
        return .object(fields)
    }
}
