import SwiftUI
import HerdrCore

@MainActor
final class SessionStore: ObservableObject {
    @Published var workspaces: [Workspace] = []
    @Published var tabs: [HerdrCore.Tab] = []
    @Published var panes: [Pane] = []
    @Published var agents: [Agent] = []
    @Published var layouts: [String: TabLayout] = [:]
    @Published var selectedSpace: String?
    @Published var selectedTab: String?
    @Published var selectedPane: String?
    @Published var connected = false
    @Published var connecting = false
    @Published var busy = false
    @Published var connectionError: String?
    @Published var operationError: String?
    @Published var version = ""
    @Published var sheet: AppSheet?
    @Published var pendingClose: ResourceTarget?
    @Published var connectionGeneration = UUID()
    @Published private(set) var profile: DeviceProfile
    @Published private(set) var effectiveSocketPath: String
    @Published private(set) var remoteHome: String?
    @Published private(set) var suspended = false
    @Published var appearance: String { didSet { defaults.set(appearance, forKey: "appearance") } }
    @Published var fontSize: Double { didSet { defaults.set(fontSize, forKey: "fontSize") } }
    var socketPath: String { profile.socketPath }
    var executable: String { profile.executable }
    var isRemote: Bool { profile.kind == .ssh }
    var defaultDirectory: String { isRemote ? remoteHome ?? "/tmp" : NSHomeDirectory() }
    private let defaults: UserDefaults
    private let tunnel: SSHTunnel
    private var retryAfter = Date.distantPast
    private var client: HerdrClient
    private var pollTask: Task<Void, Never>?
    private var refreshingGeneration: UUID?
    private var serverProcess: Process?
    private var selectionRevision = 0

    init(profile: DeviceProfile, defaults: UserDefaults = .standard, tunnel: SSHTunnel? = nil) {
        self.profile = profile
        self.defaults = defaults
        self.tunnel = tunnel ?? SSHTunnel()
        let socket = profile.kind == .local ? (profile.socketPath as NSString).expandingTildeInPath : ""
        effectiveSocketPath = socket
        appearance = defaults.string(forKey: "appearance") ?? "system"
        fontSize = defaults.object(forKey: "fontSize") as? Double ?? 13
        client = HerdrClient(socketPath: (socket as NSString).expandingTildeInPath)
        selectedSpace = defaults.string(forKey: "selectedSpace:\(profile.id.uuidString)")
        selectedTab = defaults.string(forKey: "selectedTab:\(profile.id.uuidString)")
    }

    static func findExecutable() -> String {
        let candidates = [NSHomeDirectory() + "/.local/bin/herdr", "/opt/homebrew/bin/herdr", "/usr/local/bin/herdr"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/opt/homebrew/bin/herdr"
    }

    var currentSpace: Workspace? { workspaces.first { $0.id == selectedSpace } }
    var currentTab: HerdrCore.Tab? { tabs.first { $0.id == selectedTab } }
    var currentPane: Pane? { panes.first { $0.id == selectedPane } }
    var visibleTabs: [HerdrCore.Tab] { tabs.filter { $0.workspaceID == selectedSpace } }
    var visiblePanes: [Pane] { panes.filter { $0.tabID == selectedTab } }
    var currentLayout: TabLayout? { selectedTab.flatMap { layouts[$0] } }
    var attentionCount: Int { agents.filter { $0.agentStatus == .blocked || $0.agentStatus == .done }.count }
    var colorScheme: ColorScheme? { appearance == "dark" ? .dark : appearance == "light" ? .light : nil }

    func start() {
        guard pollTask == nil, !suspended else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(1.25))
            }
        }
    }

    func reconnect() {
        disconnect()
        suspended = false
        retryAfter = .distantPast
        connectionError = nil
        start()
    }

    func disconnect() {
        pollTask?.cancel(); pollTask = nil
        connectionGeneration = UUID()
        tunnel.stop()
        suspended = true; connected = false; connecting = false; busy = false
        if isRemote { effectiveSocketPath = "" }
    }

    func updateProfile(_ value: DeviceProfile) {
        disconnect()
        profile = value
        workspaces = []; tabs = []; panes = []; agents = []; layouts = [:]
        selectedSpace = nil; selectedTab = nil; selectedPane = nil
        reconnect()
    }

    func refresh() async {
        guard !suspended, refreshingGeneration != connectionGeneration, Date() >= retryAfter else { return }
        let generation = connectionGeneration
        refreshingGeneration = generation
        connecting = !connected
        defer {
            if refreshingGeneration == generation { refreshingGeneration = nil }
            if connectionGeneration == generation { connecting = false }
        }
        let revision = selectionRevision
        do {
            let path: String
            if isRemote {
                path = try await tunnel.connect(profile)
                guard generation == connectionGeneration, !Task.isCancelled else { return }
                remoteHome = tunnel.remoteHome
            } else { path = (socketPath as NSString).expandingTildeInPath }
            if effectiveSocketPath != path || client.socketPath != path {
                effectiveSocketPath = path
                client = HerdrClient(socketPath: path)
            }
            let activeClient = client
            let response = try await activeClient.request("session.snapshot")
            let snapshot = try response["snapshot"].decode(SessionSnapshot.self)
            guard generation == connectionGeneration, !Task.isCancelled else { return }
            version = snapshot.version
            if workspaces != snapshot.workspaces { workspaces = snapshot.workspaces }
            if tabs != snapshot.tabs { tabs = snapshot.tabs }
            if panes != snapshot.panes { panes = snapshot.panes }
            if agents != snapshot.agents { agents = snapshot.agents }
            if revision == selectionRevision {
                if !workspaces.contains(where: { $0.id == selectedSpace }) {
                    selectedSpace = snapshot.focusedWorkspaceID ?? workspaces.first?.id
                }
                if !visibleTabs.contains(where: { $0.id == selectedTab }) {
                    selectedTab = currentSpace?.activeTabID ?? visibleTabs.first?.id
                }
                if !visiblePanes.contains(where: { $0.id == selectedPane }) {
                    selectedPane = visiblePanes.first(where: { $0.id == snapshot.focusedPaneID })?.id ?? visiblePanes.first?.id
                }
            }
            if let tabID = selectedTab {
                let result = try await activeClient.request("layout.export", params: ["tab_id": .string(tabID)])
                let layout = try result["layout"].decode(TabLayout.self)
                guard generation == connectionGeneration, !Task.isCancelled else { return }
                if layouts[tabID] != layout { layouts[tabID] = layout }
                if selectedTab == tabID { selectedPane = layout.resolveSelectedPane(selectedPane) }
            }
            connected = true
            connectionError = nil
            persistSelection()
        } catch {
            guard generation == connectionGeneration, !Task.isCancelled else { return }
            connected = false
            connectionError = error.localizedDescription
            if isRemote { retryAfter = Date().addingTimeInterval(10) }
        }
    }

    func selectSpace(_ space: Workspace) {
        selectionRevision += 1
        selectedSpace = space.id
        selectedTab = space.activeTabID
        selectedPane = layouts[space.activeTabID]?.resolveSelectedPane(nil) ?? panes.first { $0.tabID == space.activeTabID }?.id
        perform("workspace.focus", params: ["workspace_id": .string(space.id)])
        persistSelection()
    }

    func selectTab(_ tab: HerdrCore.Tab) {
        selectionRevision += 1
        selectedSpace = tab.workspaceID
        selectedTab = tab.id
        selectedPane = layouts[tab.id]?.resolveSelectedPane(nil) ?? panes.first { $0.tabID == tab.id }?.id
        perform("tab.focus", params: ["tab_id": .string(tab.id)])
        persistSelection()
    }

    func focusPane(_ id: String) {
        guard selectedPane != id else { return }
        selectedPane = id
        perform("pane.focus", params: ["pane_id": .string(id)], showBusy: false)
    }

    func revealAgent(_ agent: Agent) {
        selectionRevision += 1
        selectedSpace = agent.workspaceID
        selectedTab = agent.tabID
        selectedPane = agent.paneID
        perform("pane.focus", params: ["pane_id": .string(agent.paneID)])
    }

    private func persistSelection() {
        defaults.set(selectedSpace, forKey: "selectedSpace:\(profile.id.uuidString)")
        defaults.set(selectedTab, forKey: "selectedTab:\(profile.id.uuidString)")
    }

    func perform(_ method: String, params: [String: JSONValue], showBusy: Bool = true, completion: ((JSONValue) -> Void)? = nil) {
        guard connected, !suspended else { return }
        let activeClient = client
        let generation = connectionGeneration
        Task {
            guard generation == connectionGeneration, connected, !suspended else { return }
            if showBusy { busy = true }
            defer { if showBusy, generation == connectionGeneration { busy = false } }
            do {
                let result = try await activeClient.request(method, params: params, timeout: method == "agent.start" ? 40 : 8)
                guard generation == connectionGeneration else { return }
                completion?(result)
                await refresh()
            } catch {
                guard generation == connectionGeneration else { return }
                operationError = error.localizedDescription
            }
        }
    }

    func createSpace(label: String, cwd: String) {
        perform("workspace.create", params: ["label": .string(label), "cwd": .string(cwd), "focus": .bool(true)]) { [weak self] result in
            self?.selectionRevision += 1
            self?.selectedSpace = result["workspace"]["workspace_id"].string
            self?.selectedTab = result["tab"]["tab_id"].string
            self?.selectedPane = result["root_pane"]["pane_id"].string
        }
    }

    func createTab(label: String) {
        guard let space = selectedSpace else { return }
        var params: [String: JSONValue] = ["workspace_id": .string(space), "label": .string(label), "focus": .bool(true)]
        if let cwd = currentPane?.directory, !cwd.isEmpty { params["cwd"] = .string(cwd) }
        perform("tab.create", params: params) { [weak self] result in
            self?.selectionRevision += 1
            self?.selectedTab = result["tab"]["tab_id"].string
            self?.selectedPane = result["root_pane"]["pane_id"].string
        }
    }

    func split(_ direction: SplitDirection, paneID: String? = nil) {
        guard let pane = paneID ?? selectedPane else { return }
        perform("pane.split", params: ["target_pane_id": .string(pane), "direction": .string(direction.rawValue), "focus": .bool(true)]) { [weak self] result in
            self?.selectedPane = result["pane"]["pane_id"].string
        }
    }

    func setRatio(tabID: String, path: [Bool], ratio: Double) {
        perform("layout.set_split_ratio", params: ["tab_id": .string(tabID), "path": .array(path.map(JSONValue.bool)), "ratio": .number(min(0.9, max(0.1, ratio)))], showBusy: false)
    }

    func zoom(_ paneID: String) { selectedPane = paneID; perform("pane.zoom", params: ["pane_id": .string(paneID), "mode": .string("toggle")]) }
    func rename(_ target: ResourceTarget, label: String) {
        perform("\(target.kind).rename", params: ["\(target.kind)_id": .string(target.id), "label": .string(label)])
    }
    func close(_ target: ResourceTarget) {
        perform("\(target.kind).close", params: ["\(target.kind)_id": .string(target.id)])
    }
    func startAgent(paneID: String, kind: String, name: String) {
        perform("agent.start", params: ["pane_id": .string(paneID), "kind": .string(kind), "name": .string(name), "timeout_ms": .number(30000)])
    }

    func startServer() {
        guard !isRemote else { return }
        guard serverProcess?.isRunning != true else { return }
        do {
            let path = (socketPath as NSString).expandingTildeInPath
            try FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/nohup")
            process.arguments = [(executable as NSString).expandingTildeInPath, "server"]
            var env = ProcessInfo.processInfo.environment
            env.removeValue(forKey: "HERDR_SESSION")
            env.removeValue(forKey: "HERDR_CLIENT_SOCKET_PATH")
            env["HERDR_SOCKET_PATH"] = path
            process.environment = env
            process.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            serverProcess = process
        } catch { operationError = error.localizedDescription }
    }
}

struct ResourceTarget: Identifiable {
    let kind: String
    let id: String
    let label: String
    var singular: String { kind == "workspace" ? "space" : kind }
}

enum AppSheet: Identifiable {
    case space, tab, rename(ResourceTarget), agent(String), settings
    var id: String {
        switch self {
        case .space: return "space"
        case .tab: return "tab"
        case .rename(let target): return "rename-\(target.id)"
        case .agent(let id): return "agent-\(id)"
        case .settings: return "settings"
        }
    }
}
