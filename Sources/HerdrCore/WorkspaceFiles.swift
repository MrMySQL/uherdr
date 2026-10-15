import Foundation

/// One row of the Files tree.
public struct FileEntry: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case file
        case directory
        /// `inside` is false when the link points outside the space's folder
        /// (shown, opened read-only, never expanded or searched) or nowhere.
        case symlink(target: String, inside: Bool, isDirectory: Bool)
        case other
    }

    public let name: String
    public let path: String
    public let kind: Kind

    public init(name: String, path: String, kind: Kind) {
        self.name = name
        self.path = path
        self.kind = kind
    }

    public var isHidden: Bool { name.hasPrefix(".") }
    /// Rows the tree can open as a folder: real folders, and links to folders inside the space.
    public var isExpandable: Bool {
        switch kind {
        case .directory: return true
        case let .symlink(_, inside, isDirectory): return inside && isDirectory
        default: return false
        }
    }
}

public enum FileListingError: Error, Equatable, LocalizedError {
    case denied(String)
    case missing(String)
    case notDirectory(String)
    case notFile(String)
    case outsideSpace(String)
    case failed(String, String)

    public var errorDescription: String? {
        switch self {
        case let .denied(path): return "No permission to read \(path)"
        case let .missing(path): return "\(path) no longer exists"
        case let .notDirectory(path): return "\(path) is not a folder"
        case let .notFile(path): return "\(path) is not a regular file"
        case let .outsideSpace(path): return "\(path) is outside this space's folder"
        case let .failed(path, reason): return "Couldn't read \(path): \(reason)"
        }
    }
}

/// Keeps every path the sidebar touches inside the space's folder.
/// Paths are compared after resolving symlinks, component by component,
/// so `/a/b-other` is not inside `/a/b` and `..` can't climb out.
public struct PathBoundary: Equatable, Sendable {
    public let root: String

    public init(root: String) throws {
        guard let canonical = Self.canonical(root) else { throw FileListingError.missing(root) }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: canonical, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw FileListingError.notDirectory(root)
        }
        self.root = canonical
    }

    /// The path with every symlink and `.`/`..` resolved, or nil if it doesn't exist.
    public static func canonical(_ path: String) -> String? {
        guard !path.isEmpty, !path.contains("\0"), let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    public func contains(_ path: String) -> Bool {
        guard let canonical = Self.canonical(path) else { return false }
        return Self.isWithin(canonical, root)
    }

    /// The root-relative path ("" for the root itself), or nil when outside.
    public func relative(_ path: String) -> String? {
        guard let canonical = Self.canonical(path), Self.isWithin(canonical, root) else { return nil }
        return canonical == root ? "" : String(canonical.dropFirst(root == "/" ? 1 : root.count + 1))
    }

    static func isWithin(_ path: String, _ root: String) -> Bool {
        if root == "/" { return path.hasPrefix("/") }
        return path == root || path.hasPrefix(root + "/")
    }
}

/// Lists one folder of a space on this Mac, without following symlinks.
public enum LocalFileListing {
    /// Names never shown in the tree, whatever the Hidden setting: Git's
    /// metadata folder and uHerdr's own in-progress save files.
    public static func isAlwaysHidden(_ name: String) -> Bool { name == ".git" || name.hasPrefix(".uherdr-") }

    public static func list(_ directory: String, in boundary: PathBoundary) throws -> [FileEntry] {
        guard let canonical = PathBoundary.canonical(directory) else { throw FileListingError.missing(directory) }
        guard PathBoundary.isWithin(canonical, boundary.root) else { throw FileListingError.outsideSpace(directory) }
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: canonical)
        } catch let error as NSError {
            switch (error.domain, error.code) {
            case (NSCocoaErrorDomain, NSFileReadNoPermissionError): throw FileListingError.denied(directory)
            case (NSCocoaErrorDomain, NSFileReadNoSuchFileError): throw FileListingError.missing(directory)
            case (NSPOSIXErrorDomain, Int(ENOTDIR)): throw FileListingError.notDirectory(directory)
            default:
                if (error.userInfo[NSUnderlyingErrorKey] as? NSError)?.code == Int(ENOTDIR) { throw FileListingError.notDirectory(directory) }
                throw FileListingError.failed(directory, error.localizedDescription)
            }
        }
        var entries: [FileEntry] = []
        for name in names where !isAlwaysHidden(name) {
            let path = canonical == "/" ? "/" + name : canonical + "/" + name
            var info = stat()
            guard lstat(path, &info) == 0 else { continue }
            let kind: FileEntry.Kind
            switch info.st_mode & S_IFMT {
            case S_IFREG: kind = .file
            case S_IFDIR: kind = .directory
            case S_IFLNK:
                let target = (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) ?? ""
                if let resolved = PathBoundary.canonical(path) {
                    var isDirectory: ObjCBool = false
                    FileManager.default.fileExists(atPath: resolved, isDirectory: &isDirectory)
                    kind = .symlink(target: target, inside: PathBoundary.isWithin(resolved, boundary.root), isDirectory: isDirectory.boolValue)
                } else {
                    kind = .symlink(target: target, inside: false, isDirectory: false)
                }
            default: kind = .other
            }
            entries.append(FileEntry(name: name, path: path, kind: kind))
        }
        return sorted(entries)
    }

    /// Folders first, then Finder's natural order ("file2" before "file10").
    public static func sorted(_ entries: [FileEntry]) -> [FileEntry] {
        entries.sorted { a, b in
            if a.isExpandable != b.isExpandable { return a.isExpandable }
            let order = a.name.localizedStandardCompare(b.name)
            return order == .orderedSame ? a.name < b.name : order == .orderedAscending
        }
    }
}
