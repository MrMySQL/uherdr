import AppKit
import SwiftUI

/// A local recorder whose events belong to this sheet, excluding text editors.
struct ShortcutRecordingMonitor: NSViewRepresentable {
    var handler: (NSEvent) -> NSEvent?

    func makeNSView(context: Context) -> ShortcutRecordingView {
        let view = ShortcutRecordingView()
        view.handler = handler
        return view
    }

    func updateNSView(_ view: ShortcutRecordingView, context: Context) {
        view.handler = handler
    }

    static func dismantleNSView(_ view: ShortcutRecordingView, coordinator: ()) {
        view.stopMonitoring()
    }
}

final class ShortcutRecordingView: NSView {
    var handler: ((NSEvent) -> NSEvent?)?
    private var monitor: Any?
    var isMonitoring: Bool { monitor != nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopMonitoring()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.filter(event)
        }
    }

    func filter(_ event: NSEvent) -> NSEvent? {
        guard let window, event.window === window else { return event }
        guard !(window.firstResponder is NSTextView), !(window.firstResponder is NSTextField) else { return event }
        guard let handler else { return event }
        return handler(event)
    }

    func stopMonitoring() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }
}
