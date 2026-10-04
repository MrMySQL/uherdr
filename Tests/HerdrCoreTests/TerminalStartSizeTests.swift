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
}
