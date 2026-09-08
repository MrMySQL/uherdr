import AppKit
import SwiftTerm
import HerdrCore
@testable import HerdrMac

@main
struct TerminalKeyboardTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        let view = HerdrTerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 360))
        let capture = InputCapture()
        view.terminalDelegate = capture
        let window = NSWindow(contentRect: view.frame, styleMask: .titled, backing: .buffered, defer: false)
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        let store = SessionStore(profile: DeviceProfile(name: "Keyboard test", kind: .local, socketPath: "/tmp/uherdr-keyboard-test.sock", executable: "/tmp/herdr"))
        let coordinator = TerminalSurface.Coordinator(controller: TerminalController(), store: store, paneID: "keyboard-test")
        coordinator.view = view
        coordinator.installEvents()
        defer { coordinator.removeEvents(); window.orderOut(nil) }

        func check(_ label: String, keyCode: UInt16 = 36, modifiers: NSEvent.ModifierFlags,
                   repeatPress: Bool = false, type: NSEvent.EventType = .keyDown, expected: String) {
            capture.bytes = []
            let characters = keyCode == 76 ? "\u{3}" : "\r"
            let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers,
                                        timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                        characters: characters, charactersIgnoringModifiers: characters,
                                        isARepeat: repeatPress, keyCode: keyCode)!
            NSApp.sendEvent(event)
            guard capture.bytes == Array(expected.utf8) else {
                print("FAIL: \(label): expected \(Array(expected.utf8)), got \(capture.bytes)")
                exit(1)
            }
            print("PASS: \(label)")
        }

        check("Shift-Return stays distinct from submit", modifiers: .shift, expected: "\u{1b}[13;2u")
        check("Shift-keypad-Enter stays distinct from submit", keyCode: 76,
              modifiers: [.shift, .numericPad], expected: "\u{1b}[13;2u")
        check("Caps Lock does not disable Shift-Return", modifiers: [.shift, .capsLock], expected: "\u{1b}[13;2u")
        check("held Shift-Return repeats newlines", modifiers: .shift, repeatPress: true, expected: "\u{1b}[13;2u")
        check("plain Return still submits", modifiers: [], expected: "\r")
        check("plain keypad Enter still submits", keyCode: 76, modifiers: .numericPad, expected: "\r")
        view.optionAsMetaKey = true
        check("Option-Return retains its encoding", modifiers: .option, expected: "\u{1b}\r")
        check("Shift-Option-Return retains its encoding", modifiers: [.shift, .option], expected: "\u{1b}\r")
        check("legacy Shift-Return release sends nothing", modifiers: .shift, type: .keyUp, expected: "")

        // Applications can negotiate their own keyboard reporting.
        view.feed(text: "\u{1b}[>11u")
        precondition(view.getTerminal().keyboardEnhancementFlags.rawValue == 11)
        check("negotiated Shift-Return press", modifiers: .shift, expected: "\u{1b}[13;2u")

        // An installed monitor for an unfocused pane must not send extra input.
        let otherView = HerdrTerminalView(frame: view.frame)
        let otherCapture = InputCapture()
        otherView.terminalDelegate = otherCapture
        view.addSubview(otherView)
        let otherCoordinator = TerminalSurface.Coordinator(controller: TerminalController(), store: store, paneID: "other-pane")
        otherCoordinator.view = otherView
        otherCoordinator.installEvents()
        defer { otherCoordinator.removeEvents() }
        view.feed(text: "\u{1b}[<u")
        check("only the focused pane receives Shift-Return", modifiers: .shift, expected: "\u{1b}[13;2u")
        precondition(otherCapture.bytes.isEmpty)
    }
}

private final class InputCapture: TerminalViewDelegate {
    var bytes: [UInt8] = []
    func send(source: TerminalView, data: ArraySlice<UInt8>) { bytes.append(contentsOf: data) }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
