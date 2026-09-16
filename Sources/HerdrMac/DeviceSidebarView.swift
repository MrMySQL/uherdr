import SwiftUI
import HerdrCore

struct DeviceSidebarView: View {
    @ObservedObject var devices: DeviceStore
    @Environment(\.resolvedAppearance) private var appearance
    @Environment(\.colorScheme) private var colorScheme
    private var palette: NativePalette { NativePalette(snapshot: appearance, colorScheme: colorScheme) }
    @State private var search = ""
    @State private var collapsed: Set<UUID> = []
    @StateObject private var commandKey = CommandKeyMonitor()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "square.split.2x2.fill").foregroundStyle(palette.color("accent"))
                Text("herdr").font(.system(size: 25, weight: .semibold, design: .rounded))
                Spacer()
                Button { addDevice() } label: { Image(systemName: "plus") }.buttonStyle(.plain).help("Add device")
            }.padding(18)
            Picker("Sidebar", selection: $devices.sidebarMode) {
                Text("Spaces").tag("spaces")
                Text("Agents\(devices.attentionCount > 0 ? " · \(devices.attentionCount)" : "")").tag("agents")
            }.pickerStyle(.segmented).labelsHidden().padding(.horizontal, 12)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(palette.color("secondary_text", fallback: Color(nsColor: .tertiaryLabelColor)))
                TextField("Find a device, space, or agent", text: $search).textFieldStyle(.plain)
            }.font(.system(size: 11)).padding(9).background(palette.color("surface0", fallback: Color.primary.opacity(0.035)), in: RoundedRectangle(cornerRadius: 6)).padding(12)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(devices.sessions, id: \.profile.id) { session in
                        deviceGroup(session)
                    }
                }.padding(.horizontal, 10).padding(.bottom, 12)
            }
            Divider().overlay(palette.color("border", fallback: .clear))
            HStack {
                Button { devices.activeSession.sheet = .space } label: { Label("New space", systemImage: "plus") }
                    .disabled(!devices.activeSession.connected || devices.activeSession.busy)
                Spacer()
                Button("Add device…") { addDevice() }
            }.font(.system(size: 11)).buttonStyle(.plain).padding(12)
        }
        .background(palette.color("sidebar_bg", fallback: .clear))
        .onAppear { commandKey.start() }
        .onDisappear { commandKey.stop() }
    }

    private func addDevice() {
        devices.editor = DeviceEditorTarget(profile: DeviceProfile(name: "", executable: devices.activeSession.executable), isNew: true)
    }

    private func matches(_ text: String) -> Bool { search.isEmpty || text.localizedCaseInsensitiveContains(search) }

    @ViewBuilder private func deviceGroup(_ session: SessionStore) -> some View {
        let deviceMatches = matches(session.profile.name) || (!search.isEmpty && matches(session.profile.host))
        let spaces = session.workspaces.filter { deviceMatches || matches($0.label) }
        let agents = session.agents.filter { agent in
            deviceMatches || matches(agent.displayName) || matches(session.workspaces.first(where: { $0.id == agent.workspaceID })?.label ?? "")
        }
        if deviceMatches || (devices.sidebarMode == "spaces" ? !spaces.isEmpty : !agents.isEmpty) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Button {
                        if collapsed.contains(session.profile.id) { collapsed.remove(session.profile.id) }
                        else { collapsed.insert(session.profile.id) }
                    } label: {
                        Image(systemName: collapsed.contains(session.profile.id) ? "chevron.right" : "chevron.down").frame(width: 12)
                    }.buttonStyle(.plain).help("Expand or collapse device")
                    Button { devices.select(session) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: session.isRemote ? "desktopcomputer" : "laptopcomputer")
                            Text(session.profile.name).fontWeight(.semibold).lineLimit(1)
                            Spacer(minLength: 0)
                            Circle().fill(session.connected ? palette.color("accent") : session.connecting ? palette.color("status_interrupted") : palette.color("secondary_text")).frame(width: 6, height: 6)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    Menu {
                        Button("Edit device…") { devices.editor = DeviceEditorTarget(profile: session.profile) }
                        Button("Reconnect") { session.reconnect() }
                        Button("Disconnect") { session.disconnect() }.disabled(session.suspended)
                        if session.isRemote {
                            Divider().overlay(palette.color("border", fallback: .clear))
                            Button("Remove device…", role: .destructive) { devices.pendingRemoval = session.profile.id }
                        }
                    } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                }.font(.system(size: 11)).padding(8)
                    .background(devices.selectedDeviceID == session.profile.id ? palette.color("active_row", fallback: Color.primary.opacity(0.045)) : .clear, in: RoundedRectangle(cornerRadius: 6))
                if !collapsed.contains(session.profile.id) || !search.isEmpty {
                    if !session.connected {
                        Button { devices.select(session) } label: {
                            Text(session.suspended ? "Disconnected" : session.connecting ? "Connecting…" : "Connection unavailable")
                                .font(.caption).foregroundStyle(palette.color("secondary_text"))
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 24).padding(.vertical, 4)
                        }.buttonStyle(.plain).help(session.connectionError ?? "Select to manage connection")
                    }
                    if devices.sidebarMode == "spaces" {
                        ForEach(spaces) { space in spaceRow(space, session: session) }
                        if spaces.isEmpty && session.connected {
                            Text("No spaces yet").font(.caption).foregroundStyle(palette.color("secondary_text", fallback: Color(nsColor: .tertiaryLabelColor))).padding(.leading, 24)
                        }
                    } else {
                        ForEach(agents) { agent in agentRow(agent, session: session) }
                        if agents.isEmpty && session.connected {
                            Text("No agents yet").font(.caption).foregroundStyle(palette.color("secondary_text", fallback: Color(nsColor: .tertiaryLabelColor))).padding(.leading, 24)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private func spaceRow(_ space: Workspace, session: SessionStore) -> some View {
        let selected = devices.selectedDeviceID == session.profile.id && session.selectedSpace == space.id
        let shortcut = devices.workspaceShortcuts.firstIndex { $0.session === session && $0.workspace.id == space.id }
        let configuredRows = session.spaceSidebarRows[space.id]
        if configuredRows?.isEmpty != true {
            Button { devices.select(session, workspace: space) } label: {
                VStack(alignment: .leading, spacing: 4) {
                    if let rows = configuredRows {
                        HStack {
                            SidebarRowView(rows: rows, rowGap: session.appearanceStore.sidebarConfiguration?.spaces?.rowGap ?? 0)
                            Spacer(minLength: 0)
                            if let shortcut {
                                Text("⌘\(shortcut + 1)").font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(palette.color("accent")).opacity(commandKey.isHeld ? 1 : 0)
                                    .accessibilityHidden(!commandKey.isHeld)
                            }
                        }
                    } else {
                        HStack(spacing: 6) {
                            Image(systemName: selected ? "folder.fill" : "folder").foregroundStyle(selected ? palette.color("accent") : palette.color("secondary_text"))
                            Text(space.label).font(.system(size: 13, weight: .medium)).lineLimit(1)
                            Spacer(minLength: 0)
                            if space.agentStatus == .working || space.agentStatus == .blocked || space.agentStatus == .done { StatusDot(status: space.agentStatus) }
                            if let shortcut {
                                Text("⌘\(shortcut + 1)").font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(palette.color("accent")).opacity(commandKey.isHeld ? 1 : 0)
                                    .accessibilityHidden(!commandKey.isHeld)
                            }
                        }
                        Text("\(space.tabCount) tabs · \(space.paneCount) panes").font(.system(size: 10)).foregroundStyle(palette.color("secondary_text"))
                    }
                }.padding(.horizontal, 8).padding(.vertical, 7).padding(.leading, 16)
                    .contentShape(Rectangle())
                    .background(selected ? palette.color("active_row", fallback: palette.color("accent").opacity(0.12)) : .clear, in: RoundedRectangle(cornerRadius: 7))
            }.buttonStyle(.plain).disabled(!session.connected)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .contextMenu {
                    Button("Rename space…") {
                        devices.select(session)
                        session.sheet = .rename(ResourceTarget(kind: "workspace", id: space.id, label: space.label))
                    }.disabled(!session.connected)
                    Button("Close space…", role: .destructive) {
                        devices.select(session)
                        session.pendingClose = ResourceTarget(kind: "workspace", id: space.id, label: space.label)
                    }.disabled(!session.connected)
                }
        }
    }

    @ViewBuilder private func agentRow(_ agent: Agent, session: SessionStore) -> some View {
        let configuredRows = session.agentSidebarRows[agent.id]
        if configuredRows?.isEmpty != true {
            Button { devices.select(session); session.revealAgent(agent) } label: {
                VStack(alignment: .leading, spacing: 4) {
                    if let rows = configuredRows {
                        SidebarRowView(rows: rows, rowGap: session.appearanceStore.sidebarConfiguration?.agents?.rowGap ?? 0)
                    } else {
                        HStack {
                            Image(systemName: "sparkles").foregroundStyle(palette.color("accent"))
                            Text(agent.displayName).lineLimit(1)
                            Spacer(minLength: 0)
                        }.font(.system(size: 12, weight: .medium))
                        HStack {
                            Text(session.workspaces.first { $0.id == agent.workspaceID }?.label ?? "Space").lineLimit(1)
                            Spacer(minLength: 0)
                            StatusBadge(status: agent.agentStatus)
                        }.font(.system(size: 10)).foregroundStyle(palette.color("secondary_text"))
                    }
                }.padding(8).padding(.leading, 16).contentShape(Rectangle())
                    .background(devices.selectedDeviceID == session.profile.id && session.selectedPane == agent.paneID ? palette.color("active_row", fallback: palette.color("accent").opacity(0.12)) : .clear, in: RoundedRectangle(cornerRadius: 7))
            }.buttonStyle(.plain).disabled(!session.connected)
                .accessibilityAddTraits(devices.selectedDeviceID == session.profile.id && session.selectedPane == agent.paneID ? .isSelected : [])
        }
    }
}
