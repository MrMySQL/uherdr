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
        var view: TerminalStartGate.ViewSize = (1454, 939, 2)
        var delivered: [[Int]] = []
        var timers: [(TimeInterval, @MainActor () -> Void)] = []
        func makeGate() -> TerminalStartGate {
            TerminalStartGate(isStarted: { started }, viewSize: { view }, schedule: { timers.append(($0, $1)) },
                              deliver: { cols, rows in delivered.append([cols, rows]); started = true })
        }
        func reset(_ size: TerminalStartGate.ViewSize) { started = false; view = size; delivered = []; timers = [] }
        func fire() { timers.removeFirst().1() }
        let placeholder = TerminalStartGate.Grid(columns: 50, rows: 20, widthPixels: 800, heightPixels: 600)
        let laidOut = TerminalStartGate.Grid(columns: 181, rows: 62, widthPixels: 2908, heightPixels: 1878)
        // Measured case: placeholder first, real size 15 ms later; the fallback then does nothing.
        var gate = makeGate()
        gate.report(placeholder)
        XCTAssertTrue(delivered.isEmpty)
        XCTAssertEqual(timers.count, 1)
        XCTAssertEqual(timers[0].0, TerminalStartSize.fallbackDelay)
        gate.report(laidOut)
        XCTAssertEqual(delivered, [[181, 62]])
        fire()
        XCTAssertEqual(delivered, [[181, 62]])
        XCTAssertTrue(timers.isEmpty)
        // Once started, every report resizes.
        gate.report(TerminalStartGate.Grid(columns: 120, rows: 40, widthPixels: 1, heightPixels: 1))
        XCTAssertEqual(delivered, [[181, 62], [120, 40]])
        // Slow layout: the first tick re-arms instead of attaching at the placeholder,
        // and the laid-out size attaches when it arrives.
        reset((1454, 939, 2))
        gate = makeGate()
        gate.report(placeholder)
        fire()
        XCTAssertTrue(delivered.isEmpty)
        XCTAssertEqual(timers.count, 1)
        XCTAssertEqual(timers[0].0, TerminalStartSize.fallbackDelay)
        gate.report(laidOut)
        XCTAssertEqual(delivered, [[181, 62]])
        fire()
        XCTAssertEqual(delivered, [[181, 62]])
        XCTAssertTrue(timers.isEmpty)
        // The view is laid out after the last report: a tick attaches once that size fills it.
        reset((0, 0, 0))
        gate = makeGate()
        gate.report(laidOut)
        fire()
        XCTAssertTrue(delivered.isEmpty)
        view = (1454, 939, 2)
        fire()
        XCTAssertEqual(delivered, [[181, 62]])
        XCTAssertTrue(timers.isEmpty)
        // No laid-out size ever arrives: after the last tick the latest size attaches,
        // with one timer chain however many reports arrive.
        reset((0, 0, 0))
        gate = makeGate()
        gate.report(placeholder)
        for _ in 1..<TerminalStartSize.fallbackTicks {
            gate.report(placeholder)
            XCTAssertEqual(timers.count, 1)
            fire()
            XCTAssertTrue(delivered.isEmpty)
        }
        gate.report(TerminalStartGate.Grid(columns: 60, rows: 22, widthPixels: 960, heightPixels: 660))
        XCTAssertEqual(timers.count, 1)
        fire()
        XCTAssertEqual(delivered, [[60, 22]])
        XCTAssertTrue(timers.isEmpty)
        print("PASS: panes attach at the laid-out size, or with the latest size after the bounded fallback")
    }
}
