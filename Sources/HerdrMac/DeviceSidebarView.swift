import SwiftUI
import HerdrCore

struct DeviceSidebarView: View {
    @ObservedObject var devices: DeviceStore
    @State private var search = ""
    @State private var collapsed: Set<String> = []
    @ObservedObject private var shortcuts = ShortcutSettings.shared
    let showShortcutHints: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "square.split.2x2.fill").foregroundStyle(Color.accentColor)
                Text("uHerdr").font(.system(size: 25, weight: .semibold, design: .rounded))
                Spacer()
                Button { addDevice() } label: { Image(systemName: "plus") }.buttonStyle(.plain).help("Add device")
            }.padding(18)
            Picker("Sidebar", selection: $devices.sidebarMode) {
                Text("Spaces").tag("spaces")
                Text("Agents\(devices.attentionCount > 0 ? " · \(devices.attentionCount)" : "")").tag("agents")
            }.pickerStyle(.segmented).labelsHidden().padding(.horizontal, 12)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
                TextField("Find a device, space, or agent", text: $search).textFieldStyle(.plain)
            }.font(.system(size: 11)).padding(9).background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 6)).padding(12)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(devices.machineGroups) { machine in
                        machineGroup(machine)
                    }
                }.padding(.horizontal, 10).padding(.bottom, 12)
            }
            Divider()
            HStack {
                Button { devices.activeSession.sheet = .space } label: { Label("New space", systemImage: "plus") }
                    .disabled(!devices.activeSession.connected || devices.activeSession.busy)
                Spacer()
                Menu("Add device") {
                    Button("SSH device…") { addDevice() }
                    Button("Discover sessions on this Mac") { Task { await devices.discoverSessions(includeDismissed: true) } }
                }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }.font(.system(size: 11)).buttonStyle(.plain).padding(12)
        }
    }

    private func addDevice() {
        devices.editor = DeviceEditorTarget(profile: DeviceProfile(name: "", executable: devices.activeSession.executable), isNew: true)
    }

    private var filter: SidebarSearch { SidebarSearch(text: search, mode: devices.sidebarMode) }

    private func isCollapsed(_ key: String) -> Bool { search.isEmpty && collapsed.contains(key) }
    private func toggle(_ key: String) {
        if collapsed.contains(key) { collapsed.remove(key) } else { collapsed.insert(key) }
    }
    private func chevron(_ key: String) -> some View {
        Button { toggle(key) } label: {
            Image(systemName: isCollapsed(key) ? "chevron.right" : "chevron.down").frame(width: 12)
        }.buttonStyle(.plain).help("Expand or collapse")
    }

    @ViewBuilder private func machineGroup(_ machine: MachineGroup) -> some View {
        let machineMatches = filter.machineMatches(machine)
        let sessions = machine.sessions.filter { filter.shows($0, machineMatches: machineMatches) }
        if !sessions.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    chevron(machine.id)
                    Image(systemName: machine.isRemote ? "desktopcomputer" : "laptopcomputer")
                    if let power = machine.powerStatus { DevicePowerIndicator(status: power) }
                    Text(machine.name).fontWeight(.semibold).lineLimit(1)
                    Spacer(minLength: 0)
                    machineMenu(machine)
                }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 8).padding(.vertical, 4)
                if !isCollapsed(machine.id) {
                    ForEach(sessions, id: \.profile.id) { session in
                        sessionSection(session, machineMatches: machineMatches)
                    }
                }
            }
        }
    }

    @ViewBuilder private func sessionSection(_ session: SessionStore, machineMatches: Bool) -> some View {
        let key = session.profile.id.uuidString
        let spaces = filter.spaces(session, machineMatches: machineMatches)
        let agents = filter.agents(session, machineMatches: machineMatches)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                chevron(key)
                Button { devices.select(session) } label: {
                    HStack(spacing: 6) {
                        Circle().fill(session.connected ? Color.accentColor : session.connecting ? .orange : .secondary).frame(width: 6, height: 6)
                        Text(session.profile.sessionName).fontWeight(.semibold).lineLimit(1)
                        Spacer(minLength: 0)
                        if session.attentionCount > 0 {
                            Text("\(session.attentionCount)").font(.system(size: 10, weight: .semibold)).monospacedDigit()
                                .foregroundStyle(Color.accentColor).help("Agents waiting for you")
                        }
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
                sessionMenu(session)
            }.font(.system(size: 11)).padding(8).padding(.leading, 12)
                .background(devices.selectedDeviceID == session.profile.id ? Color.primary.opacity(0.045) : .clear, in: RoundedRectangle(cornerRadius: 6))
            if !isCollapsed(key) {
                if !session.connected {
                    Button { devices.select(session) } label: {
                        Text(session.suspended ? "Disconnected" : session.connecting ? "Connecting…" : "Connection unavailable")
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 36).padding(.vertical, 4)
                    }.buttonStyle(.plain).help(session.connectionError ?? "Select to manage connection")
                }
                if devices.sidebarMode == "spaces" {
                    ForEach(spaces) { space in spaceRow(space, session: session) }
                    if spaces.isEmpty && session.connected {
                        Text("No spaces yet").font(.caption).foregroundStyle(.tertiary).padding(.leading, 36)
                    }
                } else {
                    ForEach(agents) { agent in agentRow(agent, session: session) }
                    if agents.isEmpty && session.connected {
                        Text("No agents yet").font(.caption).foregroundStyle(.tertiary).padding(.leading, 36)
                    }
                }
            }
        }
    }

    private func machineMenu(_ machine: MachineGroup) -> some View {
        Menu {
            if machine.isRemote, let first = machine.sessions.first {
                Button("Edit SSH connection…") { devices.editor = DeviceEditorTarget(profile: first.profile, machineID: machine.id) }
                Divider()
                Button("Reconnect all sessions") { devices.reconnectAll(machine.id) }
                Button("Disconnect all sessions") { devices.disconnectAll(machine.id) }
                    .disabled(machine.sessions.allSatisfy(\.suspended))
                if devices.canRemoveMachine(machine.id) {
                    Divider()
                    Button("Remove machine…", role: .destructive) { devices.pendingMachineRemoval = machine.id }
                }
            } else {
                Button("Discover sessions on this Mac") { Task { await devices.discoverSessions(includeDismissed: true) } }
                Menu("Start session") {
                    ForEach(devices.stoppedHerdrSessions, id: \.socketPath) { entry in
                        Button(entry.name) { Task { await devices.startHerdrSession(entry) } }
                    }
                }.disabled(devices.stoppedHerdrSessions.isEmpty)
            }
        } label: { Image(systemName: "ellipsis") }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Machine actions")
    }

    private func sessionMenu(_ session: SessionStore) -> some View {
        let herdrSession = devices.herdrSession(for: session)
        return Menu {
            Button("Reconnect") { session.reconnect() }
            Button("Disconnect") { session.disconnect() }.disabled(session.suspended)
            if let herdrSession {
                if herdrSession.running {
                    Button("Restart session…") { devices.pendingSessionAction = .restart(session.profile.id) }
                    Button("Stop session…") { devices.pendingSessionAction = .stop(session.profile.id) }
                } else {
                    Button("Start session") { Task { await devices.startServer(for: session) } }
                }
            }
            Button("Edit socket…") { devices.editor = DeviceEditorTarget(profile: session.profile) }
            if devices.canRemoveHerdrSession(session) {
                Divider()
                Button("Remove session…", role: .destructive) { devices.pendingSessionAction = .remove(session.profile.id) }
            } else if devices.sessions.count > 1 {
                Divider()
                Button("Remove from list…", role: .destructive) { devices.pendingRemoval = session.profile.id }
            }
        } label: { Image(systemName: "ellipsis") }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Session actions")
    }

    private func spaceRow(_ space: Workspace, session: SessionStore) -> some View {
        let selected = devices.selectedDeviceID == session.profile.id && session.selectedSpace == space.id
        let shortcut = devices.workspaceShortcuts.firstIndex { $0.session === session && $0.workspace.id == space.id }
        return Button { devices.select(session, workspace: space) } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: selected ? "folder.fill" : "folder").foregroundStyle(selected ? Color.accentColor : .secondary)
                    Text(space.label).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Spacer(minLength: 0)
                    if space.agentStatus == .working || space.agentStatus == .blocked || space.agentStatus == .done { StatusDot(status: space.agentStatus) }
                    if let shortcut, let chord = shortcuts.bindings.chord(for: .selectSpace) {
                        Text(KeyChord.modifierGlyphs(chord.modifiers) + "\(shortcut + 1)").font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Color.accentColor).opacity(showShortcutHints ? 1 : 0)
                            .accessibilityHidden(!showShortcutHints)
                    }
                }
                Text("\(space.tabCount) tabs · \(space.paneCount) panes").font(.system(size: 10)).foregroundStyle(.secondary)
            }.padding(.horizontal, 8).padding(.vertical, 7).padding(.leading, 28)
                .contentShape(Rectangle())
                .background(selected ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 7))
        }.buttonStyle(.plain).disabled(!session.connected)
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

    private func agentRow(_ agent: Agent, session: SessionStore) -> some View {
        Button { devices.select(session); session.revealAgent(agent) } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    AgentIconView(agent: agent.agent, size: 14)
                    Text(agent.displayName).lineLimit(1)
                    Spacer(minLength: 0)
                }.font(.system(size: 12, weight: .medium))
                HStack {
                    Text(session.workspaces.first { $0.id == agent.workspaceID }?.label ?? "Space").lineLimit(1)
                    Spacer(minLength: 0)
                    StatusBadge(status: agent.agentStatus)
                }.font(.system(size: 10)).foregroundStyle(.secondary)
            }.padding(8).padding(.leading, 28).contentShape(Rectangle())
                .background(devices.selectedDeviceID == session.profile.id && session.selectedPane == agent.paneID ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 7))
        }.buttonStyle(.plain).disabled(!session.connected)
    }
}

/// A compact outline leaves enough room for a three-digit battery level.
struct DevicePowerIndicator: View {
    let status: DevicePowerStatus

    var body: some View {
        Group {
            switch status {
            case let .battery(percentage, external):
                HStack(spacing: 3) {
                    HStack(spacing: 1) {
                        Text("\(percentage)")
                            .font(.system(size: 8, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .frame(width: 22, height: 13)
                            .overlay(RoundedRectangle(cornerRadius: 2).stroke(lineWidth: 1))
                        RoundedRectangle(cornerRadius: 1).frame(width: 2, height: 5)
                    }
                    if external { Image(systemName: "bolt.fill").font(.system(size: 8)) }
                }
                .foregroundStyle(!external && percentage <= 20 ? Color.red : .secondary)
            case .mains:
                Image(systemName: "powerplug.fill").foregroundStyle(.secondary)
            }
        }
        .fixedSize()
        .help(description)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(description)
    }

    private var description: String {
        switch status {
        case let .battery(percentage, external):
            return "Battery: \(percentage)% · \(external ? "Connected to power" : "On battery")"
        case .mains:
            return "Connected to power · No internal battery"
        }
    }
}
