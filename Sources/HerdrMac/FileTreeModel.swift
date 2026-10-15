import Foundation
import HerdrCore

/// The Files tab's state for one space's folder on this Mac: which folders
/// are open, what each one holds, and what Git ignores there. Folders load
/// when opened; nothing scans the whole tree.
@MainActor
final class FileTreeModel: ObservableObject {
    enum FolderState: Equatable {
        case loading
        case loaded([FileEntry])
        case failed(String)
    }

    @Published private(set) var root: String?
    @Published private(set) var rootError: String?
    @Published private(set) var folders: [String: FolderState] = [:]
    @Published private(set) var ignored: [String: Set<String>] = [:]
    @Published private(set) var expanded: Set<String> = []
    @Published var selection: String?
    @Published var showHidden = true { didSet { revision += 1 } }
    @Published var showIgnored = true { didSet { revision += 1 } }
    /// Bumped whenever the visible rows may have changed, so the outline reloads.
    @Published private(set) var revision = 0
    /// When a folder was last listed, for "last listing from 14:31" while the device is away.
    @Published private(set) var listedAt: Date?

    /// Where the folder lives: this Mac, or an SSH device reached with fixed scripts.
    enum Source: Equatable {
        case local
        case remote(RemoteShell)

        static func == (a: Source, b: Source) -> Bool {
            switch (a, b) {
            case (.local, .local): return true
            case let (.remote(x), .remote(y)): return x.profile == y.profile && x.ssh == y.ssh
            default: return false
            }
        }
    }

    @Published private(set) var source: Source = .local
    var isRemote: Bool { source != .local }

    private var boundary: PathBoundary?
    /// The remote folder as typed; the device's script resolves and checks it.
    private var remoteRoot: String?
    private var generation = UUID()
    private var requests: [String: UUID] = [:]
    /// Injectable folder reader for deterministic ordering checks.
    var readFolder: ((String) async throws -> [FileEntry])?

    /// Points the tree at a space's folder; nil clears it. Re-opening the same
    /// folder keeps what is expanded.
    func open(root newRoot: String?, source newSource: Source = .local) {
        let opened = boundary != nil || remoteRoot != nil
        guard newRoot != root || newSource != source || (newRoot != nil && !opened && rootError == nil) else { return }
        generation = UUID()
        requests = [:]
        listedAt = nil
        root = newRoot
        source = newSource
        remoteRoot = nil
        folders = [:]
        ignored = [:]
        expanded = []
        selection = nil
        rootError = nil
        boundary = nil
        revision += 1
        guard let newRoot else { return }
        if case .remote = newSource {
            remoteRoot = newRoot.count > 1 && newRoot.hasSuffix("/") ? String(newRoot.dropLast()) : newRoot
            load(remoteRoot!)
            return
        }
        do {
            boundary = try PathBoundary(root: newRoot)
        } catch {
            rootError = error.localizedDescription
            return
        }
        load(boundary!.root)
    }

    /// How to read a file of this tree for an editor tab.
    /// `outsideLink`: the row is a symlink pointing outside the space, which
    /// opens read-only.
    /// Reads and saves one file of this tree.
    func io(for path: String, outsideLink: Bool = false) -> EditorFileIO? {
        switch source {
        case .local: return boundary.map { Self.io(for: path, outsideLink: outsideLink, local: $0) }
        case let .remote(shell): return remoteRoot.map { Self.io(for: path, outsideLink: outsideLink, remoteRoot: $0, shell: shell) }
        }
    }

    /// Reads and saves a file of any space, also one not shown in the tree
    /// (tabs reopened after a relaunch). A link leading outside the space opens
    /// read-only, so its writer always refuses.
    static func io(for path: String, outsideLink: Bool, root: String, source: Source) -> EditorFileIO? {
        switch source {
        case .local:
            guard let boundary = try? PathBoundary(root: root) else { return nil }
            return io(for: path, outsideLink: outsideLink, local: boundary)
        case let .remote(shell):
            return io(for: path, outsideLink: outsideLink, remoteRoot: root.count > 1 && root.hasSuffix("/") ? String(root.dropLast()) : root, shell: shell)
        }
    }

    private static func io(for path: String, outsideLink: Bool, local boundary: PathBoundary) -> EditorFileIO {
        EditorFileIO(
            read: { try await Task.detached { try FileReader.readLocal(path, in: boundary, allowingLinkOutside: outsideLink) }.value },
            write: { text, baseline, mode in
                if outsideLink { throw FileSaveError.outsideSpace }
                return try await Task.detached {
                    try LocalFileSaver.save(text, to: path, in: boundary, baseline: baseline, mode: mode)
                }.value
            },
            readData: { try await Task.detached { try FileReader.readLocalData(path, in: boundary, allowingLinkOutside: outsideLink) }.value })
    }

    private static func io(for path: String, outsideLink: Bool, remoteRoot: String, shell: RemoteShell) -> EditorFileIO {
        EditorFileIO(
            read: { try await FileReader.readRemote(path, root: remoteRoot, shell: shell, allowingLinkOutside: outsideLink) },
            write: { text, baseline, mode in
                if outsideLink { throw FileSaveError.outsideSpace }
                return try await RemoteFileSaver.save(text, to: path, root: remoteRoot, shell: shell, baseline: baseline, mode: mode)
            },
            readData: { try await FileReader.readRemoteData(path, root: remoteRoot, shell: shell, allowingLinkOutside: outsideLink) })
    }

    /// The tree's top folder: resolved on this Mac, as typed on an SSH device.
    var canonicalRoot: String? { boundary?.root ?? remoteRoot }

    /// The rows under a folder, after the Hidden and Ignored settings.
    func children(of path: String) -> [FileEntry] {
        guard case let .loaded(entries) = folders[path] else { return [] }
        let ignoredHere = ignored[path] ?? []
        return entries.filter { entry in
            (showHidden || !entry.isHidden) && (showIgnored || !ignoredHere.contains(entry.name))
        }
    }

    func isIgnored(_ entry: FileEntry) -> Bool {
        ignored[(entry.path as NSString).deletingLastPathComponent]?.contains(entry.name) ?? false
    }

    func setExpanded(_ path: String, _ isExpanded: Bool) {
        if isExpanded {
            guard !expanded.contains(path) else { return }
            expanded.insert(path)
            if folders[path] == nil { load(path) }
        } else {
            expanded.remove(path)
        }
    }

    /// The open folders relative to the space folder, deepest last (to remember them).
    var expandedRelative: [String] {
        guard let top = canonicalRoot else { return [] }
        return expanded.compactMap { path -> String? in
            guard path.hasPrefix(top == "/" ? "/" : top + "/") else { return nil }
            return String(path.dropFirst(top == "/" ? 1 : top.count + 1))
        }.sorted { ($0.split(separator: "/").count, $0) < ($1.split(separator: "/").count, $1) }
    }

    /// Opens remembered folders again, parents first; ones that are gone stay closed.
    func restoreExpanded(_ relatives: [String]) async {
        guard let top = canonicalRoot else { return }
        let token = generation
        for relative in relatives.sorted(by: { $0.split(separator: "/").count < $1.split(separator: "/").count }) {
            let path = top == "/" ? "/" + relative : top + "/" + relative
            let parent = (path as NSString).deletingLastPathComponent
            guard token == generation, parent == top || expanded.contains(parent) else { continue }
            if folders[path] == nil { await loadNow(path) }
            guard token == generation, case .loaded? = folders[path] else { continue }
            expanded.insert(path)
        }
        revision += 1
    }

    func collapseAll() {
        expanded = []
        revision += 1
    }

    /// Re-reads every folder that is open, keeping what is expanded.
    func refresh() {
        guard let top = canonicalRoot else {
            let (current, currentSource) = (root, source)
            root = nil
            open(root: current, source: currentSource)
            return
        }
        for path in [top] + expanded.sorted() { load(path) }
    }

    /// Opens every folder above a path inside the space and selects it.
    func reveal(_ path: String) async {
        guard let top = canonicalRoot else { return }
        let relative: String
        if let boundary {
            guard let inside = boundary.relative(path), !inside.isEmpty else { return }
            relative = inside
        } else {
            guard path.hasPrefix(top + "/") else { return }
            relative = String(path.dropFirst(top.count + 1))
        }
        var folder = top
        for component in relative.split(separator: "/").dropLast() {
            folder += "/" + component
            expanded.insert(folder)
            if folders[folder] == nil { await loadNow(folder) }
        }
        selection = top + "/" + relative
        revision += 1
    }

    private func load(_ path: String) {
        Task { await loadNow(path) }
    }

    private func loadNow(_ path: String) async {
        let token = generation, request = UUID()
        requests[path] = request
        defer { if requests[path] == request { requests.removeValue(forKey: path) } }
        let result: Result<[FileEntry], Error>
        if let readFolder {
            do { result = .success(try await readFolder(path)) } catch { result = .failure(error) }
        } else {
        switch source {
        case .local:
            guard let boundary else { return }
            if folders[path] == nil { folders[path] = .loading; revision += 1 }
            result = await Task.detached(priority: .userInitiated) {
                Result { try LocalFileListing.list(path, in: boundary) }
            }.value
        case let .remote(shell):
            guard let remoteRoot else { return }
            if folders[path] == nil { folders[path] = .loading; revision += 1 }
            do { result = .success(try await RemoteFileListing.list(path, root: remoteRoot, shell: shell)) }
            catch { result = .failure(error) }
        }
        }
        guard token == generation, requests[path] == request else { return }
        switch result {
        case let .success(entries):
            folders[path] = .loaded(entries)
            listedAt = Date()
            revision += 1
            // Git's ignore rules, from Git on the device that holds the files.
            let names = entries.map(\.name)
            let ignoredNames: Set<String>
            if case let .remote(shell) = source {
                ignoredNames = await GitIgnoreCheck.ignoredNames(names, in: path, shell: shell)
            } else {
                ignoredNames = await GitIgnoreCheck.ignoredNames(names, in: path)
            }
            guard token == generation, requests[path] == request else { return }
            if ignored[path] != ignoredNames {
                ignored[path] = ignoredNames
                revision += 1
            }
        case let .failure(error):
            folders[path] = .failed(error.localizedDescription)
            revision += 1
        }
    }
}
