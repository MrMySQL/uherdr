import SwiftUI
import HerdrCore

let herdrAccentColor = Color(red: 0.34, green: 0.73, blue: 0.58)

struct WorkspaceView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var devices: DeviceStore
    @State private var sidebarVisibility: NavigationSplitViewVisibility = .all
    var body: some View {
        NavigationSplitView(columnVisibility: $sidebarVisibility) {
            DeviceSidebarView(devices: devices)
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 360)
                .toolbar(removing: .sidebarToggle)
        } detail: {
            VStack(spacing: 0) {
                if store.connected {
                    if store.currentSpace != nil {
                        tabStrip
                        Divider()
                        terminalDeck
                            .id(store.connectionGeneration)
                            .padding(8)
                    } else {
                        emptySpaces
                    }
                } else {
                    connectionView
                }
                Divider()
                statusBar
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .navigationTitle("\(store.profile.name) — \(store.currentSpace?.label ?? "Herdr")")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    HStack(spacing: 2) {
                        if store.busy { ProgressView().controlSize(.mini) }
                        compactToolbarButton("Start agent", systemImage: "sparkles") {
                            store.sheet = .agent(store.selectedPane ?? "")
                        }
                        .help("Start a coding agent in the selected pane")
                        compactToolbarButton("Split side by side", systemImage: "rectangle.split.2x1") {
                            store.split(.right)
                        }
                        .help("Split side by side (⌘D)")
                        compactToolbarButton("Split top and bottom", systemImage: "rectangle.split.1x2") {
                            store.split(.down)
                        }
                        .help("Split top and bottom (⇧⌘D)")
                    }
                    .disabled(store.selectedPane == nil || !store.connected || store.busy)
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                compactToolbarButton("Toggle sidebar", systemImage: "sidebar.left") {
                    withAnimation {
                        sidebarVisibility = sidebarVisibility == .detailOnly ? .all : .detailOnly
                    }
                }
                .help("Show or hide sidebar")
            }
        }
        .tint(herdrAccentColor)
        .accentColor(herdrAccentColor)
        .frame(minWidth: 840, minHeight: 520)
        .preferredColorScheme(store.colorScheme)
        .sheet(item: $store.sheet) { sheet in EditorSheet(sheet: sheet, store: store) }
        .sheet(item: $devices.editor) { target in DeviceEditorSheet(target: target, devices: devices) }
        .alert("Remove device?", isPresented: Binding(get: { devices.pendingRemoval != nil }, set: { if !$0 { devices.pendingRemoval = nil } })) {
            Button("Cancel", role: .cancel) { devices.pendingRemoval = nil }
            Button("Remove", role: .destructive) {
                if let id = devices.pendingRemoval { devices.remove(id) }
                devices.pendingRemoval = nil
            }
        } message: { Text("This removes the saved connection. Workspaces and running processes on the device are kept.") }
        .alert("Couldn’t complete the action", isPresented: Binding(get: { store.operationError != nil }, set: { if !$0 { store.operationError = nil } })) {
            Button("OK") { store.operationError = nil }
        } message: { Text(store.operationError ?? "") }
        .alert("Close \(store.pendingClose?.singular ?? "resource")?", isPresented: Binding(get: { store.pendingClose != nil }, set: { if !$0 { store.pendingClose = nil } })) {
            Button("Cancel", role: .cancel) { store.pendingClose = nil }
            Button("Close \(store.pendingClose?.singular ?? "resource")", role: .destructive) {
                if let target = store.pendingClose { store.close(target) }
                store.pendingClose = nil
            }
        } message: {
            Text("Closing “\(store.pendingClose?.label ?? "")” terminates its terminals and running agents. You can quit Herdr instead to keep them running.")
        }
        .background(WindowAccessor())
        .task { devices.start() }
    }

    private var terminalDeck: some View {
        ZStack {
            TerminalTabDeck(store: store)
            if store.currentLayout == nil {
                ProgressView("Loading terminals…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func compactToolbarButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    private var tabStrip: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(store.visibleTabs) { tab in
                        Button { store.selectTab(tab) } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "terminal").font(.system(size: 10))
                                Text(tab.label).lineLimit(1)
                                if tab.agentStatus != .unknown && tab.agentStatus != .idle { StatusDot(status: tab.agentStatus) }
                                Text("\(tab.paneCount)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                            }
                            .font(.system(size: 11, weight: store.selectedTab == tab.id ? .semibold : .regular))
                            .padding(.horizontal, 10).frame(height: 26)
                            .contentShape(Rectangle())
                            .background(store.selectedTab == tab.id ? Color.primary.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                            .overlay(alignment: .bottom) { if store.selectedTab == tab.id { Capsule().fill(herdrAccentColor).frame(height: 2).padding(.horizontal, 12) } }
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Rename tab…") { store.sheet = .rename(ResourceTarget(kind: "tab", id: tab.id, label: tab.label)) }
                            Button("Close tab…", role: .destructive) { store.pendingClose = ResourceTarget(kind: "tab", id: tab.id, label: tab.label) }
                        }
                    }
                    Button { store.sheet = .tab } label: { Image(systemName: "plus").font(.system(size: 11)).frame(width: 26, height: 26) }
                        .buttonStyle(.plain).help("New tab (⌘T)").disabled(store.busy)
                }.padding(.horizontal, 6).padding(.vertical, 3)
            }
            Text("\(store.visiblePanes.count) \(store.visiblePanes.count == 1 ? "pane" : "panes")")
                .font(.system(size: 11)).foregroundStyle(.tertiary).padding(.horizontal, 14)
        }.frame(height: 32)
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            Circle().fill(store.connected ? herdrAccentColor : Color.orange).frame(width: 6, height: 6)
            Text(store.profile.name)
            Text(store.connected ? "Connected to herdr \(store.version)" : store.connecting ? "Connecting…" : "Disconnected")
            Spacer()
            if store.connected {
                Text("\(store.agents.count) agents")
                Text("·")
                Text("\(store.workspaces.count) spaces")
            }
            Button { store.sheet = .settings } label: { Image(systemName: "slider.horizontal.3") }
                .buttonStyle(.plain).help("Connection and appearance settings")
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14).padding(.vertical, 7)
    }

    private var emptySpaces: some View {
        VStack(spacing: 18) {
            Image(systemName: "square.stack.3d.up").font(.system(size: 42, weight: .ultraLight)).foregroundStyle(herdrAccentColor)
            Text("Room for your next idea").font(.system(size: 24, weight: .medium))
            Text("Create a space for a project, then add terminals and agents.").foregroundStyle(.secondary)
            Button("Create a space…") { store.sheet = .space }.buttonStyle(.borderedProminent)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var connectionView: some View {
        VStack(spacing: 18) {
            Image(systemName: "square.split.2x2").font(.system(size: 50, weight: .ultraLight)).foregroundStyle(herdrAccentColor)
            Text(store.profile.name).font(.system(size: 26, weight: .medium))
            Text(store.isRemote ? "Connect over SSH to see this device’s workspaces." : "Connect to herdr on this Mac to see your workspaces.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let error = store.connectionError {
                Text(error).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    .textSelection(.enabled).multilineTextAlignment(.center).frame(maxWidth: 460)
                    .padding(12).background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
            }
            HStack {
                Button("Edit device…") { devices.editor = DeviceEditorTarget(profile: store.profile) }
                Button(store.connecting ? "Connecting…" : "Connect") { store.reconnect() }.disabled(store.connecting)
                if !store.isRemote {
                    Button("Start server") { store.startServer(); store.reconnect() }.buttonStyle(.borderedProminent)
                }
            }
            Text("Your sessions keep running when you close this app.").font(.caption).foregroundStyle(.tertiary)
        }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}


struct StatusDot: View {
    let status: AgentStatus
    var body: some View { Circle().fill(status.color).frame(width: 6, height: 6).accessibilityLabel(status.label) }
}
struct StatusBadge: View {
    let status: AgentStatus
    var body: some View {
        HStack(spacing: 5) { StatusDot(status: status); Text(status.label) }
            .font(.system(size: 10, weight: .medium)).foregroundStyle(status.color)
    }
}
extension AgentStatus {
    var color: Color {
        switch self { case .working: return .cyan; case .blocked: return .orange; case .done: return herdrAccentColor; case .idle: return .secondary; case .unknown: return .secondary }
    }
}

struct WindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.setFrameAutosaveName("HerdrMainWindow")
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
