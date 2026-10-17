import Foundation

/// Runs fixed POSIX `sh` scripts on an SSH device, beside its files. ssh joins
/// the words after the host with spaces and the remote login shell parses that
/// line again, so the script and every argument travel as single-quoted words:
/// a path or query can never become shell syntax. Nothing is ever typed into a
/// terminal pane.
public struct RemoteShell: Sendable {
    public let profile: DeviceProfile
    public let ssh: String
    public let environment: [String: String]?
    /// The device's shared connection (`SSHMaster`), when there is one.
    public let controlPath: String?

    public init(profile: DeviceProfile, ssh: String = "/usr/bin/ssh", environment: [String: String]? = nil, controlPath: String? = nil) {
        self.profile = profile
        self.ssh = ssh
        self.environment = environment
        self.controlPath = controlPath
    }

    /// One shell word: 'it'\''s' for it's.
    public static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public func run(_ script: String, _ arguments: [String], input: Data? = nil,
                    maxBytes: Int = 16 << 20, timeout: Duration = .seconds(20)) async throws -> StreamingProcess.Result {
        try await StreamingProcess.run(executable: ssh, arguments: try command(script, arguments),
                                       environment: environment, input: input, maxBytes: maxBytes, timeout: timeout)
    }

    /// The same, as a stream: output arrives as it is produced, and ending the
    /// stream early stops the local ssh client.
    public func events(_ script: String, _ arguments: [String], maxBytes: Int, timeout: Duration) throws -> AsyncThrowingStream<StreamingProcess.Event, Error> {
        StreamingProcess.events(executable: ssh, arguments: try command(script, arguments), environment: environment,
                                keepInputOpen: true, maxBytes: maxBytes, timeout: timeout)
    }

    private func command(_ script: String, _ arguments: [String]) throws -> [String] {
        guard !arguments.contains(where: { $0.contains("\0") }) else { throw HerdrError.message("A path contains a NUL character.") }
        let words = ["sh", "-c", Self.quote(script), "uherdr"] + arguments.map(Self.quote)
        return try profile.sshArguments(control: controlPath.map { .client($0) } ?? .none) + ["--", profile.host] + words
    }
}

/// Lists one folder of a space on an SSH device, with the same rules as
/// `LocalFileListing`: no symlinks followed, links classified against the
/// space's folder, and distinct errors for the different failures.
public enum RemoteFileListing {
    /// Args: space folder, folder to list. Prints kind, name, link target and
    /// link flags (inside, directory) as NUL-separated fields.
    static let script = #"""
    canon() {
      if command -v realpath >/dev/null 2>&1; then realpath "$1" 2>/dev/null
      elif [ -d "$1" ]; then (cd -P "$1" 2>/dev/null && pwd -P)
      else readlink -f "$1" 2>/dev/null; fi
    }
    r=$(canon "$1"); d=$2
    [ -n "$r" ] || exit 3
    [ -e "$d" ] || exit 3
    [ -d "$d" ] || exit 5
    c=$(canon "$d")
    case "$c/" in "$r"/*) ;; *) exit 6 ;; esac
    { [ -r "$d" ] && [ -x "$d" ]; } || exit 4
    for f in "$d"/* "$d"/.*; do
      n=${f##*/}
      case $n in .|..) continue ;; esac
      [ -e "$f" ] || [ -L "$f" ] || continue
      if [ -L "$f" ]; then
        t=$(readlink "$f"); rc=$(canon "$f"); i=0; k=0
        if [ -n "$rc" ]; then
          case "$rc/" in "$r"/*) i=1 ;; esac
          [ -d "$rc" ] && k=1
        fi
        printf 'l\0%s\0%s\0%s%s\0' "$n" "$t" "$i" "$k"
      elif [ -d "$f" ]; then printf 'd\0%s\0\0\0' "$n"
      elif [ -f "$f" ]; then printf 'f\0%s\0\0\0' "$n"
      else printf 'o\0%s\0\0\0' "$n"
      fi
    done
    """#

    public static func list(_ directory: String, root: String, shell: RemoteShell) async throws -> [FileEntry] {
        let result = try await shell.run(script, [root, directory])
        switch result.status {
        case 0: break
        case 3: throw FileListingError.missing(directory)
        case 4: throw FileListingError.denied(directory)
        case 5: throw FileListingError.notDirectory(directory)
        case 6: throw FileListingError.outsideSpace(directory)
        default:
            let reason = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw FileListingError.failed(directory, reason.isEmpty ? "ssh exited with status \(result.status)" : reason)
        }
        return LocalFileListing.sorted(parse(result.stdout, in: directory))
    }

    static func parse(_ data: Data, in directory: String) -> [FileEntry] {
        let fields = data.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        var entries: [FileEntry] = []
        var index = 0
        while index + 3 < fields.count {
            let kind = fields[index], name = fields[index + 1], target = fields[index + 2], flags = fields[index + 3]
            index += 4
            guard !name.isEmpty, !LocalFileListing.isAlwaysHidden(name) else { continue }
            let path = directory == "/" ? "/" + name : directory + "/" + name
            switch kind {
            case "d": entries.append(FileEntry(name: name, path: path, kind: .directory))
            case "f": entries.append(FileEntry(name: name, path: path, kind: .file))
            case "l":
                entries.append(FileEntry(name: name, path: path, kind: .symlink(target: target, inside: flags.first == "1", isDirectory: flags.last == "1")))
            default: entries.append(FileEntry(name: name, path: path, kind: .other))
            }
        }
        return entries
    }
}
