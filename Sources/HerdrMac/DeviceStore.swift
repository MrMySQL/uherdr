import SwiftUI
import Combine
import HerdrCore

@MainActor
final class DeviceStore: ObservableObject {
    @Published private(set) var sessions: [SessionStore]
    @Published private(set) var selectedDeviceID: UUID
    @Published var editor: DeviceEditorTarget?
    @Published var pendingRemoval: UUID?
    @Published var sidebarMode = "spaces"
    let appearance: AppearanceStore
    private let defaults: UserDefaults
    private var subscriptions: [AnyCancellable] = []
    private var observedAppearanceRevisions: [ObjectIdentifier: Int] = [:]
    private var lastAppearanceRevision: Int

    init(defaults: UserDefaults = .standard, profiles: [DeviceProfile]? = nil, appearance: AppearanceStore? = nil) {
        self.defaults = defaults
        let sharedAppearance = appearance ?? AppearanceStore(defaults: defaults)
        self.appearance = sharedAppearance
        lastAppearanceRevision = sharedAppearance.revision
        let profiles = profiles ?? DeviceProfile.load(from: defaults, environment: ProcessInfo.processInfo.environment, home: NSHomeDirectory(), executable: SessionStore.findExecutable())
        precondition(!profiles.isEmpty)
        sessions = profiles.map { SessionStore(profile: $0, defaults: defaults, appearanceStore: sharedAppearance) }
        let savedID = defaults.string(forKey: "selectedDeviceID").flatMap(UUID.init(uuidString:))
        selectedDeviceID = profiles.first(where: { $0.id == savedID })?.id ?? profiles[0].id
        observeSessions()
        persist()
    }

    var activeSession: SessionStore { sessions.first { $0.profile.id == selectedDeviceID } ?? sessions[0] }
    var attentionCount: Int { sessions.reduce(0) { $0 + $1.attentionCount } }
    var workspaceShortcuts: [(session: SessionStore, workspace: Workspace)] {
        Array(sessions.flatMap { session in session.workspaces.map { (session, $0) } }.prefix(9))
    }

    func start() { sessions.forEach { $0.start() } }
    func stop() { sessions.forEach { $0.disconnect() } }

    func select(_ session: SessionStore, workspace: Workspace? = nil) {
        guard sessions.contains(where: { $0 === session }) else { return }
        selectedDeviceID = session.profile.id
        defaults.set(selectedDeviceID.uuidString, forKey: "selectedDeviceID")
        if let workspace { session.selectSpace(workspace) }
    }

    func save(_ profile: DeviceProfile) {
        guard profile.validationError == nil else { return }
        if let existing = sessions.first(where: { $0.profile.id == profile.id }) {
            existing.updateProfile(profile)
        } else {
            let session = SessionStore(profile: profile, defaults: defaults, appearanceStore: appearance)
            sessions.append(session)
            observeSessions()
            session.start()
        }
        persist()
    }

    func remove(_ id: UUID) {
        guard sessions.count > 1, let session = sessions.first(where: { $0.profile.id == id }), session.isRemote else { return }
        session.disconnect()
        sessions.removeAll { $0.profile.id == id }
        if selectedDeviceID == id { selectedDeviceID = sessions[0].profile.id }
        observeSessions()
        persist()
    }

    private func observeSessions() {
        observedAppearanceRevisions = Dictionary(uniqueKeysWithValues: sessions.map {
            (ObjectIdentifier($0), $0.appearanceRevision)
        })
        subscriptions = sessions.map { session in
            session.objectWillChange.sink { [weak self, weak session] _ in
                guard let self, let session else { return }
                let id = ObjectIdentifier(session)
                let revision = session.appearanceRevision
                if observedAppearanceRevisions[id] != revision {
                    observedAppearanceRevisions[id] = revision
                    guard lastAppearanceRevision != revision else { return }
                    lastAppearanceRevision = revision
                }
                objectWillChange.send()
            }
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(sessions.map(\.profile)) { defaults.set(data, forKey: DeviceProfile.preferencesKey) }
        defaults.set(selectedDeviceID.uuidString, forKey: "selectedDeviceID")
    }
}

struct DeviceEditorTarget: Identifiable {
    let id = UUID()
    var profile: DeviceProfile
    var isNew = false
}
