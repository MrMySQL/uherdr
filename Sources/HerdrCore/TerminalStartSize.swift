import Foundation

/// Ghostty reports a default 800×600 px grid before the view is laid out.
/// Attaching at that size shrinks the shared herdr pane for every client and
/// cuts its lines, so a pane attaches only once the grid fills its view.
public enum TerminalStartSize {
    public static func fillsView(widthPixels: UInt32, heightPixels: UInt32,
                                 viewWidth: Double, viewHeight: Double, scale: Double) -> Bool {
        guard scale > 0, viewWidth > 0, viewHeight > 0, widthPixels > 0, heightPixels > 0 else { return false }
        // Allow for points that round to fractional pixels.
        return abs(Double(widthPixels) - viewWidth * scale) <= scale + 1
            && abs(Double(heightPixels) - viewHeight * scale) <= scale + 1
    }

    /// How long to wait for a laid-out size before attaching with the latest one.
    public static let fallbackDelay: TimeInterval = 0.25
}
