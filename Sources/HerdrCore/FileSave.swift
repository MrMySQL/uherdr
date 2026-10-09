import CryptoKit
import Foundation

public enum FileSaveError: Error, Equatable, LocalizedError {
    /// The file changed on disk after it was opened (or vanished).
    case conflict
    /// More than one name points at this file; replacing it would split them.
    case hardLinked(count: Int)
    /// The file is writable but its folder isn't, so it can't be replaced.
    case folderNotWritable
    case outsideSpace
    case notAFile
    /// You don't have permission to change this file.
    case readOnly
    /// Over SSH the connection failed after the write may have happened.
    case outcomeUnknown(String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .conflict: return "The file changed on disk after you opened it."
        case let .hardLinked(count): return "This file has \(count) names (hard links). Saving safely would separate them."
        case .folderNotWritable: return "You can't write to this file's folder, so it can't be replaced safely."
        case .outsideSpace: return "This file is outside the space's folder."
        case .notAFile: return "This is not a regular file."
        case .readOnly: return "This file is read-only: you don't have permission to change it."
        case let .outcomeUnknown(reason): return "The connection failed during the save, so it may or may not have been saved. \(reason)"
        case let .failed(reason): return "Couldn't save: \(reason)"
        }
    }
}

/// How a save may proceed past a check that stopped it.
public enum SaveMode: Equatable, Sendable {
    /// Refuse if the file changed on disk; replace it through a temp file.
    case safe
    /// The user chose "Overwrite with my version": skip the changed-on-disk check.
    case overwrite
    /// The user agreed to write into the file itself (hard links, unwritable folder).
    case inPlace
    /// Both partial-write risk and changed-on-disk overwrite were explicitly accepted.
    case overwriteInPlace
}

extension FileContents {
    /// The bytes to write for edited text: the file's own line ending
    /// everywhere and its BOM if it had one.
    public static func encode(_ text: String, lineEnding: LineEnding, bom: Bool) -> Data {
        var normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        switch lineEnding {
        case .lf: break
        case .crlf: normalized = normalized.replacingOccurrences(of: "\n", with: "\r\n")
        case .cr: normalized = normalized.replacingOccurrences(of: "\n", with: "\r")
        }
        return (bom ? Data([0xEF, 0xBB, 0xBF]) : Data()) + Data(normalized.utf8)
    }
}

/// Saves an editor tab's text on an SSH device with the same rules as
/// `LocalFileSaver`, in one fixed script whose arguments travel as quoted words
/// and whose new content arrives on stdin.
public enum RemoteFileSaver {
    /// Args: space folder, file, expected SHA-256 of the file now, mode
    /// (safe|overwrite|inplace), SHA-256 of the new content. Prints the new
    /// SHA-256. Exit 6 conflict, 7 write failed (including content that
    /// arrived incomplete), 8 hard-linked (count on stdout), 9 folder not
    /// writable, 10 outside the space, 11 not a file, 12 read-only file.
    ///
    /// The content always lands in a temp file first and is checked against
    /// its hash: when the connection drops mid-transfer, `cat` just sees an
    /// early end, and a short file must never replace (or become) the real one.
    static let script = #"""
    canon() {
      if command -v realpath >/dev/null 2>&1; then realpath "$1" 2>/dev/null
      else readlink -f "$1" 2>/dev/null; fi
    }
    if command -v sha256sum >/dev/null 2>&1; then h() { sha256sum "$1" | cut -d' ' -f1; }
    else h() { shasum -a 256 "$1" | cut -d' ' -f1; }; fi
    links() { stat -c %h "$1" 2>/dev/null || stat -f %l "$1"; }
    r=$(canon "$1"); f=$2; want=$3; mode=$4; new=$5
    [ -n "$r" ] || exit 10
    if [ ! -e "$f" ] && [ ! -L "$f" ]; then
      [ "$mode" = overwrite ] || [ "$mode" = overwrite-inplace ] || exit 6
      d=$(canon "${f%/*}")
      case "$d/" in "$r"/*) ;; *) exit 10 ;; esac
      t="$d/${f##*/}"
      tmp=$(mktemp "$d/.uherdr-save-XXXXXXXX") || exit 7
      [ -f "$tmp" ] && [ ! -L "$tmp" ] || exit 7
      trap 'rm -f "$tmp"' EXIT INT TERM HUP
      cat > "$tmp" || exit 7
      [ "$(h "$tmp")" = "$new" ] || exit 7
      ln "$tmp" "$t" 2>/dev/null || exit 6
      h "$t"; exit 0
    fi
    c=$(canon "$f")
    case "$c" in "$r"/*) ;; *) exit 10 ;; esac
    [ -f "$c" ] || exit 11
    [ -w "$c" ] || exit 12
    if [ "$mode" != overwrite ] && [ "$mode" != overwrite-inplace ] && [ "$(h "$c")" != "$want" ]; then exit 6; fi
    if [ "$mode" = inplace ] || [ "$mode" = overwrite-inplace ]; then
      tmp=$(mktemp "${TMPDIR:-/tmp}/uherdr-inplace-XXXXXX") || exit 7
      [ -f "$tmp" ] && [ ! -L "$tmp" ] || exit 7
      trap 'rm -f "$tmp"' EXIT INT TERM HUP
      cat > "$tmp" || exit 7
      [ "$(h "$tmp")" = "$new" ] || exit 7
      if [ "$mode" != overwrite-inplace ] && [ "$(h "$c")" != "$want" ]; then exit 6; fi
      cat "$tmp" > "$c" || exit 7
      h "$c"; exit 0
    fi
    n=$(links "$c")
    if [ "$n" -gt 1 ]; then printf '%s' "$n"; exit 8; fi
    [ -w "${c%/*}" ] || exit 9
    tmp=$(mktemp "${c%/*}/.uherdr-save-XXXXXXXX") || exit 7
    [ -f "$tmp" ] && [ ! -L "$tmp" ] || exit 7
    trap 'rm -f "$tmp"' EXIT INT TERM HUP
    cp -p "$c" "$tmp" 2>/dev/null || exit 7
    cat > "$tmp" || exit 7
    [ "$(h "$tmp")" = "$new" ] || exit 7
    if [ "$mode" != overwrite ] && [ "$mode" != overwrite-inplace ] && [ "$(h "$c")" != "$want" ]; then exit 6; fi
    mv -f "$tmp" "$c" || exit 7
    trap - EXIT
    h "$c"
    """#

    public static func save(_ text: String, to path: String, root: String, shell: RemoteShell,
                            baseline: FileContents, mode: SaveMode = .safe) async throws -> FileContents {
        let data = FileContents.encode(text, lineEnding: baseline.lineEnding, bom: baseline.hasBOM)
        let expected = FileContents.decode(data, limit: .max)
        let modeWord: String
        switch mode {
        case .safe: modeWord = "safe"
        case .overwrite: modeWord = "overwrite"
        case .inPlace: modeWord = "inplace"
        case .overwriteInPlace: modeWord = "overwrite-inplace"
        }
        let result: StreamingProcess.Result
        do {
            result = try await shell.run(script, [root, path, baseline.sha256, modeWord, expected.sha256], input: data, maxBytes: 4096, timeout: .seconds(60))
        } catch StreamingProcess.Failure.timedOut {
            throw FileSaveError.outcomeUnknown("The device didn't answer in time.")
        }
        let output = String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        switch result.status {
        case 0:
            // The device reports what it stored; anything else means we can't be sure.
            guard output == expected.sha256 else { throw FileSaveError.outcomeUnknown("The saved file doesn't match what was sent.") }
            return expected
        case 6: throw FileSaveError.conflict
        case 7: throw FileSaveError.failed("The file couldn't be written on the device, or didn't arrive complete; it wasn't changed.")
        case 8: throw FileSaveError.hardLinked(count: Int(output) ?? 2)
        case 9: throw FileSaveError.folderNotWritable
        case 10: throw FileSaveError.outsideSpace
        case 11: throw FileSaveError.notAFile
        case 12: throw FileSaveError.readOnly
        default:
            // ssh's own failure (255), a client stopped by a signal, or any
            // status the script never uses: the write may or may not have
            // happened, and reading the file back settles it.
            throw FileSaveError.outcomeUnknown(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}

/// Saves an editor tab's text on this Mac. The edited text replaces the file
/// only if the file is still the version that was opened: it is written to a
/// temp file beside the real file (symlinks are followed, so a link stays a
/// link), the target is checked once more, then the temp file is renamed over
/// it. Nothing protects against a program writing between that last check and
/// the rename; the UI says "changed on disk", never more.
public enum LocalFileSaver {
    public static func save(_ text: String, to path: String, in boundary: PathBoundary,
                            baseline: FileContents, mode: SaveMode = .safe) throws -> FileContents {
        guard let real = PathBoundary.canonical(path) else {
            // Deleted after it was opened: a conflict unless the user overwrites.
            guard mode == .overwrite || mode == .overwriteInPlace else { throw FileSaveError.conflict }
            return try create(text, at: path, in: boundary, baseline: baseline)
        }
        guard boundary.contains(real) else { throw FileSaveError.outsideSpace }
        var info = stat()
        guard stat(real, &info) == 0 else { throw FileSaveError.failed(String(cString: strerror(errno))) }
        guard info.st_mode & S_IFMT == S_IFREG else { throw FileSaveError.notAFile }
        // A rename would replace a read-only file; refuse it, as the device does.
        guard access(real, W_OK) == 0 else { throw FileSaveError.readOnly }
        let data = FileContents.encode(text, lineEnding: baseline.lineEnding, bom: baseline.hasBOM)
        if mode != .overwrite && mode != .overwriteInPlace, try currentHash(real) != baseline.sha256 { throw FileSaveError.conflict }
        if mode != .inPlace && mode != .overwriteInPlace {
            if info.st_nlink > 1 { throw FileSaveError.hardLinked(count: Int(info.st_nlink)) }
            let folder = (real as NSString).deletingLastPathComponent
            if access(folder, W_OK) != 0 { throw FileSaveError.folderNotWritable }
        }
        if mode == .inPlace || mode == .overwriteInPlace {
            try writeInPlace(data, to: real)
        } else {
            try replace(real, with: data, mode: info.st_mode & 0o7777, owner: info.st_uid, group: info.st_gid,
                        expected: mode == .safe ? baseline.sha256 : nil)
        }
        return FileContents.decode(data)
    }

    static func currentHash(_ path: String) throws -> String {
        guard let handle = FileHandle(forReadingAtPath: path) else { throw FileSaveError.failed("can't read \(path)") }
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty { hash.update(data: chunk) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func replace(_ real: String, with data: Data, mode: mode_t, owner: uid_t, group: gid_t, expected: String?) throws {
        let folder = (real as NSString).deletingLastPathComponent
        let name = (real as NSString).lastPathComponent
        let temp = folder + "/.uherdr-" + name + "-" + UUID().uuidString.prefix(8)
        let fd = open(temp, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw FileSaveError.failed(String(cString: strerror(errno))) }
        var renamed = false
        defer {
            close(fd)
            if !renamed { unlink(temp) }
        }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                guard written > 0 else { throw FileSaveError.failed(String(cString: strerror(errno))) }
                offset += written
            }
        }
        guard fsync(fd) == 0 else { throw FileSaveError.failed(String(cString: strerror(errno))) }
        fchmod(fd, mode)
        _ = fchown(fd, owner, group) // keeps the owner and group where allowed
        // Last check just before replacing: the file may have changed while writing.
        if let expected, try currentHash(real) != expected { throw FileSaveError.conflict }
        guard rename(temp, real) == 0 else { throw FileSaveError.failed(String(cString: strerror(errno))) }
        renamed = true
    }

    private static func writeInPlace(_ data: Data, to real: String) throws {
        guard let handle = FileHandle(forWritingAtPath: real) else { throw FileSaveError.failed("can't write \(real)") }
        defer { try? handle.close() }
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: data)
        try handle.synchronize()
    }

    /// The file was deleted after it was opened and the user chose to write it back.
    static func create(_ text: String, at path: String, in boundary: PathBoundary, baseline: FileContents,
                       writer: (Int32, UnsafeRawPointer?, Int) -> Int = { write($0, $1, $2) },
                       synchronize: (Int32) -> Int32 = fsync) throws -> FileContents {
        let folder = (path as NSString).deletingLastPathComponent
        guard let realFolder = PathBoundary.canonical(folder), boundary.contains(realFolder) else { throw FileSaveError.outsideSpace }
        let data = FileContents.encode(text, lineEnding: baseline.lineEnding, bom: baseline.hasBOM)
        let target = realFolder + "/" + (path as NSString).lastPathComponent
        let fd = open(target, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        guard fd >= 0 else { throw errno == EEXIST ? FileSaveError.conflict : FileSaveError.failed(String(cString: strerror(errno))) }
        var complete = false
        defer { close(fd); if !complete { unlink(target) } }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = writer(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { throw FileSaveError.failed(String(cString: strerror(errno))) }
                offset += written
            }
        }
        guard synchronize(fd) == 0 else { throw FileSaveError.failed(String(cString: strerror(errno))) }
        complete = true
        return FileContents.decode(data)
    }
}
