import SwiftUI
import Combine
import HerdrCore

@MainActor
final class DeviceStore: ObservableObject {
    @Published private(set) var sessions: [SessionStore]
    @Published private(set) var selectedDeviceID: UUID
    @Published var editor: DeviceEditorTarget?
    @Published var pendingRemoval: UUID?
    @Published var pendingSessionAction: SessionAction?
    @Published var pendingMachineRemoval: String?
    /// The latest `herdr session list`, refreshed by discovery and after actions.
    @Published private(set) var herdrSessions: [HerdrSessionEntry] = []
    @Published var sidebarMode = "spaces"
    private let defaults: UserDefaults
    private var subscriptions: [AnyCancellable] = []
    private let sessionLister: @MainActor (String) async throws -> [HerdrSessionEntry]
    private let sessionRunner: @MainActor (String) -> SessionControl.Runner
    private let launchServer: @MainActor (String, SessionControl.ServerLaunch) throws -> Void
    private var discoveryTask: Task<Void, Never>?
    private var discovering = false

    init(defaults: UserDefaults = .standard, profiles: [DeviceProfile]? = nil,
         sessionLister: @escaping @MainActor (String) async throws -> [HerdrSessionEntry] = { try await SessionDiscovery.list(executable: $0) },
         sessionRunner: @escaping @MainActor (String) -> SessionControl.Runner = { SessionControl.runner(executable: $0) },
         launchServer: @escaping @MainActor (String, SessionControl.ServerLaunch) throws -> Void = DeviceStore.launchDetachedServer) {
        self.defaults = defaults
        self.sessionLister = sessionLister
        self.sessionRunner = sessionRunner
        self.launchServer = launchServer
        let profiles = profiles ?? DeviceProfile.load(from: defaults, environment: ProcessInfo.processInfo.environment, home: NSHomeDirectory(), executable: SessionStore.findExecutable())
        precondition(!profiles.isEmpty)
        sessions = profiles.map { SessionStore(profile: $0, defaults: defaults) }
        let savedID = defaults.string(forKey: "selectedDeviceID").flatMap(UUID.init(uuidString:))
        selectedDeviceID = profiles.first(where: { $0.id == savedID })?.id ?? profiles[0].id
        observeSessions()
        persist()
    }

    var activeSession: SessionStore { sessions.first { $0.profile.id == selectedDeviceID } ?? sessions[0] }
    var attentionCount: Int { sessions.reduce(0) { $0 + $1.attentionCount } }
    /// Sessions grouped by machine, in order of first appearance.
    var machineGroups: [MachineGroup] {
        var groups: [MachineGroup] = []
        for session in sessions {
            let key = session.profile.machineKey
            if let index = groups.firstIndex(where: { $0.id == key }) { groups[index].sessions.append(session) }
            else { groups.append(MachineGroup(id: key, name: session.isRemote ? session.profile.name : "This Mac", isRemote: session.isRemote, sessions: [session])) }
        }
        return groups
    }
    /// Follows the sidebar's grouped order.
    var workspaceShortcuts: [(session: SessionStore, workspace: Workspace)] {
        Array(machineGroups.flatMap(\.sessions).flatMap { session in session.workspaces.map { (session, $0) } }.prefix(9))
    }

    func start() {
        sessions.forEach { $0.start() }
        guard discoveryTask == nil else { return }
        discoveryTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.discoverSessions()
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    func stop() {
        discoveryTask?.cancel(); discoveryTask = nil
        sessions.forEach { $0.disconnect() }
    }

    /// Adds a local device for each running herdr session on this Mac that no
    /// device uses yet. Failures are silent: older herdr CLIs lack `session list`.
    func discoverSessions(includeDismissed: Bool = false) async {
        guard !discovering else { return }
        discovering = true
        defer { discovering = false }
        let executable = sessions.first { !$0.isRemote }?.executable ?? SessionStore.findExecutable()
        guard let found = try? await sessionLister(executable) else { return }
        herdrSessions = found
        if includeDismissed { defaults.removeObject(forKey: SessionDiscovery.dismissedKey) }
        let dismissed = Set(defaults.stringArray(forKey: SessionDiscovery.dismissedKey) ?? [])
        for profile in SessionDiscovery.newProfiles(for: found, existing: sessions.map(\.profile), dismissed: dismissed, executable: executable) {
            save(profile)
        }
    }

    func select(_ session: SessionStore, workspace: Workspace? = nil) {
        guard sessions.contains(where: { $0 === session }) else { return }
        // Keep appearance shared while each device retains its own navigation state.
        session.appearance = activeSession.appearance
        session.fontSize = activeSession.fontSize
        selectedDeviceID = session.profile.id
        defaults.set(selectedDeviceID.uuidString, forKey: "selectedDeviceID")
        if let workspace { session.selectSpace(workspace) }
    }

    /// A machine edit also applies its SSH connection to the machine's other sessions.
    func save(_ profile: DeviceProfile, machine machineID: String? = nil) {
        guard profile.validationError == nil else { return }
        if let machineID, let machine = machine(machineID), machine.isRemote {
            for other in machine.sessions where other.profile.id != profile.id {
                var updated = other.profile
                updated.host = profile.host; updated.user = profile.user
                updated.port = profile.port; updated.identityFile = profile.identityFile
                updated.executable = profile.executable
                if updated.validationError == nil, updated != other.profile { other.updateProfile(updated) }
            }
        }
        if let existing = sessions.first(where: { $0.profile.id == profile.id }) {
            existing.updateProfile(profile)
        } else {
            let session = SessionStore(profile: profile, defaults: defaults)
            sessions.append(session)
            observeSessions()
            session.start()
        }
        persist()
    }

    func remove(_ id: UUID) { remove(id, dismiss: true) }

    private func remove(_ id: UUID, dismiss: Bool) {
        guard sessions.count > 1, let session = sessions.first(where: { $0.profile.id == id }) else { return }
        if dismiss, !session.isRemote {
            // Keep a removed local session from being discovered again.
            var dismissed = defaults.stringArray(forKey: SessionDiscovery.dismissedKey) ?? []
            dismissed.append(SessionDiscovery.normalized(session.profile.socketPath))
            defaults.set(dismissed, forKey: SessionDiscovery.dismissedKey)
        }
        session.disconnect()
        sessions.removeAll { $0.profile.id == id }
        if selectedDeviceID == id { selectedDeviceID = sessions[0].profile.id }
        observeSessions()
        persist()
    }

    /// The herdr session behind a local device, if herdr lists its socket.
    func herdrSession(for session: SessionStore) -> HerdrSessionEntry? {
        SessionControl.session(for: session.profile, in: herdrSessions)
    }

    func canRemoveHerdrSession(_ session: SessionStore) -> Bool {
        sessions.count > 1 && herdrSession(for: session).map(SessionControl.canDelete) == true
    }

    func machine(_ id: String) -> MachineGroup? { machineGroups.first { $0.id == id } }

    func reconnectAll(_ machineID: String) { machine(machineID)?.sessions.forEach { $0.reconnect() } }
    func disconnectAll(_ machineID: String) { machine(machineID)?.sessions.forEach { $0.disconnect() } }

    /// Removes a saved SSH machine and every session on it; its herdr
    /// sessions keep running. At least one device always remains.
    func removeMachine(_ machineID: String) {
        guard let machine = machine(machineID), machine.isRemote, sessions.count > machine.sessions.count else { return }
        for session in machine.sessions { remove(session.profile.id, dismiss: false) }
    }

    func canRemoveMachine(_ machineID: String) -> Bool {
        guard let machine = machine(machineID) else { return false }
        return machine.isRemote && sessions.count > machine.sessions.count
    }

    /// This Mac's herdr sessions that are not running, for the machine menu.
    var stoppedHerdrSessions: [HerdrSessionEntry] { herdrSessions.filter { !$0.running } }

    /// Starts a stopped session from the machine menu, adding its device if needed.
    func startHerdrSession(_ entry: HerdrSessionEntry) async {
        let socket = SessionDiscovery.normalized(entry.socketPath)
        var target = sessions.first { !$0.isRemote && SessionDiscovery.normalized($0.profile.socketPath) == socket }
        if target == nil {
            save(DeviceProfile(name: entry.name, kind: .local, socketPath: socket, executable: localExecutable))
            target = sessions.last
        }
        if let target { await startServer(for: target) }
    }

    /// Starts the server for a local device with its own session's data.
    func startServer(for session: SessionStore) async {
        guard !session.isRemote else { return }
        let run = sessionRunner(session.executable)
        do {
            // Fail closed: without herdr's list a named session would start bare.
            let current = try await SessionControl.list(run)
            herdrSessions = current
            guard let launch = SessionControl.serverLaunch(for: session.profile, in: current, environment: ProcessInfo.processInfo.environment) else {
                throw HerdrError.message("herdr no longer lists this session.")
            }
            try launchServer(session.executable, launch)
            await waitForSocket(session.profile.socketPath, present: true)
            session.reconnect()
            await discoverSessions()
        } catch {
            activeSession.operationError = error.localizedDescription
        }
    }

    /// Stops whatever server answers on the session's socket (even one
    /// started with the wrong data) and starts the session's own.
    func restartHerdrSession(_ session: SessionStore) async {
        guard await runSessionAction(on: session, { entry, run in try await SessionControl.stop(entry.name, run) }) else { return }
        await waitForSocket(session.profile.socketPath, present: false)
        await startServer(for: session)
    }

    private func waitForSocket(_ path: String, present: Bool) async {
        let socket = SessionDiscovery.normalized(path)
        for _ in 0..<100 where FileManager.default.fileExists(atPath: socket) != present {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Runs herdr detached from the app, so quitting uHerdr leaves it running.
    static func launchDetachedServer(executable: String, launch: SessionControl.ServerLaunch) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nohup")
        process.arguments = [(executable as NSString).expandingTildeInPath] + launch.arguments
        process.environment = launch.environment
        process.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    func stopHerdrSession(_ session: SessionStore) async {
        await runSessionAction(on: session) { entry, run in try await SessionControl.stop(entry.name, run) }
    }

    /// Stops the session if needed, deletes it from herdr, then removes it here.
    func removeHerdrSession(_ session: SessionStore) async {
        guard canRemoveHerdrSession(session) else { return }
        let id = session.profile.id
        if await runSessionAction(on: session, { entry, run in try await SessionControl.delete(entry, run) }) {
            remove(id, dismiss: false)
        }
    }

    /// Re-reads the session list first, so the action uses herdr's current state.
    @discardableResult
    private func runSessionAction(on session: SessionStore,
                                  _ action: @MainActor (HerdrSessionEntry, SessionControl.Runner) async throws -> Void) async -> Bool {
        let run = sessionRunner(session.executable)
        do {
            let current = try await SessionControl.list(run)
            herdrSessions = current
            guard let entry = SessionControl.session(for: session.profile, in: current) else {
                throw HerdrError.message("herdr no longer lists this session.")
            }
            try await action(entry, run)
            await discoverSessions()
            return true
        } catch {
            activeSession.operationError = error.localizedDescription
            return false
        }
    }

    private var localExecutable: String {
        sessions.first { !$0.isRemote }?.executable ?? SessionStore.findExecutable()
    }

    private func observeSessions() {
        subscriptions = sessions.map { session in
            session.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(sessions.map(\.profile)) { defaults.set(data, forKey: DeviceProfile.preferencesKey) }
        defaults.set(selectedDeviceID.uuidString, forKey: "selectedDeviceID")
    }
}

@MainActor
struct MachineGroup: Identifiable {
    let id: String
    let name: String
    let isRemote: Bool
    var sessions: [SessionStore]
    var powerStatus: DevicePowerStatus? { sessions.lazy.compactMap { $0.powerStatus }.first }
}

struct DeviceEditorTarget: Identifiable {
    let id = UUID()
    var profile: DeviceProfile
    var isNew = false
    /// Set when editing a whole SSH machine's connection.
    var machineID: String?
}

enum SessionAction: Identifiable {
    case stop(UUID), remove(UUID), restart(UUID)
    var id: String {
        switch self {
        case .stop(let id): "stop:\(id)"
        case .remove(let id): "remove:\(id)"
        case .restart(let id): "restart:\(id)"
        }
    }
    var deviceID: UUID {
        switch self { case .stop(let id), .remove(let id), .restart(let id): id }
    }
}
