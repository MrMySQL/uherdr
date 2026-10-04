import Foundation

extension AgentStatus {
    /// Blocked agents wait for input; done agents finished and are unseen.
    public var needsAttention: Bool { self == .blocked || self == .done }
}

/// Finds agents that just finished or started waiting. Only a change from a
/// known status counts, so agents already waiting at launch, on reconnect,
/// or when first seen raise nothing. Pane IDs repeat across servers, so
/// agents are keyed by device and pane.
public struct AttentionTracker {
    /// One alert per agent in this window, so an agent flipping between
    /// working and waiting does not alert on every flip.
    public static let cooldown: TimeInterval = 120

    private var known: [UUID: [String: AgentStatus]] = [:]
    private var lastAlert: [String: Date] = [:]

    public init() {}

    /// Waiting (blocked, or done and unseen), and any finish: herdr reports
    /// working -> idle instead of done when a focused terminal shows the tab.
    public static func alerts(from old: AgentStatus, to new: AgentStatus) -> Bool {
        (!old.needsAttention && new.needsAttention) || (old == .working && new == .idle)
    }

    public mutating func update(device: UUID, agents: [Agent], now: Date = Date()) -> [Agent] {
        lastAlert = lastAlert.filter { now.timeIntervalSince($0.value) < Self.cooldown }
        let previous = known[device]
        var current: [String: AgentStatus] = [:]
        var alerts: [Agent] = []
        for agent in agents where current[agent.paneID] == nil {
            current[agent.paneID] = agent.agentStatus
            guard let old = previous?[agent.paneID], Self.alerts(from: old, to: agent.agentStatus) else { continue }
            let id = Self.notificationID(device: device, paneID: agent.paneID)
            guard lastAlert[id] == nil else { continue }
            lastAlert[id] = now
            alerts.append(agent)
        }
        known[device] = current
        return alerts
    }

    /// Drops a device's baseline, e.g. while it is disconnected.
    public mutating func forget(device: UUID) { known[device] = nil }

    public static func notificationID(device: UUID, paneID: String) -> String { "\(device.uuidString):\(paneID)" }
}
