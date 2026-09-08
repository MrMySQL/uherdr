import SwiftUI
import HerdrCore

struct SplitTree: View {
    let node: LayoutNode
    let tabID: String
    let path: [Bool]
    @ObservedObject var store: SessionStore
    var zoomedPaneID: String? = nil
    var body: some View {
        content
    }
    private var content: AnyView {
        switch node {
        case .pane(let id):
            if let pane = store.panes.first(where: { $0.id == id }) {
                return AnyView(PaneCard(pane: pane, store: store, zoomed: zoomedPaneID == id,
                                        visible: zoomedPaneID == nil || zoomedPaneID == id).id(pane.terminalID))
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
                SplitTree(node: first, tabID: tabID, path: path + [false], store: store, zoomedPaneID: zoomedPaneID)
            } second: {
                SplitTree(node: second, tabID: tabID, path: path + [true], store: store, zoomedPaneID: zoomedPaneID)
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
    @ObservedObject var store: SessionStore
    let zoomed: Bool
    var visible = true
    @StateObject private var controller = TerminalController()
    @Environment(\.colorScheme) private var colorScheme
    private var selected: Bool { store.selectedPane == pane.id }
    private var target: ResourceTarget { ResourceTarget(kind: "pane", id: pane.id, label: pane.displayTitle) }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: pane.agent == nil ? "terminal" : "sparkles")
                    .font(.system(size: 10)).foregroundStyle(selected ? Color.accentColor : .secondary)
                Text(pane.displayTitle).font(.system(size: 11, weight: .medium)).lineLimit(1)
                if pane.agent != nil { StatusBadge(status: pane.agentStatus) }
                Spacer(minLength: 4)
                Button { store.zoom(pane.id) } label: { Image(systemName: zoomed ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") }
                    .buttonStyle(.plain).help(zoomed ? "Restore split layout" : "Zoom pane")
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
            }
            .foregroundStyle(.secondary).font(.system(size: 10))
            .padding(.horizontal, 11).frame(height: 33)
            .background(selected ? Color.accentColor.opacity(0.075) : Color.primary.opacity(0.025))
            .contentShape(Rectangle()).onTapGesture { store.focusPane(pane.id) }
            Divider().opacity(0.6)
            ZStack {
                TerminalSurface(controller: controller, pane: pane, store: store, dark: colorScheme == .dark, visible: visible)
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
            if !pane.directory.isEmpty {
                HStack(spacing: 5) {
                    Image(systemName: "folder").font(.system(size: 8))
                    Text(pane.directory.replacingOccurrences(of: NSHomeDirectory(), with: "~")).lineLimit(1).truncationMode(.head)
                    Spacer()
                    Text(pane.id).foregroundStyle(.tertiary)
                }.font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                    .padding(.horizontal, 10).frame(height: 22).background(.primary.opacity(0.02))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? Color.accentColor.opacity(0.5) : Color.primary.opacity(0.1), lineWidth: 1) }
    }
}
