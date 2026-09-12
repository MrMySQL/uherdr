import AppKit
import SwiftUI
import HerdrCore

/// A tab's UI inputs are values. Descendants use the session only to perform
/// actions, so unrelated session notifications cannot invalidate hidden trees.
struct TerminalTabSnapshot: Equatable {
    let layout: TabLayout
    let panes: [String: Pane]
    var selectedPaneID: String?
    var dragPayloads: [String: PaneDragPayload]
    var moveDestinationTabs: [HerdrCore.Tab]
    let fontSize: Double
    let colorScheme: ColorScheme
    let displayScale: CGFloat
    var visible: Bool

    @MainActor init(layout: TabLayout, panes: [Pane], store: SessionStore,
                    colorScheme: ColorScheme, displayScale: CGFloat, visible: Bool) {
        self.layout = layout
        self.panes = Dictionary(uniqueKeysWithValues: panes.map { ($0.id, $0) })
        selectedPaneID = visible ? store.selectedPane : nil
        dragPayloads = Dictionary(uniqueKeysWithValues: panes.compactMap { pane in
            guard visible, let payload = store.paneDragPayload(for: pane.id) else { return nil }
            return (pane.id, payload)
        })
        fontSize = store.fontSize
        moveDestinationTabs = visible ? store.visibleTabs.filter { $0.id != layout.tabID } : []
        self.colorScheme = colorScheme
        self.displayScale = displayScale
        self.visible = visible
    }

    var terminalIDs: [String: String] { panes.mapValues(\.terminalID) }

    func hidden() -> Self {
        var copy = self
        copy.visible = false
        copy.selectedPaneID = nil
        copy.dragPayloads = [:]
        copy.moveDestinationTabs = []
        return copy
    }
}

struct TerminalTabDeck: NSViewRepresentable {
    @ObservedObject var store: SessionStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale

    func makeNSView(context: Context) -> TerminalTabDeckView { TerminalTabDeckView() }

    func updateNSView(_ view: TerminalTabDeckView, context: Context) {
        view.update(store: store, colorScheme: colorScheme, displayScale: displayScale)
    }

    static func dismantleNSView(_ view: TerminalTabDeckView, coordinator: ()) {
        view.removeAllTabs()
    }
}

/// Hidden hosts remain attached to the window: their Ghostty mailboxes and
/// streams can keep draining, but they do not resize or join the visible tab's
/// SwiftUI layout graph. Switching preserves native views and controllers.
@MainActor final class TerminalTabDeckView: NSView {
    private struct Entry {
        let host: NSHostingView<AnyView>
        var snapshot: TerminalTabSnapshot
    }
    private var entries: [String: Entry] = [:]
    private var selectedTabID: String?
    private weak var session: SessionStore?
    private var generation: UUID?

    override var isFlipped: Bool { true }

    func update(store: SessionStore, colorScheme: ColorScheme, displayScale: CGFloat) {
        if session !== store || generation != store.connectionGeneration {
            removeAllTabs()
            session = store
            generation = store.connectionGeneration
        }
        let retainedIDs = Set(store.tabs.map(\.id)).intersection(store.layouts.keys)
        for id in Array(entries.keys) where !retainedIDs.contains(id) { removeTab(id) }

        if selectedTabID != store.selectedTab, let oldID = selectedTabID, var old = entries[oldID] {
            // Stop native input/display immediately, before SwiftUI processes
            // the outgoing root's visibility change on its next update.
            PaneDropState.endDrag()
            setTerminals(in: old.host, visible: false)
            old.host.isHidden = true
            apply(old.snapshot.hidden(), to: &old, store: store)
            entries[oldID] = old
        }
        selectedTabID = store.selectedTab
        let panesByTab = Dictionary(grouping: store.panes, by: \.tabID)
        for tab in store.tabs {
            guard let layout = store.layouts[tab.id] else { continue }
            let visible = tab.id == selectedTabID
            let snapshot = TerminalTabSnapshot(layout: layout, panes: panesByTab[tab.id] ?? [], store: store,
                                               colorScheme: colorScheme, displayScale: displayScale, visible: visible)
            if var entry = entries[tab.id] {
                if visible {
                    let revealing = entry.host.isHidden
                    apply(snapshot, to: &entry, store: store)
                    if entry.host.frame != bounds { entry.host.frame = bounds }
                    if revealing {
                        // Process pending font, theme and metadata changes
                        // while hidden, then restore native input and focus.
                        entry.host.layoutSubtreeIfNeeded()
                        entry.host.isHidden = false
                        setTerminals(in: entry.host, visible: true, zoomedPaneID: zoomedPaneID(snapshot))
                    }
                } else if entry.snapshot.layout != snapshot.layout || entry.snapshot.terminalIDs != snapshot.terminalIDs {
                    // Close/replaced terminals must be released even while
                    // hidden. Cosmetic metadata catches up when revealed.
                    apply(snapshot, to: &entry, store: store)
                }
                entries[tab.id] = entry
            } else {
                let host = NSHostingView(rootView: root(snapshot, store: store))
                host.sizingOptions = []
                host.frame = bounds
                host.isHidden = true
                addSubview(host)
                if visible {
                    host.layoutSubtreeIfNeeded()
                    host.isHidden = false
                    setTerminals(in: host, visible: true, zoomedPaneID: zoomedPaneID(snapshot))
                }
                entries[tab.id] = Entry(host: host, snapshot: snapshot)
            }
        }
        needsLayout = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        if let id = selectedTabID, let host = entries[id]?.host, host.frame != bounds {
            host.frame = bounds
        }
    }

    private func apply(_ snapshot: TerminalTabSnapshot, to entry: inout Entry, store: SessionStore) {
        guard entry.snapshot != snapshot else { return }
        entry.snapshot = snapshot
        entry.host.rootView = root(snapshot, store: store)
    }

    private func root(_ snapshot: TerminalTabSnapshot, store: SessionStore) -> AnyView {
        AnyView(SplitTree(node: snapshot.layout.root, tabID: snapshot.layout.tabID, path: [], store: store,
                          snapshot: snapshot,
                          zoomedPaneID: zoomedPaneID(snapshot),
                          visible: snapshot.visible)
            .modifier(PaneDragLifecycle())
            .environment(\.colorScheme, snapshot.colorScheme)
            .environment(\.displayScale, snapshot.displayScale)
            .tint(herdrAccentColor)
            .accentColor(herdrAccentColor)
            .accessibilityHidden(!snapshot.visible)
            .frame(maxWidth: .infinity, maxHeight: .infinity))
    }

    private func zoomedPaneID(_ snapshot: TerminalTabSnapshot) -> String? {
        snapshot.layout.zoomed ? snapshot.layout.resolveSelectedPane(nil) : nil
    }

    private func setTerminals(in view: NSView, visible: Bool, zoomedPaneID: String? = nil) {
        if let terminal = view as? HerdrTerminalView {
            terminal.onRetainedTabVisibility?(visible, zoomedPaneID)
        }
        for child in view.subviews { setTerminals(in: child, visible: visible, zoomedPaneID: zoomedPaneID) }
    }

    private func removeTab(_ id: String) {
        guard let entry = entries.removeValue(forKey: id) else { return }
        setTerminals(in: entry.host, visible: false)
        entry.host.rootView = AnyView(EmptyView())
        entry.host.layoutSubtreeIfNeeded()
        entry.host.removeFromSuperview()
    }

    func removeAllTabs() {
        for id in Array(entries.keys) { removeTab(id) }
        selectedTabID = nil
    }
}
