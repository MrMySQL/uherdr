import CryptoKit
import Foundation

/// A file opened in an editor tab: its text if it is text, or why it can't be
/// shown. Keeps what saving needs to write it back the same way.
public struct FileContents: Equatable, Sendable {
    public enum LineEnding: String, Equatable, Sendable { case lf = "LF", crlf = "CRLF", cr = "CR" }

    public enum Kind: Equatable, Sendable {
        case text(String)
        /// Binary content, or text in an encoding the editor doesn't read.
        case unsupported(reason: String)
        case tooLarge(bytes: Int, limit: Int)
    }

    public let kind: Kind
    public let byteCount: Int
    public let hasBOM: Bool
    public let lineEnding: LineEnding
    /// SHA-256 of the bytes on disk, the save baseline.
    public let sha256: String

    /// Editable text files up to this size (decided in M0 to start at 5 MB).
    public static let editableLimit = 5_000_000

    public static func decode(_ data: Data, limit: Int = editableLimit) -> FileContents {
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard data.count <= limit else {
            return FileContents(kind: .tooLarge(bytes: data.count, limit: limit), byteCount: data.count, hasBOM: false, lineEnding: .lf, sha256: hash)
        }
        let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
        let hasBOM = data.starts(with: bom)
        let body = hasBOM ? data.dropFirst(3) : data[...]
        // A NUL in the first 8 KB means binary, as Git decides.
        if body.prefix(8192).contains(0) {
            return FileContents(kind: .unsupported(reason: "binary"), byteCount: data.count, hasBOM: false, lineEnding: .lf, sha256: hash)
        }
        guard let text = String(data: Data(body), encoding: .utf8) else {
            return FileContents(kind: .unsupported(reason: "not UTF-8 text"), byteCount: data.count, hasBOM: false, lineEnding: .lf, sha256: hash)
        }
        return FileContents(kind: .text(text), byteCount: data.count, hasBOM: hasBOM, lineEnding: lineEnding(of: text), sha256: hash)
    }

    /// The first line break decides; a file with none counts as LF.
    static func lineEnding(of text: String) -> LineEnding {
        guard let index = text.utf8.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) else { return .lf }
        let utf8 = text.utf8
        if utf8[index] == 0x0A { return .lf }
        let next = utf8.index(after: index)
        return next < utf8.endIndex && utf8[next] == 0x0A ? .crlf : .cr
    }
}

/// Reads a whole file for an editor tab, on this Mac or on an SSH device,
/// refusing anything that isn't a regular file inside the space.
public enum FileReader {
    /// Images, PDFs and Markdown preview assets are read whole, up to this size.
    public static let mediaLimit = 50 << 20

    /// A file's bytes, or its size when it is over the limit.
    public enum Raw: Equatable, Sendable {
        case data(Data)
        case tooLarge(Int)
    }

    /// `allowingLinkOutside`: the path is a symlink in the space whose target is
    /// outside it. Such a file is shown read-only (never saved), so its target
    /// may be read; any other path outside the space is refused.
    public static func readLocal(_ path: String, in boundary: PathBoundary, allowingLinkOutside: Bool = false,
                                 limit: Int = FileContents.editableLimit) throws -> FileContents {
        switch try readLocalData(path, in: boundary, allowingLinkOutside: allowingLinkOutside, limit: limit) {
        case let .data(data): return FileContents.decode(data, limit: limit)
        case let .tooLarge(size): return FileContents.decode(Data(count: 0), limit: limit).withTooLarge(bytes: size, limit: limit)
        }
    }

    /// The same checks, returning the bytes themselves (images, PDFs).
    public static func readLocalData(_ path: String, in boundary: PathBoundary, allowingLinkOutside: Bool = false,
                                     limit: Int = mediaLimit) throws -> Raw {
        guard let canonical = PathBoundary.canonical(path) else { throw FileListingError.missing(path) }
        if !boundary.contains(canonical) {
            var link = stat()
            let parent = (path as NSString).deletingLastPathComponent
            guard allowingLinkOutside, lstat(path, &link) == 0, link.st_mode & S_IFMT == S_IFLNK, boundary.contains(parent) else {
                throw FileListingError.outsideSpace(path)
            }
        }
        var info = stat()
        guard stat(canonical, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw FileListingError.notFile(path) }
        if Int(info.st_size) > limit { return .tooLarge(Int(info.st_size)) }
        guard let handle = FileHandle(forReadingAtPath: canonical) else { throw FileListingError.denied(path) }
        defer { try? handle.close() }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        return data.count > limit ? .tooLarge(data.count) : .data(data)
    }

    /// Args: space folder, file, limit, link-ok (1 lets a symlink in the space
    /// point outside it). Exit 3 missing, 4 unreadable, 5 not a regular file,
    /// 6 outside the space, 7 larger than the limit (size on stdout).
    static let readScript = #"""
    canon() {
      if command -v realpath >/dev/null 2>&1; then realpath "$1" 2>/dev/null
      else readlink -f "$1" 2>/dev/null; fi
    }
    r=$(canon "$1"); f=$2; limit=$3; linkok=$4
    [ -n "$r" ] || exit 3
    [ -e "$f" ] || exit 3
    c=$(canon "$f")
    case "$c" in
      "$r"/*) ;;
      *)
        [ "$linkok" = 1 ] && [ -L "$f" ] || exit 6
        p=$(canon "${f%/*}")
        case "$p/" in "$r"/*) ;; *) exit 6 ;; esac
        ;;
    esac
    [ -f "$c" ] || exit 5
    [ -r "$c" ] || exit 4
    s=$(wc -c < "$c" | tr -d ' ')
    if [ "$s" -gt "$limit" ]; then printf '%s' "$s"; exit 7; fi
    cat "$c"
    """#

    public static func readRemote(_ path: String, root: String, shell: RemoteShell, allowingLinkOutside: Bool = false,
                                  limit: Int = FileContents.editableLimit) async throws -> FileContents {
        switch try await readRemoteData(path, root: root, shell: shell, allowingLinkOutside: allowingLinkOutside, limit: limit) {
        case let .data(data): return FileContents.decode(data, limit: limit)
        case let .tooLarge(size): return FileContents.decode(Data(), limit: limit).withTooLarge(bytes: size, limit: limit)
        }
    }

    public static func readRemoteData(_ path: String, root: String, shell: RemoteShell, allowingLinkOutside: Bool = false,
                                      limit: Int = mediaLimit) async throws -> Raw {
        let result = try await shell.run(readScript, [root, path, String(limit), allowingLinkOutside ? "1" : "0"],
                                         maxBytes: limit + 1024, timeout: .seconds(limit > FileContents.editableLimit ? 120 : 30))
        switch result.status {
        case 0: return .data(result.stdout)
        case 3: throw FileListingError.missing(path)
        case 4: throw FileListingError.denied(path)
        case 5: throw FileListingError.notFile(path)
        case 6: throw FileListingError.outsideSpace(path)
        case 7: return .tooLarge(Int(String(decoding: result.stdout, as: UTF8.self)) ?? limit + 1)
        default:
            let reason = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw FileListingError.failed(path, reason.isEmpty ? "ssh exited with status \(result.status)" : reason)
        }
    }
}

extension FileContents {
    func withTooLarge(bytes: Int, limit: Int) -> FileContents {
        FileContents(kind: .tooLarge(bytes: bytes, limit: limit), byteCount: bytes, hasBOM: false, lineEnding: .lf, sha256: "")
    }
}
