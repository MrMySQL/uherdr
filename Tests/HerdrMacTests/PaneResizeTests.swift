import AppKit
import SwiftUI
import HerdrCore
@testable import HerdrMac

extension TerminalPerformanceTests {
    @MainActor static func paneResizePreview() async throws {
        try paneResizePreviewGeometry()
        try await paneResizeEffectiveLayout()
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

    static func paneResizePreviewGeometry() throws {
        let row = LayoutNode.split(.right, 0.25, .pane("a"),
                                   .split(.right, 0.5, .pane("b"), .pane("c")))
        let column = LayoutNode.split(.down, 0.25, .pane("a"),
                                      .split(.down, 0.5, .pane("b"), .pane("c")))
        let mixed = LayoutNode.split(.right, 0.5,
            .split(.down, 0.25, .pane("a"), .pane("b")),
            .split(.right, 0.75, .pane("c"), .pane("d")))
        let fixtures: [(LayoutNode, CGRect, [PaneResizePreviewFrame])] = [
            (row, CGRect(x: 0, y: 0, width: 808, height: 608), [
                .init(id: "a", rect: CGRect(x: 0, y: 0, width: 200, height: 608)),
                .init(id: "b", rect: CGRect(x: 208, y: 0, width: 296, height: 608)),
                .init(id: "c", rect: CGRect(x: 512, y: 0, width: 296, height: 608))
            ]),
            (column, CGRect(x: 0, y: 0, width: 608, height: 808), [
                .init(id: "a", rect: CGRect(x: 0, y: 0, width: 608, height: 200)),
                .init(id: "b", rect: CGRect(x: 0, y: 208, width: 608, height: 296)),
                .init(id: "c", rect: CGRect(x: 0, y: 512, width: 608, height: 296))
            ]),
            (mixed, CGRect(x: 10, y: 20, width: 808, height: 608), [
                .init(id: "a", rect: CGRect(x: 10, y: 20, width: 400, height: 150)),
                .init(id: "b", rect: CGRect(x: 10, y: 178, width: 400, height: 450)),
                .init(id: "c", rect: CGRect(x: 418, y: 20, width: 294, height: 608)),
                .init(id: "d", rect: CGRect(x: 720, y: 20, width: 98, height: 608))
            ])
        ]
        for (layout, bounds, expected) in fixtures {
            guard PaneResizePreviewFrame.frames(for: layout, in: bounds) == expected else {
                throw HerdrError.message("Resize preview must show each leaf pane with its nested ratios and divider gaps")
            }
        }
        print("PASS: per-pane resize previews for rows, columns, and mixed nested splits")
    }

    @MainActor static func paneResizeEffectiveLayout() async throws {
        // The parent still has the server's 50/50 layout; its child already
        // displays the 75/25 ratio applied by the preceding resize.
        let staleChild = LayoutNode.split(.down, 0.5, .pane("a"), .pane("b"))
        var reported: LayoutNode?
        let pair = ResizablePair(direction: .right, ratio: 0.25,
                                 firstLayout: staleChild, secondLayout: .pane("c"), onCommit: { _ in }) {
            ResizablePair(direction: .down, ratio: 0.75,
                          firstLayout: .pane("a"), secondLayout: .pane("b"), onCommit: { _ in }) {
                Color.clear
            } second: {
                Color.clear
            }
        } second: {
            Color.clear
        }
        let host = NSHostingView(rootView: pair.onPreferenceChange(PaneResizeLayoutKey.self) { reported = $0 })
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 808, height: 608),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        defer { window.close() }
        let expected = LayoutNode.split(.right, 0.25,
                                       .split(.down, 0.75, .pane("a"), .pane("b")), .pane("c"))
        for _ in 0..<20 {
            host.layoutSubtreeIfNeeded()
            if reported == expected { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        guard reported == expected else {
            throw HerdrError.message("Parent resize preview must use the displayed child ratio while server layout is stale")
        }
        print("PASS: nested preview layout follows displayed ratios before server acknowledgement")
    }
}
