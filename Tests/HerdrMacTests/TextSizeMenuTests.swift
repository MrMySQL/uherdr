import AppKit
import GhosttyTerminal
import HerdrCore
@testable import HerdrMac

@main
struct TextSizeMenuTests {
    @MainActor static func main() {
        setbuf(stdout, nil)
        // A separate bundle identifier keeps app settings out of user preferences.
        precondition(Bundle.main.bundleIdentifier == "dev.herdr.text-size-tests")
        let profile = DeviceProfile(name: "Menu test", kind: .local,
                                    socketPath: "/tmp/herdr-text-size-no-server.sock", executable: "/usr/bin/false")
        UserDefaults.standard.set(try! JSONEncoder().encode([profile]), forKey: DeviceProfile.preferencesKey)
        UserDefaults.standard.set(13.0, forKey: "fontSize")
        var attempts = 0
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { timer in
            MainActor.assumeIsolated {
                attempts += 1
                guard let window = NSApp.windows.first(where: { $0.canBecomeMain }),
                      let menu = NSApp.mainMenu,
                      items(in: menu).contains(where: { $0.title == "Decrease Text Size" }) else {
                    if attempts >= 100 { fatalError("App did not install its text-size commands") }
                    return
                }
                timer.invalidate()
                run(window: window)
            }
        }
        HerdrApp.main()
    }

    @MainActor static func items(in menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { item in [item] + (item.submenu.map { items(in: $0) } ?? []) }
    }

    @MainActor static func run(window: NSWindow) {
        let bridge = GhosttyStreamBridge(input: { _ in }, resize: { _ in })
        let engine = GhosttyTerminal.TerminalController(configuration: HerdrTerminalView.baseConfiguration)
        let view = HerdrTerminalView(frame: window.contentView!.bounds)
        view.configuration = TerminalSurfaceOptions(backend: .inMemory(bridge.session))
        view.controller = engine
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        precondition(window.firstResponder === view, "Shortcut tests require a focused terminal")
        let cases: [(String, NSEvent.ModifierFlags, UInt16, Double)] = [
            ("+", [.command, .shift], 24, 14),
            ("-", .command, 27, 13),
            ("=", .command, 24, 14),
            ("-", .command, 27, 13),
        ]
        for (key, modifiers, code, expected) in cases {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                        timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: window.windowNumber, context: nil,
                                        characters: key, charactersIgnoringModifiers: key,
                                        isARepeat: false, keyCode: code)!
            NSApp.sendEvent(event)
            let deadline = Date().addingTimeInterval(1)
            while UserDefaults.standard.double(forKey: "fontSize") != expected && Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            }
            precondition(UserDefaults.standard.double(forKey: "fontSize") == expected,
                         "Actual app shortcut \(key) must set font size to \(expected)")
        }
        print("PASS: real SwiftUI app menus handle Command-plus, minus, and equal from a focused terminal")
        view.controller = nil
        UserDefaults.standard.removePersistentDomain(forName: "dev.herdr.text-size-tests")
        exit(0)
    }
}
