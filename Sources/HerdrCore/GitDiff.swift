import Foundation

/// A read-only diff of one file, as the diff tab shows it.
public struct GitDiff: Equatable, Sendable {
    public struct Line: Equatable, Sendable {
        public enum Kind: Equatable, Sendable { case context, added, removed }
        public let kind: Kind
        public let text: String
        /// Line numbers in the old and new versions; nil on the side that lacks the line.
        public let old: Int?
        public let new: Int?
        /// "\ No newline at end of file" followed this line.
        public var noNewlineAtEnd = false

        public init(kind: Kind, text: String, old: Int?, new: Int?, noNewlineAtEnd: Bool = false) {
            self.kind = kind; self.text = text; self.old = old; self.new = new; self.noNewlineAtEnd = noNewlineAtEnd
        }
    }

    public struct Hunk: Equatable, Sendable {
        /// The "@@ -a,b +c,d @@ context" line as Git wrote it.
        public let header: String
        public var lines: [Line]

        public init(header: String, lines: [Line]) { self.header = header; self.lines = lines }

        /// Split view rows: context on both sides, and each run of removed
        /// lines beside the run of added lines that follows it.
        public var splitRows: [(old: Line?, new: Line?)] {
            var rows: [(old: Line?, new: Line?)] = []
            var removed: [Line] = [], added: [Line] = []
            func flush() {
                for i in 0..<max(removed.count, added.count) {
                    rows.append((i < removed.count ? removed[i] : nil, i < added.count ? added[i] : nil))
                }
                removed = []; added = []
            }
            for line in lines {
                switch line.kind {
                case .removed:
                    if !added.isEmpty { flush() }
                    removed.append(line)
                case .added: added.append(line)
                case .context:
                    flush()
                    rows.append((line, line))
                }
            }
            flush()
            return rows
        }
    }

    public var hunks: [Hunk] = []
    /// Git called it binary; there are no lines to show.
    public var isBinary = false

    public init(hunks: [Hunk] = [], isBinary: Bool = false) { self.hunks = hunks; self.isBinary = isBinary }

    public var added: Int { hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .added }.count } }
    public var removed: Int { hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .removed }.count } }
}

/// Parses `git diff` output for a single file. Headers (diff --git, index,
/// ---/+++ and mode lines) are skipped; only hunks are kept.
public enum UnifiedDiffParser {
    public static func parse(_ data: Data) -> GitDiff {
        var diff = GitDiff()
        var old = 0, new = 0
        var inHunk = false
        var lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
        if lines.last?.isEmpty == true { lines.removeLast() }
        for raw in lines {
            var line = String(decoding: raw, as: UTF8.self)
            if line.hasSuffix("\r") { line.removeLast() }
            if line.hasPrefix("@@ ") {
                guard let (oldStart, newStart) = hunkStarts(line) else { inHunk = false; continue }
                old = oldStart; new = newStart
                diff.hunks.append(GitDiff.Hunk(header: line, lines: []))
                inHunk = true
                continue
            }
            if !inHunk {
                if line.hasPrefix("Binary files ") || line == "GIT binary patch" { diff.isBinary = true }
                continue
            }
            guard let marker = line.first else {
                // An empty line inside a hunk is a context line whose text is empty
                // only when Git dropped the leading space; treat it as context.
                diff.hunks[diff.hunks.count - 1].lines.append(GitDiff.Line(kind: .context, text: "", old: old, new: new))
                old += 1; new += 1
                continue
            }
            let text = String(line.dropFirst())
            switch marker {
            case " ":
                diff.hunks[diff.hunks.count - 1].lines.append(GitDiff.Line(kind: .context, text: text, old: old, new: new))
                old += 1; new += 1
            case "+":
                diff.hunks[diff.hunks.count - 1].lines.append(GitDiff.Line(kind: .added, text: text, old: nil, new: new))
                new += 1
            case "-":
                diff.hunks[diff.hunks.count - 1].lines.append(GitDiff.Line(kind: .removed, text: text, old: old, new: nil))
                old += 1
            case "\\":
                let count = diff.hunks[diff.hunks.count - 1].lines.count
                if count > 0 { diff.hunks[diff.hunks.count - 1].lines[count - 1].noNewlineAtEnd = true }
            default:
                // The next file's header (a diff of one path never has one) ends the hunk.
                inHunk = false
                if line.hasPrefix("Binary files ") { diff.isBinary = true }
            }
        }
        return diff
    }

    /// "@@ -12,3 +12,4 @@ …" → (12, 12). (With a count of 0 the start is the
    /// line before, but that side then has no lines to number.)
    static func hunkStarts(_ header: String) -> (Int, Int)? {
        let parts = header.split(separator: " ")
        guard parts.count >= 3, parts[1].hasPrefix("-"), parts[2].hasPrefix("+") else { return nil }
        func start(_ part: Substring) -> Int? {
            guard let first = part.dropFirst().split(separator: ",").first else { return nil }
            return Int(first)
        }
        guard let a = start(parts[1]), let b = start(parts[2]) else { return nil }
        return (a, b)
    }
}

public enum GitDiffReader {
    /// Args: repository root, mode (staged, unstaged, untracked, base), path,
    /// and for a staged rename the original path. Paths are literal (no globs).
    /// "base" prints a blob: its path argument is "HEAD:<path>" or ":0:<path>".
    static let script = GitChangesReader.preamble + "\n" + #"""
    cd "$1" 2>/dev/null || exit 21
    export GIT_LITERAL_PATHSPECS=1
    o="--no-pager"
    d="diff --no-ext-diff --no-textconv --no-color -U3"
    case $2 in
      staged) exec git $o -c core.quotepath=false $d --cached -M -- ${4:+"$4"} "$3" ;;
      unstaged) exec git $o -c core.quotepath=false $d -- "$3" ;;
      untracked)
        git $o -c core.quotepath=false $d --no-index -- /dev/null "$3"
        s=$?; [ "$s" -le 1 ] && exit 0; exit "$s" ;;
      base) exec git $o cat-file blob "$3" ;;
      *) exit 25 ;;
    esac
    """#

    /// The diff a Changes row opens: staged rows compare HEAD with the index,
    /// other rows the index with the working file, untracked rows nothing with it.
    public static func read(_ change: GitChange, repositoryRoot: String, runner: ScriptRunner) async throws -> GitDiff {
        var arguments = [repositoryRoot]
        switch change.group {
        case .staged: arguments += ["staged", change.path] + (change.originalPath.map { [$0] } ?? [])
        case .untracked: arguments += ["untracked", change.path]
        case .changes, .conflicts: arguments += ["unstaged", change.path]
        }
        let result = try await runner.run(script, arguments, maxBytes: 8 << 20, timeout: .seconds(30))
        try check(result)
        return UnifiedDiffParser.parse(result.stdout)
    }

    /// A deleted file's last version: from HEAD when the deletion is staged,
    /// otherwise from the index.
    public static func baseVersion(_ change: GitChange, repositoryRoot: String, runner: ScriptRunner) async throws -> Data {
        let spec = (change.group == .staged ? "HEAD:" : ":0:") + change.path
        let result = try await runner.run(script, [repositoryRoot, "base", spec], maxBytes: FileContents.editableLimit + 1, timeout: .seconds(30))
        try check(result)
        return result.stdout
    }

    private static func check(_ result: StreamingProcess.Result) throws {
        switch result.status {
        case 0: return
        case 20: throw GitChangesError.gitMissing
        case 21: throw GitChangesError.folderMissing
        default:
            let reason = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw GitChangesError.failed(reason.isEmpty ? "git exited with status \(result.status)" : reason)
        }
    }
}
