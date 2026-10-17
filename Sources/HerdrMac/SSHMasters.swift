import Foundation
import HerdrCore

/// The shared SSH connection of each device, started on first use and kept
/// while the device is connected. Every sidebar and editor command for an SSH
/// device gets its `RemoteShell` here.
@MainActor
final class SSHMasters {
    static let shared = SSHMasters()
    private var cleaned = false

    private var masters: [UUID: SSHMaster] = [:]
    private var starting: Set<UUID> = []
    private var lastAttempt: [UUID: Date] = [:]
    /// A master that couldn't connect isn't retried more often than this;
    /// commands meanwhile connect on their own.
    var retryInterval: TimeInterval = 10

    func shell(for profile: DeviceProfile) -> RemoteShell {
        if !cleaned {
            cleaned = true
            SSHMaster.removeStaleFolders()
        }
        let master: SSHMaster
        if let existing = masters[profile.id], existing.profile == profile {
            master = existing
        } else {
            masters[profile.id]?.stop()
            master = SSHMaster(profile: profile)
            masters[profile.id] = master
        }
        let id = profile.id
        if !master.isRunning, !starting.contains(id), Date().timeIntervalSince(lastAttempt[id] ?? .distantPast) > retryInterval {
            starting.insert(id)
            lastAttempt[id] = Date()
            Task { [weak self] in
                _ = await master.start()
                self?.starting.remove(id)
            }
        }
        return RemoteShell(profile: profile, controlPath: master.controlPath)
    }

    func stop(_ profile: UUID) {
        masters.removeValue(forKey: profile)?.stop()
        lastAttempt[profile] = nil
    }

    func stopAll() {
        for master in masters.values { master.stop() }
        masters = [:]
        lastAttempt = [:]
    }
}

extension SessionStore {
    /// How sidebar and editor commands reach this SSH device.
    var remoteShell: RemoteShell { SSHMasters.shared.shell(for: profile) }
}
