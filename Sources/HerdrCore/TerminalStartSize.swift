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

/// Decides when a pane attaches: at once for a size that fills its view,
/// otherwise after `TerminalStartSize.fallbackDelay` with the latest size,
/// so a pane is never left unattached. The timer is injected for tests.
@MainActor
public final class TerminalStartGate {
    public struct Grid: Equatable, Sendable {
        public let columns: Int, rows: Int, widthPixels: UInt32, heightPixels: UInt32
        public init(columns: Int, rows: Int, widthPixels: UInt32, heightPixels: UInt32) {
            self.columns = columns; self.rows = rows; self.widthPixels = widthPixels; self.heightPixels = heightPixels
        }
    }

    public typealias Schedule = (TimeInterval, @escaping @MainActor () -> Void) -> Void
    private let isStarted: () -> Bool
    private let schedule: Schedule
    private let deliver: (Int, Int) -> Void
    private var pending: Grid?

    /// `deliver` starts the pane or, once started, resizes it.
    public init(isStarted: @escaping () -> Bool, schedule: @escaping Schedule, deliver: @escaping (Int, Int) -> Void) {
        self.isStarted = isStarted
        self.schedule = schedule
        self.deliver = deliver
    }

    public func report(_ grid: Grid, viewWidth: Double, viewHeight: Double, scale: Double) {
        guard !isStarted() else { return deliver(grid.columns, grid.rows) }
        if TerminalStartSize.fillsView(widthPixels: grid.widthPixels, heightPixels: grid.heightPixels,
                                       viewWidth: viewWidth, viewHeight: viewHeight, scale: scale) {
            pending = nil
            return deliver(grid.columns, grid.rows)
        }
        let waiting = pending != nil
        pending = grid
        guard !waiting else { return }
        schedule(TerminalStartSize.fallbackDelay) { [weak self] in
            guard let self, !self.isStarted(), let latest = self.pending else { return }
            self.pending = nil
            self.deliver(latest.columns, latest.rows)
        }
    }
}
