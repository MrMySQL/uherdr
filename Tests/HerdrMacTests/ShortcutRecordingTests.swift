import AppKit

@main struct ShortcutRecordingTests {
    @MainActor static func main() {
        let app = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100),
                             styleMask: [.titled], backing: .buffered, defer: false)
        let recorder = ShortcutRecordingView()
        precondition(!recorder.isMonitoring, "A view outside a window must not monitor")
        window.contentView!.addSubview(recorder)
        precondition(recorder.isMonitoring, "Joining a window starts the monitor")
        // Local monitors run in the order added, and nil ends the chain, so
        // this one counts the key presses the recorder let through.
        var passed = 0
        let probe = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in passed += 1; return event }!
        defer { NSEvent.removeMonitor(probe) }
        var recorded = 0
        recorder.handler = { _ in recorded += 1; return nil }
        // Through NSApp, as a real key press arrives, so the local monitor runs.
        func press(in window: NSWindow?) {
            app.sendEvent(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                           windowNumber: window?.windowNumber ?? 0, context: nil,
                                           characters: "p", charactersIgnoringModifiers: "p", isARepeat: false, keyCode: 35)!)
        }
        window.makeFirstResponder(nil)
        press(in: window)
        precondition(recorded == 1 && passed == 0, "A sheet shortcut is recorded once, and consumed")
        press(in: other)
        precondition(recorded == 1 && passed == 1, "Other windows must not be recorded")
        press(in: nil)
        precondition(recorded == 1 && passed == 2, "Unowned events must pass through")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 250, height: 24))
        field.isEditable = true
        window.contentView!.addSubview(field)
        precondition(window.makeFirstResponder(field), "Search field must accept focus")
        precondition(window.firstResponder is NSTextView || window.firstResponder is NSTextField)
        press(in: window)
        precondition(recorded == 1 && passed == 3, "Search typing must reach the field, not become a shortcut")
        let text = NSTextView(frame: NSRect(x: 0, y: 30, width: 250, height: 40))
        window.contentView!.addSubview(text)
        precondition(window.makeFirstResponder(text))
        press(in: window)
        precondition(recorded == 1 && passed == 4, "Text views must keep their input")
        window.makeFirstResponder(nil)
        press(in: window)
        precondition(recorded == 2 && passed == 4, "Recording resumes outside text input")

        // Moving to another window replaces the monitor rather than adding one.
        other.contentView!.addSubview(recorder)
        precondition(recorder.isMonitoring)
        press(in: other)
        precondition(recorded == 3, "A moved sheet records once, in its new window")
        press(in: window)
        precondition(recorded == 3, "The old window is no longer recorded")
        recorder.removeFromSuperview()
        precondition(!recorder.isMonitoring, "Leaving the window removes the monitor")
        press(in: other)
        precondition(recorded == 3, "Detached sheet must not record")
        print("PASS: shortcut recording consumes sheet keys only; Search, text views, other windows and detached sheets pass through, with one monitor per window")
    }
}
