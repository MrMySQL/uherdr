import Foundation
import HerdrCore

enum AttentionTrackerTests {
    // Field shape from `herdr agent list` on herdr 0.9.3 (name and display_agent are optional).
    static func agent(_ pane: String, _ status: String) throws -> Agent {
        try JSONDecoder().decode(Agent.self, from: Data(#"{"pane_id":"\#(pane)","tab_id":"wC:t1","workspace_id":"wC","agent":"claude","agent_status":"\#(status)"}"#.utf8))
    }

    static func run() throws {
        let a = UUID(), b = UUID()
        var tracker = AttentionTracker()
        // The first look is a baseline: agents already waiting raise nothing.
        XCTAssertEqual(tracker.update(device: a, agents: [try agent("wC:p1", "working"), try agent("wC:p2", "blocked")]).count, 0)
        // working -> blocked and idle -> done alert once each; staying put does not.
        XCTAssertEqual(tracker.update(device: a, agents: [try agent("wC:p1", "blocked"), try agent("wC:p2", "blocked")]).map(\.paneID), ["wC:p1"])
        XCTAssertEqual(tracker.update(device: a, agents: [try agent("wC:p1", "blocked"), try agent("wC:p2", "blocked")]).count, 0)
        // blocked -> done is still the same wait, not a new alert.
        XCTAssertEqual(tracker.update(device: a, agents: [try agent("wC:p1", "done"), try agent("wC:p2", "blocked")]).count, 0)
        // Back to working, then done again, alerts again.
        _ = tracker.update(device: a, agents: [try agent("wC:p1", "working")])
        XCTAssertEqual(tracker.update(device: a, agents: [try agent("wC:p1", "done")]).map(\.paneID), ["wC:p1"])
        // A new agent that appears already waiting is a baseline too.
        XCTAssertEqual(tracker.update(device: a, agents: [try agent("wC:p1", "done"), try agent("wC:p9", "blocked")]).count, 0)
        // The same pane ID on another device is tracked separately.
        XCTAssertEqual(tracker.update(device: b, agents: [try agent("wC:p1", "idle")]).count, 0)
        XCTAssertEqual(tracker.update(device: b, agents: [try agent("wC:p1", "done")]).map(\.paneID), ["wC:p1"])
        // Forgetting a device (disconnect) makes its next look a baseline.
        _ = tracker.update(device: a, agents: [try agent("wC:p1", "working")])
        tracker.forget(device: a)
        XCTAssertEqual(tracker.update(device: a, agents: [try agent("wC:p1", "blocked")]).count, 0)
        XCTAssertTrue(AttentionTracker.notificationID(device: a, paneID: "wC:p1") != AttentionTracker.notificationID(device: b, paneID: "wC:p1"))
        XCTAssertTrue(AgentStatus.blocked.needsAttention && AgentStatus.done.needsAttention)
        XCTAssertTrue(!AgentStatus.working.needsAttention && !AgentStatus.idle.needsAttention && !AgentStatus.unknown.needsAttention)
        print("PASS: attention alerts on transitions only, per device, with baselines at first sight and after disconnect")
    }
}
