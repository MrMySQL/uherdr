import AppKit
import HerdrCore
@testable import HerdrMac

extension TerminalPerformanceTests {
    @MainActor static func paneResizePreview() async throws {
        var resize = PaneResizeState()
        resize.update(translation: 160, available: 800, ratio: 0.5)
        guard resize.previewRatio == 0.7, resize.layoutRatio(fallback: 0.5) == 0.5 else {
            throw HerdrError.message("Dragging must preview without resizing panes")
        }
        let committed = resize.finish(translation: 200, available: 800, ratio: 0.5)
        guard committed == 0.75, resize.previewRatio == nil, resize.layoutRatio(fallback: 0.5) == 0.75 else {
            throw HerdrError.message("Release must apply the final pointer position and clear the preview")
        }
        resize.update(translation: -160, available: 800, ratio: 0.5)
        guard resize.previewRatio == 0.55, resize.layoutRatio(fallback: 0.5) == 0.75 else {
            throw HerdrError.message("A second drag must start at the applied size while awaiting the server")
        }
        resize.cancel()
        guard resize.previewRatio == nil, resize.layoutRatio(fallback: 0.5) == 0.75 else {
            throw HerdrError.message("Cancellation must discard only the preview")
        }
        resize = PaneResizeState()
        resize.update(translation: 160, available: 800, ratio: 0.5)
        let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
            characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
        NSApp.sendEvent(escape)
        guard resize.previewRatio == nil, resize.layoutRatio(fallback: 0.5) == 0.5 else {
            throw HerdrError.message("Escape must cancel the preview and preserve the original pane sizes")
        }
        resize.update(translation: 240, available: 800, ratio: 0.5)
        guard resize.previewRatio == nil,
              resize.finish(translation: 300, available: 800, ratio: 0.5) == nil,
              resize.layoutRatio(fallback: 0.5) == 0.5 else {
            throw HerdrError.message("Movement and release after Escape must not resurrect or commit the canceled resize")
        }
        resize.update(translation: 80, available: 800, ratio: 0.5)
        guard resize.previewRatio == 0.6,
              resize.finish(translation: 80, available: 800, ratio: 0.5) == 0.6 else {
            throw HerdrError.message("A new drag after Escape cancellation must resize normally")
        }
        resize = PaneResizeState()
        resize.cancel() // Zoom and accessibility changes may cancel while idle.
        resize.update(translation: 80, available: 800, ratio: 0.5)
        guard resize.previewRatio == 0.6 else {
            throw HerdrError.message("Canceling while idle must not suppress the next drag")
        }
        resize = PaneResizeState()
        resize.update(translation: 1000, available: 800, ratio: 0.5)
        guard resize.previewRatio == 0.9 else { throw HerdrError.message("Preview must honor the upper size limit") }
        guard resize.finish(translation: -1000, available: 800, ratio: 0.5) == 0.1 else {
            throw HerdrError.message("Release must honor the lower size limit")
        }
        resize = PaneResizeState()
        resize.update(translation: 100, available: 0, ratio: 0.5)
        guard resize.previewRatio == nil, resize.finish(translation: 100, available: 0, ratio: 0.5) == nil else {
            throw HerdrError.message("A zero-sized split must not resize")
        }
        print("PASS: pane resize preview, final release position, repeated drags, Escape cancellation, and size limits")
    }
}
