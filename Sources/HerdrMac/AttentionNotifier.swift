import AppKit
import Combine
import UserNotifications
import HerdrCore

/// Posts a notification when an agent on any device starts waiting, opens
/// its pane when clicked, and keeps the Dock badge at the attention count.
@MainActor
final class AttentionNotifier: NSObject, UNUserNotificationCenterDelegate {
    private weak var devices: DeviceStore?
    private var tracker = AttentionTracker()
    private var subscription: AnyCancellable?
    private var center: UNUserNotificationCenter?
    private var scanQueued = false
    /// A click that launched the app, held until its device connects.
    private var pendingReveal: (deviceID: String, paneID: String, at: Date)?

    /// Runs before launch finishes, so a click that launches the app reaches this delegate.
    func install() {
        // Notifications need an app bundle; `swift run` has none.
        guard center == nil, Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        self.center = center
    }

    func attach(_ devices: DeviceStore) {
        guard self.devices == nil else { return }
        self.devices = devices
        // objectWillChange fires before the change lands; scan on the next turn.
        subscription = devices.objectWillChange.sink { [weak self] _ in self?.queueScan() }
        if let pending = pendingReveal {
            // The timeout runs from the click, not from here.
            let delay = AttentionReveal.remaining(waited: Date().timeIntervalSince(pending.at))
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.scan() }
        }
        scan()
    }

    private func queueScan() {
        guard !scanQueued else { return }
        scanQueued = true
        DispatchQueue.main.async { [weak self] in
            self?.scanQueued = false
            self?.scan()
        }
    }

    private func scan() {
        guard let devices else { return }
        for session in devices.sessions {
            guard session.connected else { tracker.forget(device: session.profile.id); continue }
            for agent in tracker.update(device: session.profile.id, agents: session.agents) { post(agent, in: session) }
        }
        let count = devices.attentionCount
        NSApp.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
        revealPending()
    }

    private func revealPending() {
        guard let pending = pendingReveal, let devices else { return }
        guard let session = devices.sessions.first(where: { $0.profile.id.uuidString == pending.deviceID }) else { pendingReveal = nil; return }
        guard AttentionReveal.isReady(connected: session.connected, waited: Date().timeIntervalSince(pending.at)) else { return }
        pendingReveal = nil
        reveal(deviceID: pending.deviceID, paneID: pending.paneID)
    }

    private func post(_ agent: Agent, in session: SessionStore) {
        guard let center, AttentionDelivery.shouldNotify(
            enabled: AgentNotificationPreference.isEnabled(in: .standard), appActive: NSApp.isActive,
            showingPane: devices?.activeSession === session && session.selectedPane == agent.paneID) else { return }
        let content = UNMutableNotificationContent()
        content.title = agent.agentStatus == .blocked ? "\(agent.displayName) needs you" : "\(agent.displayName) finished"
        let space = session.workspaces.first { $0.id == agent.workspaceID }?.label
        content.body = [session.displayName, space].compactMap { $0 }.joined(separator: " · ")
        content.sound = .default
        content.userInfo = ["deviceID": session.profile.id.uuidString, "paneID": agent.paneID]
        let id = AttentionTracker.notificationID(device: session.profile.id, paneID: agent.paneID)
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    func reveal(deviceID: String, paneID: String) {
        guard let devices else { pendingReveal = (deviceID, paneID, Date()); return }
        guard let session = devices.sessions.first(where: { $0.profile.id.uuidString == deviceID }) else { return }
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
        devices.select(session)
        if let agent = session.agents.first(where: { $0.paneID == paneID }) { session.revealAgent(agent) }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        if let deviceID = info["deviceID"] as? String, let paneID = info["paneID"] as? String {
            Task { @MainActor in self.reveal(deviceID: deviceID, paneID: paneID) }
        }
        completionHandler()
    }
}
