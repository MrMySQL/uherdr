import AppKit

@main
struct CommandKeyMonitorTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        let monitor = CommandKeyMonitor()
        monitor.start()
        monitor.update(flags: .command, isActive: true)
        precondition(monitor.isHeld, "Holding Command should reveal shortcuts")
        monitor.update(flags: [.command, .shift], isActive: true)
        precondition(monitor.isHeld, "Other modifiers must not hide a held Command key")
        monitor.update(flags: .shift, isActive: true)
        precondition(!monitor.isHeld, "Releasing Command should hide shortcuts")
        monitor.update(flags: .command, isActive: true)
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApplication.shared)
        precondition(!monitor.isHeld, "Switching apps while Command is held must clear hints")
        monitor.update(flags: .command, isActive: false)
        precondition(!monitor.isHeld, "Inactive apps must not display held-key hints")
        monitor.update(flags: .command, isActive: true)
        monitor.stop()
        precondition(!monitor.isHeld, "Removing the sidebar should clear hints")
        monitor.update(flags: .command, isActive: true)
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApplication.shared)
        precondition(monitor.isHeld, "Stopping must remove notification observers")
        print("PASS: Command hints show, release, mixed modifiers, app deactivation, inactive state, and observer cleanup")
    }
}
