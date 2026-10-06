import CryptoKit
import Foundation

/// Unsaved editor text kept on this Mac so a quit, crash or dropped SSH
/// connection never loses it. Drafts can hold secrets (an edited `.env`), so
/// the folder is private to the user, file names are hashes, and contents are
/// never logged. They are never uploaded by themselves.
public struct Draft: Codable, Equatable, Sendable {
    public var profileID: UUID
    public var workspaceID: String
    /// Recorded so a draft can't silently attach to a different space.
    public var spaceLabel: String
    public var root: String
    public var path: String
    public var text: String
    /// The disk version the edits started from.
    public var baselineSHA: String
    public var savedAt: Date

    public init(profileID: UUID, workspaceID: String, spaceLabel: String, root: String, path: String,
                text: String, baselineSHA: String, savedAt: Date = Date()) {
        self.profileID = profileID; self.workspaceID = workspaceID; self.spaceLabel = spaceLabel
        self.root = root; self.path = path; self.text = text; self.baselineSHA = baselineSHA; self.savedAt = savedAt
    }
}

public struct DraftStore: Sendable {
    public let directory: URL

    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("uHerdr/Drafts", isDirectory: true)
    }

    public init(directory: URL = DraftStore.defaultDirectory) { self.directory = directory }

    /// profile/<hash of path>.json: one draft per file per device.
    func url(profile: UUID, path: String) -> URL {
        let hash = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(profile.uuidString, isDirectory: true).appendingPathComponent(hash + ".json")
    }

    public func save(_ draft: Draft) throws {
        let file = url(profile: draft.profileID, path: draft.path)
        let folder = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        chmod(directory.path, 0o700)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(draft)
        let temp = folder.appendingPathComponent(".\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        guard rename(temp.path, file.path) == 0 else {
            unlink(temp.path)
            throw CocoaError(.fileWriteUnknown)
        }
    }

    public func load(profile: UUID, path: String) -> Draft? { read(url(profile: profile, path: path)) }

    /// Every draft of one device, oldest first; unreadable files are skipped.
    public func all(profile: UUID) -> [Draft] {
        let folder = directory.appendingPathComponent(profile.uuidString, isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap(read).sorted { $0.savedAt < $1.savedAt }
    }

    public func remove(profile: UUID, path: String) {
        try? FileManager.default.removeItem(at: url(profile: profile, path: path))
    }

    /// A removed device takes its drafts with it.
    public func removeAll(profile: UUID) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(profile.uuidString, isDirectory: true))
    }

    private func read(_ url: URL) -> Draft? {
        guard let data = FileManager.default.contents(atPath: url.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Draft.self, from: data)
    }
}
