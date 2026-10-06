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

    /// How often the fallback re-checks for a laid-out size.
    public static let fallbackDelay: TimeInterval = 0.25
    /// Re-checks before attaching with the latest size anyway: 8 × 0.25 s = 2 s,
    /// long enough for window animations and multi-pane tab restores, short
    /// enough that a pane in a never-shown view does not sit blank for long.
    public static let fallbackTicks = 8
}

/// Decides when a pane attaches: at once for a size that fills its view,
/// otherwise at the first fallback tick where the latest size fills the
/// view as it is then, or after `fallbackTicks` ticks with the latest size,
/// so a pane is never left unattached. The view size and timer are injected for tests.
@MainActor
public final class TerminalStartGate {
    public struct Grid: Equatable, Sendable {
        public let columns: Int, rows: Int, widthPixels: UInt32, heightPixels: UInt32
        public init(columns: Int, rows: Int, widthPixels: UInt32, heightPixels: UInt32) {
            self.columns = columns; self.rows = rows; self.widthPixels = widthPixels; self.heightPixels = heightPixels
        }
    }

    public typealias ViewSize = (width: Double, height: Double, scale: Double)
    public typealias Schedule = (TimeInterval, @escaping @MainActor () -> Void) -> Void
    private let isStarted: () -> Bool
    private let viewSize: () -> ViewSize
    private let schedule: Schedule
    private let deliver: (Int, Int) -> Void
    private var pending: Grid?
    /// Ticks left in the running fallback chain; zero when none is running.
    private var ticksLeft = 0

    /// `viewSize` is the view's current size in points and its backing scale.
    /// `deliver` starts the pane or, once started, resizes it.
    public init(isStarted: @escaping () -> Bool, viewSize: @escaping () -> ViewSize,
                schedule: @escaping Schedule, deliver: @escaping (Int, Int) -> Void) {
        self.isStarted = isStarted
        self.viewSize = viewSize
        self.schedule = schedule
        self.deliver = deliver
    }

    public func report(_ grid: Grid) {
        guard !isStarted() else { return deliver(grid.columns, grid.rows) }
        if fills(grid) {
            pending = nil
            return deliver(grid.columns, grid.rows)
        }
        pending = grid
        guard ticksLeft == 0 else { return }
        ticksLeft = TerminalStartSize.fallbackTicks
        scheduleTick()
    }

    private func scheduleTick() {
        schedule(TerminalStartSize.fallbackDelay) { [weak self] in
            guard let self else { return }
            ticksLeft -= 1
            guard !isStarted(), let latest = pending else { ticksLeft = 0; return }
            // The view may have been laid out since the last report; until the
            // last tick, wait for a size that fills it rather than attach small.
            guard ticksLeft == 0 || fills(latest) else { return scheduleTick() }
            ticksLeft = 0
            pending = nil
            deliver(latest.columns, latest.rows)
        }
    }

    private func fills(_ grid: Grid) -> Bool {
        let view = viewSize()
        return TerminalStartSize.fillsView(widthPixels: grid.widthPixels, heightPixels: grid.heightPixels,
                                           viewWidth: view.width, viewHeight: view.height, scale: view.scale)
    }
}
