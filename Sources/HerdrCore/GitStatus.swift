import Foundation

/// One row of the Changes panel. A file both staged and changed again shows
/// in both groups, like Git itself reports it.
public struct GitChange: Hashable, Sendable, Identifiable {
    public enum Group: Int, CaseIterable, Sendable, Comparable {
        case conflicts, staged, changes, untracked

        public var title: String {
            switch self {
            case .conflicts: return "Conflicts"
            case .staged: return "Staged"
            case .changes: return "Changes"
            case .untracked: return "Untracked"
            }
        }

        public static func < (a: Group, b: Group) -> Bool { a.rawValue < b.rawValue }
    }

    public let group: Group
    /// Relative to the repository root.
    public let path: String
    /// Where a renamed or copied file came from.
    public let originalPath: String?
    /// Git's letter for the change: M, A, D, R, C, T; U for untracked, C for a conflict.
    public let letter: Character

    public init(group: Group, path: String, originalPath: String? = nil, letter: Character) {
        self.group = group; self.path = path; self.originalPath = originalPath; self.letter = letter
    }

    public var id: String { "\(group.rawValue):\(path)" }
    public var isDeleted: Bool { letter == "D" }
}

public struct GitBranch: Equatable, Sendable {
    /// nil when HEAD is detached.
    public var head: String?
    /// The commit, or nil before the first commit.
    public var oid: String?
    public var upstream: String?
    public var ahead = 0
    public var behind = 0

    public init(head: String? = nil, oid: String? = nil, upstream: String? = nil, ahead: Int = 0, behind: Int = 0) {
        self.head = head; self.oid = oid; self.upstream = upstream; self.ahead = ahead; self.behind = behind
    }

    /// What the header shows: the branch, or a short commit when detached.
    public var label: String {
        if let head { return head }
        if let oid { return "detached at \(oid.prefix(7))" }
        return "detached"
    }
}

/// `git status --porcelain=v2 -z --branch` output, parsed from bytes so odd
/// file names (newlines, quotes, non-UTF-8) come through untouched.
public enum GitStatusParser {
    public static func parse(_ data: Data) -> (branch: GitBranch, changes: [GitChange]) {
        var branch = GitBranch()
        var changes: [GitChange] = []
        let fields = data.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        var index = 0
        while index < fields.count {
            let record = fields[index]
            index += 1
            guard let kind = record.first else { continue }
            switch kind {
            case "#":
                let parts = record.split(separator: " ", maxSplits: 2).map(String.init)
                guard parts.count == 3 else { continue }
                switch parts[1] {
                case "branch.oid": branch.oid = parts[2] == "(initial)" ? nil : parts[2]
                case "branch.head": branch.head = parts[2] == "(detached)" ? nil : parts[2]
                case "branch.upstream": branch.upstream = parts[2]
                case "branch.ab":
                    let counts = parts[2].split(separator: " ")
                    if counts.count == 2 {
                        branch.ahead = Int(counts[0].dropFirst()) ?? 0
                        branch.behind = Int(counts[1].dropFirst()) ?? 0
                    }
                default: break
                }
            case "1":
                // 1 XY sub mH mI mW hH hI path
                guard let (xy, path) = split(record, fieldsBeforePath: 8) else { continue }
                changes += ordinary(xy, path: path, original: nil)
            case "2":
                // 2 XY sub mH mI mW hH hI Xscore path, then the original path as its own field.
                guard let (xy, path) = split(record, fieldsBeforePath: 9) else { continue }
                let original = index < fields.count ? fields[index] : nil
                index += 1
                changes += ordinary(xy, path: path, original: original)
            case "u":
                // u XY sub m1 m2 m3 mW h1 h2 h3 path
                guard let (_, path) = split(record, fieldsBeforePath: 10) else { continue }
                changes.append(GitChange(group: .conflicts, path: path, letter: "C"))
            case "?":
                guard record.hasPrefix("? ") else { continue }
                changes.append(GitChange(group: .untracked, path: String(record.dropFirst(2)), letter: "U"))
            default:
                continue // "!" ignored entries, or anything newer Git adds
            }
        }
        return (branch, changes)
    }

    /// Splits off a fixed number of space-separated fields; the rest is the path,
    /// which may itself contain spaces. Returns the XY field and the path.
    private static func split(_ record: String, fieldsBeforePath: Int) -> (String, String)? {
        let parts = record.split(separator: " ", maxSplits: fieldsBeforePath, omittingEmptySubsequences: false)
        guard parts.count == fieldsBeforePath + 1, parts[1].count == 2, !parts[fieldsBeforePath].isEmpty else { return nil }
        return (String(parts[1]), String(parts[fieldsBeforePath]))
    }

    private static func ordinary(_ xy: String, path: String, original: String?) -> [GitChange] {
        let x = xy.first!, y = xy.last!
        var rows: [GitChange] = []
        if x != "." { rows.append(GitChange(group: .staged, path: path, originalPath: x == "R" || x == "C" ? original : nil, letter: x)) }
        if y != "." { rows.append(GitChange(group: .changes, path: path, originalPath: y == "R" || y == "C" ? original : nil, letter: y)) }
        return rows
    }
}

/// Why the Changes panel has nothing to list.
public enum GitChangesError: Error, Equatable, LocalizedError {
    case gitMissing
    case notRepository
    /// Git refuses a repository owned by someone else ("dubious ownership").
    case dubiousOwnership
    case folderMissing
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .gitMissing: return "Git isn't installed."
        case .notRepository: return "This folder isn't inside a Git repository."
        case .dubiousOwnership: return "Git won't read this repository because another user owns it."
        case .folderMissing: return "The space's folder can't be opened."
        case let .failed(reason): return reason
        }
    }
}

/// The Changes panel's content: changes under the space's folder only, plus
/// how many lie elsewhere in a bigger repository.
public struct GitChanges: Equatable, Sendable {
    /// The repository's top folder, on the device.
    public let repositoryRoot: String
    /// The space folder's place in the repository, "" or ending in "/".
    public let prefix: String
    public let branch: GitBranch
    public let changes: [GitChange]
    /// Files with changes outside the space's folder, which aren't shown.
    public let outside: Int

    public init(repositoryRoot: String, prefix: String, branch: GitBranch, changes: [GitChange], outside: Int) {
        self.repositoryRoot = repositoryRoot; self.prefix = prefix; self.branch = branch; self.changes = changes; self.outside = outside
    }

    /// Distinct changed files shown, for the tab's count.
    public var fileCount: Int { Set(changes.map(\.path)).count }

    /// A change's full path on the device.
    public func absolutePath(_ path: String) -> String {
        repositoryRoot == "/" ? "/" + path : repositoryRoot + "/" + path
    }
}

public enum GitChangesReader {
    /// Shared by every Git script: drop the user's GIT_* variables (they could
    /// point Git at another repository), and never start a pager, a prompt or
    /// a lock.
    static let preamble = #"""
    for v in $(env | sed -n 's/^\(GIT_[A-Za-z0-9_]*\)=.*/\1/p'); do unset "$v"; done
    export GIT_PAGER=cat GIT_TERMINAL_PROMPT=0 GIT_OPTIONAL_LOCKS=0 LC_ALL=C
    command -v git >/dev/null 2>&1 || exit 20
    """#

    /// Args: the space folder. Prints the repository root and the folder's
    /// prefix as NUL-terminated fields, then the porcelain v2 status.
    static let script = preamble + "\n" + #"""
    cd "$1" 2>/dev/null || exit 21
    if ! e=$(git rev-parse --git-dir 2>&1 >/dev/null); then
      case $e in
        *"dubious ownership"*) exit 22 ;;
        *"not a git repository"*) exit 23 ;;
        *xcrun*|*"developer tools"*) exit 20 ;;
      esac
      printf '%s' "$e" >&2; exit 24
    fi
    t=$(git rev-parse --show-toplevel) || exit 24
    p=$(git rev-parse --show-prefix) || exit 24
    printf '%s\0%s\0' "$t" "$p"
    exec git --no-pager --no-optional-locks -c core.fsmonitor=false -c core.quotepath=false -c status.renames=true \
      status --porcelain=v2 -z --branch --untracked-files=all
    """#

    public static func read(root: String, runner: ScriptRunner) async throws -> GitChanges {
        let result = try await runner.run(script, [root], maxBytes: 32 << 20, timeout: .seconds(30))
        switch result.status {
        case 0: break
        case 20: throw GitChangesError.gitMissing
        case 21: throw GitChangesError.folderMissing
        case 22: throw GitChangesError.dubiousOwnership
        case 23: throw GitChangesError.notRepository
        default:
            let reason = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw GitChangesError.failed(reason.isEmpty ? "git exited with status \(result.status)" : reason)
        }
        return parse(result.stdout)
    }

    static func parse(_ output: Data) -> GitChanges {
        var rest = output[...]
        func field() -> String {
            guard let end = rest.firstIndex(of: 0) else { defer { rest = rest[rest.endIndex...] }; return String(decoding: rest, as: UTF8.self) }
            defer { rest = rest[rest.index(after: end)...] }
            return String(decoding: rest[..<end], as: UTF8.self)
        }
        let top = field(), prefix = field()
        let status = GitStatusParser.parse(Data(rest))
        let inside = status.changes.filter { prefix.isEmpty || $0.path.hasPrefix(prefix) }
        let outside = Set(status.changes.filter { !(prefix.isEmpty || $0.path.hasPrefix(prefix)) }.map(\.path)).count
        return GitChanges(repositoryRoot: top, prefix: prefix, branch: status.branch, changes: inside, outside: outside)
    }
}
