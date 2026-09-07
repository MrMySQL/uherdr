import SwiftUI
import HerdrCore

private let mint = Color(red: 0.34, green: 0.73, blue: 0.58)

struct WorkspaceView: View {
    @ObservedObject var store: SessionStore
    @State private var sidebarVisibility: NavigationSplitViewVisibility = .all
    var body: some View {
        NavigationSplitView(columnVisibility: $sidebarVisibility) {
            SidebarView(store: store)
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 360)
        } detail: {
            VStack(spacing: 0) {
                if store.connected {
                    if store.currentSpace != nil {
                        tabStrip
                        Divider()
                        if let layout = store.currentLayout, let tabID = store.selectedTab {
                            Group {
                                if layout.zoomed, let id = layout.focusedPaneID, let pane = store.panes.first(where: { $0.id == id }) {
                                    PaneCard(pane: pane, store: store, zoomed: true).id(pane.terminalID)
                                } else {
                                    SplitTree(node: layout.root, tabID: tabID, path: [], store: store)
                                }
                            }
                            .id(store.connectionGeneration)
                            .padding(8)
                        } else {
                            Spacer()
                            ProgressView("Loading terminals…")
                            Spacer()
                        }
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
            .navigationTitle(store.currentSpace?.label ?? "Herdr")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    if store.busy { ProgressView().controlSize(.small) }
                    Button { store.sheet = .agent(store.selectedPane ?? "") } label: { Label("Start agent", systemImage: "sparkles") }
                        .disabled(store.selectedPane == nil || !store.connected || store.busy)
                        .help("Start a coding agent in the selected pane")
                    Divider()
                    Button { store.split(.right) } label: { Label("Split side by side", systemImage: "rectangle.split.2x1") }
                        .disabled(store.selectedPane == nil || !store.connected || store.busy)
                        .help("Split side by side (⌘D)")
                    Button { store.split(.down) } label: { Label("Split top and bottom", systemImage: "rectangle.split.1x2") }
                        .disabled(store.selectedPane == nil || !store.connected || store.busy)
                        .help("Split top and bottom (⇧⌘D)")
                }
            }
        }
        .tint(mint)
        .accentColor(mint)
        .frame(minWidth: 840, minHeight: 520)
        .preferredColorScheme(store.colorScheme)
        .sheet(item: $store.sheet) { sheet in EditorSheet(sheet: sheet, store: store) }
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
        .task { store.start() }
    }

    private var tabStrip: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(store.visibleTabs) { tab in
                        Button { store.selectTab(tab) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "terminal").font(.system(size: 11))
                                Text(tab.label).lineLimit(1)
                                if tab.agentStatus != .unknown && tab.agentStatus != .idle { StatusDot(status: tab.agentStatus) }
                                Text("\(tab.paneCount)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                            }
                            .font(.system(size: 12, weight: store.selectedTab == tab.id ? .semibold : .regular))
                            .padding(.horizontal, 13).padding(.vertical, 9)
                            .background(store.selectedTab == tab.id ? Color.primary.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                            .overlay(alignment: .bottom) { if store.selectedTab == tab.id { Capsule().fill(mint).frame(height: 2).padding(.horizontal, 12) } }
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Rename tab…") { store.sheet = .rename(ResourceTarget(kind: "tab", id: tab.id, label: tab.label)) }
                            Button("Close tab…", role: .destructive) { store.pendingClose = ResourceTarget(kind: "tab", id: tab.id, label: tab.label) }
                        }
                    }
                    Button { store.sheet = .tab } label: { Image(systemName: "plus").frame(width: 30, height: 30) }
                        .buttonStyle(.plain).help("New tab (⌘T)").disabled(store.busy)
                }.padding(6)
            }
            Text("\(store.visiblePanes.count) \(store.visiblePanes.count == 1 ? "pane" : "panes")")
                .font(.system(size: 11)).foregroundStyle(.tertiary).padding(.horizontal, 14)
        }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            Circle().fill(store.connected ? mint : Color.orange).frame(width: 6, height: 6)
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
            Image(systemName: "square.stack.3d.up").font(.system(size: 42, weight: .ultraLight)).foregroundStyle(mint)
            Text("Room for your next idea").font(.system(size: 24, weight: .medium))
            Text("Create a space for a project, then add terminals and agents.").foregroundStyle(.secondary)
            Button("Create a space…") { store.sheet = .space }.buttonStyle(.borderedProminent)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var connectionView: some View {
        VStack(spacing: 18) {
            Image(systemName: "square.split.2x2").font(.system(size: 50, weight: .ultraLight)).foregroundStyle(mint)
            Text("Your agents. One workspace.").font(.system(size: 26, weight: .medium))
            Text("Connect to herdr to bring your spaces, tabs, and terminals together.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let error = store.connectionError {
                Text(error).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    .textSelection(.enabled).multilineTextAlignment(.center).frame(maxWidth: 460)
                    .padding(12).background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
            }
            HStack {
                Button("Connection settings…") { store.sheet = .settings }
                Button("Start server") { store.startServer() }.buttonStyle(.borderedProminent)
            }
            Text("Your sessions keep running when you close this app.").font(.caption).foregroundStyle(.tertiary)
        }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct SidebarView: View {
    @ObservedObject var store: SessionStore
    @State private var search = ""
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "square.split.2x2.fill").foregroundStyle(mint).font(.system(size: 24))
                Text("herdr").font(.system(size: 25, weight: .semibold, design: .rounded))
                Spacer()
                Text("NATIVE").font(.system(size: 8, weight: .bold, design: .monospaced)).tracking(1.4).foregroundStyle(.tertiary)
            }.padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 20)
            Picker("Sidebar", selection: $store.sidebarMode) {
                Text("Spaces").tag("spaces")
                Text("Agents\(store.attentionCount > 0 ? " · \(store.attentionCount)" : "")").tag("agents")
            }.pickerStyle(.segmented).labelsHidden().padding(.horizontal, 12)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
                TextField(store.sidebarMode == "spaces" ? "Find a space" : "Find an agent", text: $search).textFieldStyle(.plain)
            }.font(.system(size: 11)).padding(9).background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 6)).padding(12)
            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    if store.sidebarMode == "spaces" {
                        Text("YOUR SPACES").font(.system(size: 9, weight: .semibold)).tracking(1.5).foregroundStyle(.tertiary).padding(.horizontal, 10).padding(.bottom, 6)
                        ForEach(store.workspaces.filter { search.isEmpty || $0.label.localizedCaseInsensitiveContains(search) }) { space in
                            spaceRow(space)
                        }
                        if store.workspaces.isEmpty { Text("Your spaces will appear here.").font(.caption).foregroundStyle(.tertiary).padding(10) }
                    } else {
                        Text("AGENT ACTIVITY").font(.system(size: 9, weight: .semibold)).tracking(1.5).foregroundStyle(.tertiary).padding(.horizontal, 10).padding(.bottom, 6)
                        ForEach(store.agents.filter { search.isEmpty || $0.displayName.localizedCaseInsensitiveContains(search) }) { agent in
                            Button { store.revealAgent(agent) } label: {
                                HStack(alignment: .top, spacing: 10) {
                                    Image(systemName: "sparkles").foregroundStyle(mint).frame(width: 20)
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(agent.displayName).font(.system(size: 12, weight: .semibold))
                                        Text(store.workspaces.first { $0.id == agent.workspaceID }?.label ?? "Space").font(.caption).foregroundStyle(.secondary)
                                        StatusBadge(status: agent.agentStatus)
                                    }
                                    Spacer(minLength: 0)
                                }.padding(11).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(store.selectedPane == agent.paneID ? mint.opacity(0.12) : Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 8))
                            }.buttonStyle(.plain)
                        }
                        if store.agents.isEmpty {
                            VStack(alignment: .leading, spacing: 7) {
                                Text("No agents yet").font(.system(size: 12, weight: .medium))
                                Text("Start an agent in a terminal. Its activity will appear here automatically.").font(.caption).foregroundStyle(.secondary)
                            }.padding(10)
                        }
                    }
                }.padding(.horizontal, 10)
            }
            Spacer(minLength: 8)
            Divider()
            Button { store.sheet = .space } label: {
                HStack { Image(systemName: "plus"); Text("New space"); Spacer(); Text("⌘N").foregroundStyle(.tertiary) }
                    .font(.system(size: 12)).padding(15)
            }.buttonStyle(.plain).disabled(!store.connected || store.busy)
        }
    }

    private func spaceRow(_ space: Workspace) -> some View {
        let selected = store.selectedSpace == space.id
        let spaceAgents = store.agents.filter { $0.workspaceID == space.id }
        return Button { store.selectSpace(space) } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: selected ? "folder.fill" : "folder").foregroundStyle(selected ? mint : .secondary)
                    Text(space.label).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Spacer(minLength: 0)
                    if space.agentStatus == .working || space.agentStatus == .blocked || space.agentStatus == .done { StatusDot(status: space.agentStatus) }
                }
                HStack(spacing: 6) {
                    Text("\(space.tabCount) tabs")
                    Text("·")
                    Text("\(space.paneCount) panes")
                    Spacer()
                    if !spaceAgents.isEmpty { Image(systemName: "sparkles"); Text("\(spaceAgents.count)") }
                }.font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? mint.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? mint.opacity(0.25) : Color.clear) }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Rename space…") { store.sheet = .rename(ResourceTarget(kind: "workspace", id: space.id, label: space.label)) }
            Button("Close space…", role: .destructive) { store.pendingClose = ResourceTarget(kind: "workspace", id: space.id, label: space.label) }
        }
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
        switch self { case .working: return .cyan; case .blocked: return .orange; case .done: return mint; case .idle: return .secondary; case .unknown: return .secondary }
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
