import Foundation
import HerdrCore

enum TerminalStartSizeTests {
    static func run() {
        // Measured on a 1454×939 pt pane at 2×: Ghostty first reports its 800×600 px
        // default (50×20 cells), then 2908×1878 px (181×62 cells) once laid out.
        XCTAssertTrue(!TerminalStartSize.fillsView(widthPixels: 800, heightPixels: 600, viewWidth: 1454, viewHeight: 939, scale: 2))
        XCTAssertTrue(TerminalStartSize.fillsView(widthPixels: 2908, heightPixels: 1878, viewWidth: 1454, viewHeight: 939, scale: 2))
        // Fractional points round to the nearest pixel; a one-cell difference does not pass.
        XCTAssertTrue(TerminalStartSize.fillsView(widthPixels: 2909, heightPixels: 1877, viewWidth: 1454.5, viewHeight: 938.6, scale: 2))
        XCTAssertTrue(!TerminalStartSize.fillsView(widthPixels: 2908 - 16, heightPixels: 1878, viewWidth: 1454, viewHeight: 939, scale: 2))
        XCTAssertTrue(TerminalStartSize.fillsView(widthPixels: 1454, heightPixels: 939, viewWidth: 1454, viewHeight: 939, scale: 1))
        // Not yet in a window, not laid out, or no pixel size: wait.
        XCTAssertTrue(!TerminalStartSize.fillsView(widthPixels: 2908, heightPixels: 1878, viewWidth: 1454, viewHeight: 939, scale: 0))
        XCTAssertTrue(!TerminalStartSize.fillsView(widthPixels: 800, heightPixels: 600, viewWidth: 0, viewHeight: 0, scale: 2))
        XCTAssertTrue(!TerminalStartSize.fillsView(widthPixels: 0, heightPixels: 0, viewWidth: 1454, viewHeight: 939, scale: 2))
        print("PASS: terminals attach only at a laid-out size, with Ghostty's 800×600 default rejected")
    }

    @MainActor static func runGate() {
        var started = false
        var delivered: [[Int]] = []
        var timers: [(TimeInterval, @MainActor () -> Void)] = []
        func makeGate() -> TerminalStartGate {
            TerminalStartGate(isStarted: { started }, schedule: { timers.append(($0, $1)) },
                              deliver: { cols, rows in delivered.append([cols, rows]); started = true })
        }
        let placeholder = TerminalStartGate.Grid(columns: 50, rows: 20, widthPixels: 800, heightPixels: 600)
        let laidOut = TerminalStartGate.Grid(columns: 181, rows: 62, widthPixels: 2908, heightPixels: 1878)
        // Measured case: placeholder first, real size 15 ms later; the fallback then does nothing.
        var gate = makeGate()
        gate.report(placeholder, viewWidth: 1454, viewHeight: 939, scale: 2)
        XCTAssertTrue(delivered.isEmpty)
        XCTAssertEqual(timers.count, 1)
        XCTAssertEqual(timers[0].0, TerminalStartSize.fallbackDelay)
        gate.report(laidOut, viewWidth: 1454, viewHeight: 939, scale: 2)
        XCTAssertEqual(delivered, [[181, 62]])
        timers[0].1()
        XCTAssertEqual(delivered, [[181, 62]])
        // Once started, every report resizes.
        gate.report(TerminalStartGate.Grid(columns: 120, rows: 40, widthPixels: 1, heightPixels: 1), viewWidth: 1454, viewHeight: 939, scale: 2)
        XCTAssertEqual(delivered, [[181, 62], [120, 40]])
        // No laid-out size ever arrives: the fallback attaches with the latest size, scheduled once.
        started = false; delivered = []; timers = []
        gate = makeGate()
        gate.report(placeholder, viewWidth: 0, viewHeight: 0, scale: 0)
        gate.report(TerminalStartGate.Grid(columns: 60, rows: 22, widthPixels: 960, heightPixels: 660), viewWidth: 0, viewHeight: 0, scale: 0)
        XCTAssertEqual(timers.count, 1)
        XCTAssertTrue(delivered.isEmpty)
        timers[0].1()
        XCTAssertEqual(delivered, [[60, 22]])
        print("PASS: panes attach at the laid-out size, or with the latest size when the fallback fires")
    }
}
