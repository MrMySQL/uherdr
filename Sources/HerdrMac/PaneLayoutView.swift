import SwiftUI
import HerdrCore
import UniformTypeIdentifiers

private extension UTType {
    static let herdrPane = UTType(exportedAs: "dev.herdr.native.pane", conformingTo: .data)
}

extension PaneDragPayload: Transferable {
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .herdrPane)
    }
}

struct SplitTree: View {
    let node: LayoutNode
    let tabID: String
    let path: [Bool]
    let store: SessionStore
    let snapshot: TerminalTabSnapshot
    var zoomedPaneID: String? = nil
    var visible = true
    var body: some View {
        content
    }
    private var content: AnyView {
        switch node {
        case .pane(let id):
            if let pane = snapshot.panes[id] {
                return AnyView(PaneCard(pane: pane, store: store, snapshot: snapshot, zoomed: zoomedPaneID == id,
                                        visible: visible && (zoomedPaneID == nil || zoomedPaneID == id)).id(pane.terminalID))
            }
            return AnyView(Color.clear)
        case .split(let direction, let ratio, let first, let second):
            let expandedFirst: Bool? = zoomedPaneID.flatMap { id in
                if first.paneIDs.contains(id) { return true }
                if second.paneIDs.contains(id) { return false }
                return nil
            }
            return AnyView(ResizablePair(direction: direction, ratio: ratio, expandedFirst: expandedFirst,
                                        onCommit: { store.setRatio(tabID: tabID, path: path, ratio: $0) }) {
                SplitTree(node: first, tabID: tabID, path: path + [false], store: store, snapshot: snapshot, zoomedPaneID: zoomedPaneID, visible: visible)
            } second: {
                SplitTree(node: second, tabID: tabID, path: path + [true], store: store, snapshot: snapshot, zoomedPaneID: zoomedPaneID, visible: visible)
            })
        }
    }
}

struct ResizablePair<First: View, Second: View>: View {
    let direction: SplitDirection
    let ratio: Double
    var expandedFirst: Bool? = nil
    let onCommit: (Double) -> Void
    @ViewBuilder let first: () -> First
    @ViewBuilder let second: () -> Second
    @State private var draggedRatio: Double?
    @State private var dragStart: Double?
    @State private var hovering = false
    var body: some View {
        GeometryReader { geometry in
            let size = direction == .right ? geometry.size.width : geometry.size.height
            let available = max(0, size - 8)
            let fraction = draggedRatio ?? ratio
            let horizontal = direction == .right
            let firstSize = expandedFirst == true ? size : max(0, available * fraction)
            let secondSize = expandedFirst == false ? size : max(0, available * (1 - fraction))
            let secondOffset = expandedFirst == false ? 0 : available * fraction + 8
            // Keep both branches mounted: replacing them on zoom reconnects every
            // terminal stream and rebuilds its renderer. Only geometry changes.
            ZStack(alignment: .topLeading) {
                first()
                    .frame(width: horizontal ? firstSize : geometry.size.width,
                           height: horizontal ? geometry.size.height : firstSize)
                    .opacity(expandedFirst == false ? 0 : 1)
                    .allowsHitTesting(expandedFirst != false)
                    .accessibilityHidden(expandedFirst == false)
                second()
                    .frame(width: horizontal ? secondSize : geometry.size.width,
                           height: horizontal ? geometry.size.height : secondSize)
                    .offset(x: horizontal ? secondOffset : 0, y: horizontal ? 0 : secondOffset)
                    .opacity(expandedFirst == true ? 0 : 1)
                    .allowsHitTesting(expandedFirst != true)
                    .accessibilityHidden(expandedFirst == true)
                divider(available: available)
                    .frame(width: horizontal ? 8 : geometry.size.width,
                           height: horizontal ? geometry.size.height : 8)
                    .offset(x: horizontal ? available * fraction : 0, y: horizontal ? 0 : available * fraction)
                    .opacity(expandedFirst == nil ? 1 : 0)
                    .allowsHitTesting(expandedFirst == nil)
                    .accessibilityHidden(expandedFirst != nil)
            }
        }
        .onChange(of: ratio) { _, _ in draggedRatio = nil }
    }
    private func divider(available: CGFloat) -> some View {
        Rectangle().fill(Color.clear)
            .overlay {
                RoundedRectangle(cornerRadius: 2)
                    .fill(hovering || dragStart != nil ? Color.accentColor.opacity(0.65) : Color.primary.opacity(0.09))
                    .frame(width: direction == .right ? 2 : 34, height: direction == .right ? 34 : 2)
            }
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    guard available > 0 else { return }
                    if dragStart == nil { dragStart = draggedRatio ?? ratio }
                    let translation = direction == .right ? value.translation.width : value.translation.height
                    draggedRatio = min(0.9, max(0.1, (dragStart ?? ratio) + translation / available))
                }
                .onEnded { _ in
                    onCommit(draggedRatio ?? ratio)
                    dragStart = nil
                })
            .accessibilityLabel(direction == .right ? "Resize side-by-side panes" : "Resize stacked panes")
            .accessibilityAdjustableAction { adjustment in
                let value = min(0.9, max(0.1, (draggedRatio ?? ratio) + (adjustment == .increment ? 0.05 : -0.05)))
                draggedRatio = value; onCommit(value)
            }
    }
}

struct PaneCard: View {
    let pane: Pane
    let store: SessionStore
    let snapshot: TerminalTabSnapshot
    let zoomed: Bool
    var visible = true
    @StateObject private var controller = TerminalController()
    @StateObject private var drop = PaneDropState()
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale
    private var selected: Bool { snapshot.selectedPaneID == pane.id }
    private var target: ResourceTarget { ResourceTarget(kind: "pane", id: pane.id, label: pane.displayTitle) }
    var body: some View {
        GeometryReader { geometry in
            card
                .overlay(alignment: .topLeading) {
                    if let edge = drop.edge, visible, snapshot.dragPayloads[pane.id] != nil {
                        let rect = edge.preview(in: geometry.size)
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.accentColor.opacity(0.25))
                            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor, lineWidth: 2) }
                            .frame(width: rect.width, height: rect.height)
                            .offset(x: rect.minX, y: rect.minY)
                            .allowsHitTesting(false)
                    }
                }
                .onDrop(of: [.herdrPane], delegate: PaneDockDropDelegate(
                    paneID: pane.id, size: geometry.size, visible: visible, store: store, state: drop
                ))
        }
        .onChange(of: visible) { _, visible in if !visible { drop.reset() } }
        .onDisappear { drop.reset() }
    }

    private var card: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                draggableTitle
                Button { store.zoom(pane.id) } label: { Image(systemName: zoomed ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") }
                    .buttonStyle(.plain).help(zoomed ? "Restore split layout" : "Zoom pane")
                    .frame(height: 11)
                Menu {
                    Button("Split side by side") { store.split(.right, paneID: pane.id) }
                    Button("Split top and bottom") { store.split(.down, paneID: pane.id) }
                    Divider()
                    Button("Start agent…") { store.sheet = .agent(pane.id) }
                    Button("Rename pane…") { store.sheet = .rename(target) }
                    Button("Reconnect terminal") { controller.retry() }
                    Divider()
                    Button("Close pane…", role: .destructive) { store.pendingClose = target }
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Pane actions")
                    .frame(height: 11)
            }
            .foregroundStyle(.secondary).font(.system(size: 10))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 11).padding(.vertical, 1 / displayScale)
            .background(selected ? Color.accentColor.opacity(0.075) : Color.primary.opacity(0.025))
            .contentShape(Rectangle()).onTapGesture { store.focusPane(pane.id) }
            Divider().opacity(0.6)
            ZStack {
                TerminalSurface(controller: controller, pane: pane, store: store, dark: colorScheme == .dark, fontSize: snapshot.fontSize, selected: selected, visible: visible)
                    .padding(7)
                if let error = controller.error {
                    VStack(spacing: 12) {
                        Image(systemName: "terminal").font(.title2).foregroundStyle(.secondary)
                        Text("Terminal disconnected").font(.system(size: 13, weight: .semibold))
                        Text(error).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center).lineLimit(6).textSelection(.enabled)
                        HStack {
                            Button("Reconnect") { controller.retry() }
                            Button("Take control") { controller.retry(takeover: true) }
                                .help("Replace another client's writable control of this terminal")
                        }.controlSize(.small)
                    }.padding(22).frame(maxWidth: 400).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)).padding(12)
                }
            }
            .background(colorScheme == .dark ? Color(red: 0.055, green: 0.065, blue: 0.075) : Color(red: 0.98, green: 0.98, blue: 0.97))
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? Color.accentColor.opacity(0.5) : Color.primary.opacity(0.1), lineWidth: 1) }
    }

    @ViewBuilder private var draggableTitle: some View {
        if visible, let payload = snapshot.dragPayloads[pane.id] {
            paneTitle.draggable(payload) {
                Label(pane.displayTitle, systemImage: "terminal")
                    .font(.system(size: 12, weight: .medium))
                    .padding(10).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
        } else {
            paneTitle
        }
    }

    private var paneTitle: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 9)).foregroundStyle(.tertiary)
            Image(systemName: pane.agent == nil ? "terminal" : "sparkles")
                .font(.system(size: 10)).foregroundStyle(selected ? Color.accentColor : .secondary)
            Text(pane.displayTitle).font(.system(size: 11, weight: .medium)).lineLimit(1)
            if pane.agent != nil { StatusBadge(status: pane.agentStatus) }
            Spacer(minLength: 4)
        }
        .contentShape(Rectangle())
        .help("Drag to a pane’s top, bottom, left, or right edge to move it")
        .accessibilityHint("Drag to a pane’s top, bottom, left, or right edge to move it")
    }
}

@MainActor
final class PaneDropState: ObservableObject {
    private static let activePreviews = NSHashTable<PaneDropState>.weakObjects()

    @Published var edge: PaneDockEdge? {
        didSet {
            if edge == nil {
                Self.activePreviews.remove(self)
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
                releaseTimer?.invalidate()
                releaseTimer = nil
            } else if monitor == nil {
                Self.activePreviews.add(self)
                // AppKit can cancel a native drag without calling dropExited.
                monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .leftMouseUp]) { [weak self] event in
                    self?.handleEndingEvent(event)
                    return event
                }
                if #unavailable(macOS 26.0) {
                    // Older SwiftUI has no drag-session completion callback.
                    // Read button state even when native dragging consumes mouseUp.
                    let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
                        MainActor.assumeIsolated {
                            guard self != nil else { timer.invalidate(); return }
                            if NSEvent.pressedMouseButtons & 1 == 0 { Self.endDrag() }
                        }
                    }
                    releaseTimer = timer
                    RunLoop.main.add(timer, forMode: .common)
                    RunLoop.main.add(timer, forMode: .eventTracking)
                }
            }
        }
    }
    private var monitor: Any?
    private var releaseTimer: Timer?

    static func endDrag() {
        for preview in activePreviews.allObjects { preview.reset() }
    }

    func handleEndingEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown || event.type == .leftMouseUp || (event.type == .keyDown && event.keyCode == 53) {
            Self.endDrag()
        }
    }

    func reset() {
        edge = nil
    }
}

struct PaneDragLifecycle: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.onDragSessionUpdated { session in
                if case .ended = session.phase { PaneDropState.endDrag() }
            }
        } else {
            content
        }
    }
}


struct PaneDockDropDelegate: DropDelegate {
    let paneID: String
    let size: CGSize
    let visible: Bool
    let store: SessionStore
    let state: PaneDropState

    func validateDrop(info: DropInfo) -> Bool {
        visible && store.paneDragPayload(for: paneID) != nil
            && info.hasItemsConforming(to: [.herdrPane])
    }

    func dropEntered(info: DropInfo) {
        updatePreview(location: info.location, hasPaneItems: info.hasItemsConforming(to: [.herdrPane]))
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        updatePreview(location: info.location, hasPaneItems: info.hasItemsConforming(to: [.herdrPane]))
        return DropProposal(operation: state.edge != nil ? .move : .cancel)
    }

    func dropExited(info: DropInfo) { state.reset() }

    func performDrop(info: DropInfo) -> Bool {
        PaneDropState.endDrag()
        let providers = info.itemProviders(for: [.herdrPane])
        guard validateDrop(info: info), let edge = PaneDockEdge.at(info.location, in: size),
              providers.count == 1, let provider = providers.first else { return false }
        // macOS permits access to provider contents only during performDrop.
        // The hover preview uses type metadata and pointer geometry instead.
        _ = provider.loadTransferable(type: PaneDragPayload.self) { result in
            Task { @MainActor in
                guard case .success(let source) = result else { return }
                store.movePane(source, to: paneID, edge: edge)
            }
        }
        return true
    }

    func updatePreview(location: CGPoint, hasPaneItems: Bool) {
        if visible, hasPaneItems, store.paneDragPayload(for: paneID) != nil {
            state.edge = PaneDockEdge.at(location, in: size)
        } else { state.edge = nil }
    }
}
