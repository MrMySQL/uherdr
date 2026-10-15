import Foundation

/// What an open editor tab watches to notice that its file changed on disk:
/// size, modification time and inode (an agent that saves by renaming a new
/// file over the old one changes the inode even when size and time match).
public struct FileStamp: Equatable, Sendable {
    public var size: Int64
    /// Seconds since 1970; whole seconds on SSH devices.
    public var modified: Double
    public var inode: UInt64

    public init(size: Int64, modified: Double, inode: UInt64) {
        self.size = size; self.modified = modified; self.inode = inode
    }
}

public enum FileStamps {
    /// Stamps of files on this Mac; a missing or unreadable file has none.
    public static func local(_ paths: [String]) -> [String: FileStamp] {
        var result: [String: FileStamp] = [:]
        for path in Set(paths) {
            var info = stat()
            guard stat(path, &info) == 0 else { continue }
            let modified = Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9
            result[path] = FileStamp(size: Int64(info.st_size), modified: modified, inode: UInt64(info.st_ino))
        }
        return result
    }

    /// Args: the files. One line per file, in order: size, mtime and inode, or
    /// "-" when it is missing. GNU stat first, then BSD stat.
    static let script = #"""
    for f in "$@"; do
      if [ -e "$f" ]; then
        s=$(stat -L -c '%s %Y %i' -- "$f" 2>/dev/null || stat -L -f '%z %m %i' -- "$f" 2>/dev/null)
        [ -n "$s" ] && printf '%s\n' "$s" || echo -
      else echo -; fi
    done
    """#

    /// Stamps of files on an SSH device, in one ssh call.
    public static func remote(_ paths: [String], shell: RemoteShell) async throws -> [String: FileStamp] {
        let unique = Array(Set(paths)).sorted()
        guard !unique.isEmpty else { return [:] }
        let result = try await shell.run(script, unique, maxBytes: 1 << 20, timeout: .seconds(15))
        guard result.status == 0 else {
            let reason = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw HerdrError.message(reason.isEmpty ? "ssh exited with status \(result.status)" : reason)
        }
        return parse(String(decoding: result.stdout, as: UTF8.self), paths: unique)
    }

    static func parse(_ output: String, paths: [String]) -> [String: FileStamp] {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
        var stamps: [String: FileStamp] = [:]
        for (path, line) in zip(paths, lines) {
            let fields = line.split(separator: " ")
            guard fields.count == 3, let size = Int64(fields[0]), let modified = Double(fields[1]), let inode = UInt64(fields[2]) else { continue }
            stamps[path] = FileStamp(size: size, modified: modified, inode: inode)
        }
        return stamps
    }
}
