import AppKit
import Combine

/// Observe modifier changes without consuming terminal or application keyboard events.
@MainActor
final class CommandKeyMonitor: ObservableObject {
    @Published private(set) var isHeld = false
    private var monitor: Any?
    private var notifications: [NSObjectProtocol] = []

    func start() {
        guard monitor == nil else { return }
        update(flags: NSEvent.modifierFlags, isActive: NSApp.isActive)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.update(flags: event.modifierFlags, isActive: NSApp.isActive)
            return event
        }
        notifications = [
            NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.update(flags: [], isActive: false) }
            },
            NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.update(flags: NSEvent.modifierFlags, isActive: true) }
            }
        ]
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        notifications.forEach(NotificationCenter.default.removeObserver)
        notifications = []
        isHeld = false
    }

    func update(flags: NSEvent.ModifierFlags, isActive: Bool) {
        let held = isActive && flags.contains(.command)
        if isHeld != held { isHeld = held }
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
        notifications.forEach(NotificationCenter.default.removeObserver)
    }
}
