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
    @Published var sidebarMode = "spaces"
    @Published var connectionGeneration = UUID()
    @Published var socketPath: String
    @Published var executable: String
    @Published var appearance: String { didSet { UserDefaults.standard.set(appearance, forKey: "appearance") } }
    @Published var fontSize: Double { didSet { UserDefaults.standard.set(fontSize, forKey: "fontSize") } }
    private var client: any HerdrRequesting
    private var pollTask: Task<Void, Never>?
    private var refreshing = false
    private var serverProcess: Process?
    private var selectionRevision = 0

    init(client: (any HerdrRequesting)? = nil) {
        let defaults = UserDefaults.standard
        let env = ProcessInfo.processInfo.environment
        let configHome = env["XDG_CONFIG_HOME"] ?? NSHomeDirectory() + "/.config"
        let socket = env["HERDR_SOCKET_PATH"] ?? defaults.string(forKey: "socketPath") ?? configHome + "/herdr/herdr.sock"
        socketPath = socket
        executable = defaults.string(forKey: "herdrExecutable") ?? Self.findExecutable()
        appearance = defaults.string(forKey: "appearance") ?? "system"
        fontSize = defaults.object(forKey: "fontSize") as? Double ?? 13
        self.client = client ?? HerdrClient(socketPath: (socket as NSString).expandingTildeInPath)
        selectedSpace = defaults.string(forKey: "selectedSpace:\(socket)")
        selectedTab = defaults.string(forKey: "selectedTab:\(socket)")
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
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(1.25))
            }
        }
    }

    func reconnect() {
        pollTask?.cancel()
        pollTask = nil
        connectionGeneration = UUID()
        client = HerdrClient(socketPath: (socketPath as NSString).expandingTildeInPath)
        UserDefaults.standard.set(socketPath, forKey: "socketPath")
        UserDefaults.standard.set(executable, forKey: "herdrExecutable")
        workspaces = []; tabs = []; panes = []; agents = []; layouts = [:]
        selectedSpace = nil; selectedTab = nil; selectedPane = nil
        connected = false
        start()
    }

    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        connecting = !connected
        defer { refreshing = false; connecting = false }
        let generation = connectionGeneration
        let revision = selectionRevision
        let activeClient = client
        do {
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
        UserDefaults.standard.set(selectedSpace, forKey: "selectedSpace:\(socketPath)")
        UserDefaults.standard.set(selectedTab, forKey: "selectedTab:\(socketPath)")
    }

    func perform(_ method: String, params: [String: JSONValue], showBusy: Bool = true, completion: ((JSONValue) -> Void)? = nil) {
        let activeClient = client
        let generation = connectionGeneration
        Task {
            if showBusy { busy = true }
            defer { if showBusy { busy = false } }
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
        guard !busy else { return }
        guard let pane = panes.first(where: { $0.id == paneID }), pane.directory.hasPrefix("/") else {
            operationError = "Could not find the pane’s project folder. Refresh and try again."
            return
        }
        let activeClient = client
        let generation = connectionGeneration
        let directory = pane.directory
        busy = true
        operationError = nil
        Task {
            defer { busy = false }
            var createdWorktree = false
            do {
                let created = try await activeClient.request("worktree.create", params: [
                    "cwd": .string(directory), "label": .string(name), "focus": .bool(true)
                ], timeout: 60)
                guard generation == connectionGeneration else { return }
                createdWorktree = true
                let rootPane = try created["root_pane"].decode(Pane.self)
                selectionRevision += 1
                selectedSpace = rootPane.workspaceID
                selectedTab = rootPane.tabID
                selectedPane = rootPane.id
                await refresh()
                guard generation == connectionGeneration else { return }
                _ = try await activeClient.request("agent.start", params: [
                    "pane_id": .string(rootPane.id), "kind": .string(kind),
                    "name": .string(name), "timeout_ms": .number(30000)
                ], timeout: 40)
            } catch {
                guard generation == connectionGeneration else { return }
                operationError = error.localizedDescription
            }
            guard generation == connectionGeneration else { return }
            if createdWorktree { await refresh() }
        }
    }

    func startServer() {
        guard serverProcess?.isRunning != true else { return }
        do {
            let path = (socketPath as NSString).expandingTildeInPath
            try FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/nohup")
            process.arguments = [(executable as NSString).expandingTildeInPath, "server"]
            var env = ProcessInfo.processInfo.environment
            env.removeValue(forKey: "HERDR_SESSION")
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
