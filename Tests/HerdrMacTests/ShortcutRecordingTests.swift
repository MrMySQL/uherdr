import AppKit

@main struct ShortcutRecordingTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100),
                             styleMask: [.titled], backing: .buffered, defer: false)
        let recorder = ShortcutRecordingView()
        window.contentView!.addSubview(recorder)
        var recorded = 0
        recorder.handler = { _ in recorded += 1; return nil }
        func key(in window: NSWindow?) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                             windowNumber: window?.windowNumber ?? 0, context: nil,
                             characters: "p", charactersIgnoringModifiers: "p", isARepeat: false, keyCode: 35)!
        }
        window.makeFirstResponder(nil)
        precondition(recorder.filter(key(in: window)) == nil && recorded == 1, "A sheet shortcut is consumed once")
        precondition(recorder.filter(key(in: other)) != nil && recorded == 1, "Other windows must not be recorded")
        precondition(recorder.filter(key(in: nil)) != nil && recorded == 1, "Unowned events must pass through")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 250, height: 24))
        field.isEditable = true
        window.contentView!.addSubview(field)
        precondition(window.makeFirstResponder(field), "Search field must accept focus")
        precondition(window.firstResponder is NSTextView || window.firstResponder is NSTextField)
        precondition(recorder.filter(key(in: window)) != nil && recorded == 1, "Search typing must not become a shortcut")
        let text = NSTextView(frame: NSRect(x: 0, y: 30, width: 250, height: 40))
        window.contentView!.addSubview(text)
        precondition(window.makeFirstResponder(text))
        precondition(recorder.filter(key(in: window)) != nil && recorded == 1, "Text views must keep their input")
        window.makeFirstResponder(nil)
        precondition(recorder.filter(key(in: window)) == nil && recorded == 2, "Recording resumes outside text input")
        recorder.handler = { $0 }
        precondition(recorder.filter(key(in: window)) != nil, "Idle recorder must pass events through")
        recorder.removeFromSuperview()
        precondition(recorder.filter(key(in: window)) != nil, "Detached sheet must not record")
        recorder.stopMonitoring()
        print("PASS: shortcut recording consumes sheet keys only; Search, text views, other windows, idle and detached sheets pass through")
    }
}
