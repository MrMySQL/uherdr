import Foundation
import HerdrCore

enum AttentionTrackerTests {
    // Field shape from `herdr agent list` on herdr 0.9.3 (name and display_agent are optional).
    static func agent(_ pane: String, _ status: String) throws -> Agent {
        try JSONDecoder().decode(Agent.self, from: Data(#"{"pane_id":"\#(pane)","tab_id":"wC:t1","workspace_id":"wC","agent":"claude","agent_status":"\#(status)"}"#.utf8))
    }

    static func run() throws {
        let a = UUID(), b = UUID()
        let t0 = Date(timeIntervalSince1970: 1_791_134_000)
        func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }
        let gap = AttentionTracker.cooldown + 1
        var tracker = AttentionTracker()
        // Each alert here is shown as a banner, which starts its cooldown.
        func shown(device: UUID, agents: [Agent], now: Date) -> [Agent] {
            let alerts = tracker.update(device: device, agents: agents, now: now)
            for agent in alerts { tracker.markAlerted(device: device, paneID: agent.paneID, now: now) }
            return alerts
        }
        // The first look is a baseline: agents already waiting raise nothing.
        XCTAssertEqual(shown(device: a, agents: [try agent("wC:p1", "working"), try agent("wC:p2", "blocked")], now: at(0)).count, 0)
        // working -> blocked alerts once; staying put does not.
        XCTAssertEqual(shown(device: a, agents: [try agent("wC:p1", "blocked"), try agent("wC:p2", "blocked")], now: at(1)).map(\.paneID), ["wC:p1"])
        XCTAssertEqual(shown(device: a, agents: [try agent("wC:p1", "blocked"), try agent("wC:p2", "blocked")], now: at(2)).count, 0)
        // blocked -> done is still the same wait, not a new alert.
        XCTAssertEqual(shown(device: a, agents: [try agent("wC:p1", "done"), try agent("wC:p2", "blocked")], now: at(gap)).count, 0)
        // Back to working, then done again, alerts again.
        _ = shown(device: a, agents: [try agent("wC:p1", "working")], now: at(gap))
        XCTAssertEqual(shown(device: a, agents: [try agent("wC:p1", "done")], now: at(gap + 1)).map(\.paneID), ["wC:p1"])
        // A finish herdr reports as idle (its tab was on a focused terminal) alerts too;
        // idle that was never working (e.g. done -> idle once seen) does not.
        XCTAssertEqual(shown(device: a, agents: [try agent("wC:p1", "idle")], now: at(gap * 2)).count, 0)
        _ = shown(device: a, agents: [try agent("wC:p1", "working")], now: at(gap * 2))
        XCTAssertEqual(shown(device: a, agents: [try agent("wC:p1", "idle")], now: at(gap * 2 + 1)).map(\.paneID), ["wC:p1"])
        // Within the cooldown the same agent stays quiet, then alerts again exactly after it.
        _ = shown(device: a, agents: [try agent("wC:p1", "working")], now: at(gap * 2 + 2))
        XCTAssertEqual(shown(device: a, agents: [try agent("wC:p1", "blocked")], now: at(gap * 2 + 3)).count, 0)
        _ = shown(device: a, agents: [try agent("wC:p1", "working")], now: at(gap * 2 + 4))
        XCTAssertEqual(shown(device: a, agents: [try agent("wC:p1", "blocked")], now: at(gap * 2 + 1 + AttentionTracker.cooldown - 0.5)).count, 0)
        _ = shown(device: a, agents: [try agent("wC:p1", "working")], now: at(gap * 2 + 1 + AttentionTracker.cooldown))
        XCTAssertEqual(shown(device: a, agents: [try agent("wC:p1", "blocked")], now: at(gap * 2 + 1 + AttentionTracker.cooldown)).map(\.paneID), ["wC:p1"])
        // Another agent is not held back by the first one's cooldown, which is still running.
        _ = shown(device: a, agents: [try agent("wC:p1", "blocked"), try agent("wC:p2", "working")], now: at(gap * 2 + 1 + AttentionTracker.cooldown + 1))
        XCTAssertEqual(shown(device: a, agents: [try agent("wC:p1", "working"), try agent("wC:p2", "idle")], now: at(gap * 2 + 1 + AttentionTracker.cooldown + 2)).map(\.paneID), ["wC:p2"])
        // A new agent that appears already waiting is a baseline too.
        XCTAssertEqual(shown(device: a, agents: [try agent("wC:p9", "blocked")], now: at(gap * 5)).count, 0)
        // The same pane ID on another device is tracked separately.
        XCTAssertEqual(shown(device: b, agents: [try agent("wC:p1", "idle")], now: at(gap * 5)).count, 0)
        XCTAssertEqual(shown(device: b, agents: [try agent("wC:p1", "done")], now: at(gap * 5 + 1)).map(\.paneID), ["wC:p1"])
        // Forgetting a device (disconnect) makes its next look a baseline.
        _ = shown(device: a, agents: [try agent("wC:p1", "working")], now: at(gap * 6))
        tracker.forget(device: a)
        XCTAssertEqual(shown(device: a, agents: [try agent("wC:p1", "blocked")], now: at(gap * 7)).count, 0)
        // A suppressed alert (pane in view, or notifications off) starts no cooldown,
        // so the agent's next alert still fires: finish while watched, then blocked.
        var quiet = AttentionTracker()
        _ = quiet.update(device: a, agents: [try agent("wC:p1", "working")], now: at(0))
        XCTAssertEqual(quiet.update(device: a, agents: [try agent("wC:p1", "idle")], now: at(1)).map(\.paneID), ["wC:p1"])
        _ = quiet.update(device: a, agents: [try agent("wC:p1", "working")], now: at(2))
        XCTAssertEqual(quiet.update(device: a, agents: [try agent("wC:p1", "blocked")], now: at(30)).map(\.paneID), ["wC:p1"])
        XCTAssertTrue(AttentionTracker.notificationID(device: a, paneID: "wC:p1") != AttentionTracker.notificationID(device: b, paneID: "wC:p1"))
        XCTAssertTrue(AgentStatus.blocked.needsAttention && AgentStatus.done.needsAttention)
        XCTAssertTrue(!AgentStatus.working.needsAttention && !AgentStatus.idle.needsAttention && !AgentStatus.unknown.needsAttention)
        // Notifications are on until turned off in Settings.
        let suite = "dev.herdr.notification-pref-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(AgentNotificationPreference.isEnabled(in: defaults))
        defaults.set(false, forKey: AgentNotificationPreference.key)
        XCTAssertTrue(!AgentNotificationPreference.isEnabled(in: defaults))
        defaults.set(true, forKey: AgentNotificationPreference.key)
        XCTAssertTrue(AgentNotificationPreference.isEnabled(in: defaults))
        // A banner needs notifications on, and skips the pane already in front of the user.
        XCTAssertTrue(AttentionDelivery.shouldNotify(enabled: true, appActive: false, showingPane: true))
        XCTAssertTrue(AttentionDelivery.shouldNotify(enabled: true, appActive: true, showingPane: false))
        XCTAssertTrue(!AttentionDelivery.shouldNotify(enabled: true, appActive: true, showingPane: true))
        XCTAssertTrue(!AttentionDelivery.shouldNotify(enabled: false, appActive: false, showingPane: false))
        // A click that launched the app waits for its device to connect, but not forever.
        XCTAssertTrue(!AttentionReveal.isReady(connected: false, waited: 0))
        XCTAssertTrue(!AttentionReveal.isReady(connected: false, waited: AttentionReveal.timeout - 0.5))
        XCTAssertTrue(AttentionReveal.isReady(connected: true, waited: 0))
        XCTAssertTrue(AttentionReveal.isReady(connected: false, waited: AttentionReveal.timeout))
        // The fallback waits only what is left since the click.
        XCTAssertEqual(AttentionReveal.remaining(waited: 0), AttentionReveal.timeout)
        XCTAssertEqual(AttentionReveal.remaining(waited: 4), AttentionReveal.timeout - 4)
        XCTAssertEqual(AttentionReveal.remaining(waited: AttentionReveal.timeout + 5), 0)
        print("PASS: alerts on waiting and on every finish, once per agent per cooldown that only a shown banner starts, per device, with baselines at first sight and after disconnect; launch clicks wait for their device")
    }
}
