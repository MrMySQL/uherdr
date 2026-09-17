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
        print("PASS: pane resize preview, final release position, repeated drags, cancellation, and size limits")
    }
}
