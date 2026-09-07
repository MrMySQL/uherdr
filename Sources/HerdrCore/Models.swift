import Foundation

public enum AgentStatus: String, Codable, Sendable { case idle, working, blocked, done, unknown
    public var label: String { rawValue.capitalized }
}

public struct Workspace: Decodable, Identifiable, Equatable, Sendable {
    public let workspaceID: String
    public let label: String
    public let activeTabID: String
    public let paneCount: Int
    public let tabCount: Int
    public let agentStatus: AgentStatus
    public var id: String { workspaceID }
    enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id", label, activeTabID = "active_tab_id"
        case paneCount = "pane_count", tabCount = "tab_count", agentStatus = "agent_status"
    }
}

public struct Tab: Decodable, Identifiable, Equatable, Sendable {
    public let tabID: String
    public let workspaceID: String
    public let label: String
    public let paneCount: Int
    public let agentStatus: AgentStatus
    public var id: String { tabID }
    enum CodingKeys: String, CodingKey {
        case tabID = "tab_id", workspaceID = "workspace_id", label
        case paneCount = "pane_count", agentStatus = "agent_status"
    }
}

public struct Pane: Decodable, Identifiable, Equatable, Sendable {
    public let paneID: String
    public let terminalID: String
    public let workspaceID: String
    public let tabID: String
    public let label: String?
    public let title: String?
    public let cwd: String?
    public let foregroundCwd: String?
    public let agent: String?
    public let displayAgent: String?
    public let agentStatus: AgentStatus
    public var id: String { paneID }
    public var displayTitle: String { label ?? title ?? displayAgent ?? agent ?? "Terminal" }
    public var directory: String { foregroundCwd ?? cwd ?? "" }
    enum CodingKeys: String, CodingKey {
        case paneID = "pane_id", terminalID = "terminal_id", workspaceID = "workspace_id", tabID = "tab_id"
        case label, title, cwd, foregroundCwd = "foreground_cwd", agent, displayAgent = "display_agent", agentStatus = "agent_status"
    }
}

public struct Agent: Decodable, Identifiable, Equatable, Sendable {
    public let paneID: String
    public let workspaceID: String
    public let tabID: String
    public let name: String?
    public let agent: String?
    public let displayAgent: String?
    public let agentStatus: AgentStatus
    public var id: String { paneID }
    public var displayName: String { name ?? displayAgent ?? agent ?? "Agent" }
    enum CodingKeys: String, CodingKey {
        case paneID = "pane_id", workspaceID = "workspace_id", tabID = "tab_id", name, agent
        case displayAgent = "display_agent", agentStatus = "agent_status"
    }
}

public struct SessionSnapshot: Decodable, Sendable {
    public let version: String
    public let protocolVersion: Int
    public let workspaces: [Workspace]
    public let tabs: [Tab]
    public let panes: [Pane]
    public let agents: [Agent]
    public let focusedWorkspaceID: String?
    public let focusedTabID: String?
    public let focusedPaneID: String?
    enum CodingKeys: String, CodingKey {
        case version, protocolVersion = "protocol", workspaces, tabs, panes, agents
        case focusedWorkspaceID = "focused_workspace_id", focusedTabID = "focused_tab_id", focusedPaneID = "focused_pane_id"
    }
}

public enum SplitDirection: String, Codable, Sendable { case right, down }

public indirect enum LayoutNode: Decodable, Equatable, Sendable {
    case pane(String)
    case split(SplitDirection, Double, LayoutNode, LayoutNode)
    enum CodingKeys: String, CodingKey { case type, paneID = "pane_id", direction, ratio, first, second }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "pane": self = .pane(try c.decode(String.self, forKey: .paneID))
        case "split":
            let ratio = try c.decode(Double.self, forKey: .ratio)
            guard ratio.isFinite, ratio > 0, ratio < 1 else { throw HerdrError.message("Invalid split ratio") }
            self = .split(try c.decode(SplitDirection.self, forKey: .direction), ratio,
                          try c.decode(LayoutNode.self, forKey: .first), try c.decode(LayoutNode.self, forKey: .second))
        default: throw HerdrError.message("Unsupported layout node")
        }
    }
    public var paneIDs: [String] {
        switch self { case .pane(let id): return [id]; case .split(_, _, let a, let b): return a.paneIDs + b.paneIDs }
    }
}

public struct TabLayout: Decodable, Equatable, Sendable {
    public let tabID: String
    public let root: LayoutNode
    public let zoomed: Bool
    public let focusedPaneID: String?
    enum CodingKeys: String, CodingKey { case tabID = "tab_id", root, zoomed, focusedPaneID = "focused_pane_id" }
    public func resolveSelectedPane(_ selected: String?) -> String? {
        let ids = root.paneIDs
        if !zoomed, let selected, ids.contains(selected) { return selected }
        if let focusedPaneID, ids.contains(focusedPaneID) { return focusedPaneID }
        return ids.first
    }
}

public enum HerdrError: LocalizedError {
    case message(String)
    public var errorDescription: String? { switch self { case .message(let s): return s } }
}
