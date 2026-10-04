import Foundation

extension AgentStatus {
    /// Blocked agents wait for input; done agents finished and are unseen.
    public var needsAttention: Bool { self == .blocked || self == .done }
}

/// Finds agents that just started needing attention. Only a change from a
/// known status counts, so agents already waiting at launch, on reconnect,
/// or when first seen raise nothing. Pane IDs repeat across servers, so
/// agents are keyed by device and pane.
public struct AttentionTracker {
    private var known: [UUID: [String: AgentStatus]] = [:]

    public init() {}

    public mutating func update(device: UUID, agents: [Agent]) -> [Agent] {
        let previous = known[device]
        var current: [String: AgentStatus] = [:]
        var alerts: [Agent] = []
        for agent in agents where current[agent.paneID] == nil {
            current[agent.paneID] = agent.agentStatus
            if let old = previous?[agent.paneID], !old.needsAttention, agent.agentStatus.needsAttention {
                alerts.append(agent)
            }
        }
        known[device] = current
        return alerts
    }

    /// Drops a device's baseline, e.g. while it is disconnected.
    public mutating func forget(device: UUID) { known[device] = nil }

    public static func notificationID(device: UUID, paneID: String) -> String { "\(device.uuidString):\(paneID)" }
}
