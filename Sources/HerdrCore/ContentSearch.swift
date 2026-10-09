import Foundation

/// What the Search panel asks for.
public struct SearchOptions: Equatable, Sendable {
    public var query: String
    public var caseSensitive = false
    public var wholeWord = false
    /// Comma-separated globs, as typed ("Sources/**/*.swift, *.md").
    public var include = ""
    public var exclude = ""

    public init(query: String, caseSensitive: Bool = false, wholeWord: Bool = false, include: String = "", exclude: String = "") {
        self.query = query; self.caseSensitive = caseSensitive; self.wholeWord = wholeWord; self.include = include; self.exclude = exclude
    }

    static func globs(_ text: String) -> [String] {
        var result: [String] = [], current = ""
        var braces = 0, brackets = 0, escaped = false
        for character in text {
            if escaped { current.append(character); escaped = false; continue }
            if character == "\\" { current.append(character); escaped = true; continue }
            if character == "{" { braces += 1 }
            if character == "}" { braces = max(0, braces - 1) }
            if character == "[" { brackets += 1 }
            if character == "]" { brackets = max(0, brackets - 1) }
            if character == ",", braces == 0, brackets == 0 { result.append(current); current = "" }
            else { current.append(character) }
        }
        result.append(current)
        return result.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
    public var includeGlobs: [String] { Self.globs(include) }
    public var excludeGlobs: [String] { Self.globs(exclude) }

    /// ripgrep's arguments: literal text, never a regex, and no config file.
    /// Only excludes go to ripgrep: an include glob there would override the
    /// ignore rules and search hidden and ignored files (".build/**/*.swift"),
    /// so includes are applied to the results instead.
    public var ripgrepArguments: [String] {
        var args = ["--json", "--no-config", "--fixed-strings", caseSensitive ? "--case-sensitive" : "--ignore-case"]
        if wholeWord { args.append("--word-regexp") }
        for glob in excludeGlobs { args += ["--glob", "!" + glob] }
        return args + ["--", query, "."]
    }
}

/// One matching line.
public struct SearchHit: Equatable, Sendable {
    /// Relative to the space folder.
    public let path: String
    /// 1-based.
    public let line: Int
    /// The line, without its line break.
    public let text: String
    /// Matches as UTF-16 offsets into `text`, so the editor can select them.
    public let ranges: [Range<Int>]

    public init(path: String, line: Int, text: String, ranges: [Range<Int>]) {
        self.path = path; self.line = line; self.text = text; self.ranges = ranges
    }
}

/// Decodes `rg --json` output, one record per line.
public enum RipgrepJSON {
    public enum Record: Equatable, Sendable {
        case match(SearchHit)
        case other
    }

    /// Records bigger than this (a minified file's single line) are skipped.
    public static let recordLimit = 1 << 20

    private struct Text: Decodable {
        let text: String?
        let bytes: String?
        /// The raw bytes, base64-decoded when ripgrep had to send them that way.
        var data: Data? { text.map { Data($0.utf8) } ?? bytes.flatMap { Data(base64Encoded: $0) } }
    }
    private struct Submatch: Decodable { let start: Int; let end: Int }
    private struct MatchData: Decodable {
        let path: Text
        let lines: Text
        let line_number: Int?
        let submatches: [Submatch]
    }
    private struct Envelope: Decodable {
        let type: String
        let data: MatchData?
        enum CodingKeys: String, CodingKey { case type, data }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            type = try container.decode(String.self, forKey: .type)
            data = type == "match" ? try container.decode(MatchData.self, forKey: .data) : nil
        }
    }

    public static func decode(_ line: Data) -> Record? {
        guard !line.isEmpty, line.count <= recordLimit,
              let envelope = try? JSONDecoder().decode(Envelope.self, from: line) else { return nil }
        guard let data = envelope.data, let lineBytes = data.lines.data, let pathBytes = data.path.data, let number = data.line_number else {
            return .other
        }
        var path = String(decoding: pathBytes, as: UTF8.self)
        if path.hasPrefix("./") { path.removeFirst(2) }
        var bytes = lineBytes
        while let last = bytes.last, last == 10 || last == 13 { bytes.removeLast() }
        let text = String(decoding: bytes, as: UTF8.self)
        // Byte offsets to UTF-16: decode the prefix before each offset.
        func utf16(_ offset: Int) -> Int {
            String(decoding: bytes.prefix(max(0, min(offset, bytes.count))), as: UTF8.self).utf16.count
        }
        let ranges = data.submatches.map { utf16($0.start)..<max(utf16($0.start), utf16($0.end)) }
        return .match(SearchHit(path: path, line: number, text: text, ranges: ranges))
    }

    /// "rg: ./private: Permission denied (os error 13)" → "private: no permission".
    public static func problems(_ stderr: String) -> [String] {
        stderr.split(separator: "\n").compactMap { line in
            guard line.hasPrefix("rg: ") else { return nil }
            let rest = line.dropFirst(4)
            guard let colon = rest.range(of: ": ", options: .backwards) else { return String(rest) }
            var path = String(rest[..<colon.lowerBound])
            if path.hasPrefix("./") { path.removeFirst(2) }
            let reason = rest[colon.upperBound...]
            return path + ": " + (reason.hasPrefix("Permission denied") ? "no permission" : String(reason))
        }
    }
}

/// gitignore-style globs, as ripgrep's --glob uses them, for files searched in
/// memory: a pattern without "/" matches the name at any depth; one with "/" is
/// anchored at the space folder; "**" spans folders, "*" and "?" don't.
public enum Glob {
    public static func matches(_ pattern: String, _ path: String) -> Bool {
        var pattern = pattern
        let anchored = pattern.dropLast().contains("/")
        if pattern.hasPrefix("/") { pattern.removeFirst() }
        if pattern.hasSuffix("/") { pattern += "**" }
        guard let regex = try? NSRegularExpression(pattern: "^" + (anchored ? "" : "(?:.*/)?") + translate(pattern) + "(?:/.*)?$") else { return false }
        return regex.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)) != nil
    }

    /// Whether a relative path passes the include and exclude lists.
    public static func allows(_ path: String, include: [String], exclude: [String]) -> Bool {
        if !include.isEmpty, !include.contains(where: { matches($0, path) }) { return false }
        return !exclude.contains { matches($0, path) }
    }

    private static func translate(_ glob: String) -> String {
        var out = ""
        var chars = Array(glob)[...]
        var braces = 0
        while let c = chars.popFirst() {
            switch c {
            case "*":
                if chars.first == "*" {
                    chars.removeFirst()
                    if chars.first == "/" { chars.removeFirst(); out += "(?:.*/)?" } else { out += ".*" }
                } else {
                    out += "[^/]*"
                }
            case "?": out += "[^/]"
            case "{" where chars.contains("}"): out += "(?:"; braces += 1
            case "}" where braces > 0: out += ")"; braces -= 1
            case "," where braces > 0: out += "|"
            case "\\":
                if let next = chars.popFirst() { out += NSRegularExpression.escapedPattern(for: String(next)) }
                else { out += "\\\\" }
            case "[":
                if let close = chars.firstIndex(of: "]") {
                    var set = String(chars[chars.startIndex..<close])
                    if set.hasPrefix("!") { set = "^" + set.dropFirst() }
                    out += "[" + set.replacingOccurrences(of: "\\", with: "\\\\") + "]"
                    chars = chars[chars.index(after: close)...]
                } else {
                    out += "\\["
                }
            default: out += NSRegularExpression.escapedPattern(for: String(c))
            }
        }
        return out
    }
}

/// Searches text held in memory (an editor tab with unsaved edits) the way
/// ripgrep searches files: literal, per line, case and whole-word options.
public enum TextSearch {
    public static func hits(in text: String, path: String, options: SearchOptions) -> [SearchHit] {
        guard !options.query.isEmpty else { return [] }
        var hits: [SearchHit] = []
        var number = 0
        text.enumerateLines { line, _ in
            number += 1
            let ns = line as NSString
            var ranges: [Range<Int>] = []
            var start = 0
            while start <= ns.length {
                let found = ns.range(of: options.query, options: options.caseSensitive ? [.literal] : [.literal, .caseInsensitive],
                                     range: NSRange(location: start, length: ns.length - start))
                guard found.location != NSNotFound, found.length > 0 else { break }
                if !options.wholeWord || isWholeWord(ns, found) { ranges.append(found.location..<(found.location + found.length)) }
                start = found.location + max(found.length, 1)
            }
            if !ranges.isEmpty { hits.append(SearchHit(path: path, line: number, text: line, ranges: ranges)) }
        }
        return hits
    }

    private static func isWholeWord(_ line: NSString, _ range: NSRange) -> Bool {
        func isWord(_ index: Int) -> Bool {
            guard index >= 0, index < line.length, let scalar = UnicodeScalar(line.character(at: index)) else { return false }
            return CharacterSet.alphanumerics.contains(scalar) || scalar == "_"
        }
        return !isWord(range.location - 1) && !isWord(range.location + range.length)
    }
}

/// Why a search stopped early or found nothing usable.
public enum SearchError: Error, Equatable, LocalizedError {
    /// No ripgrep on the device (or bundled with the app).
    case ripgrepMissing
    case folderMissing
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .ripgrepMissing: return "ripgrep isn't available."
        case .folderMissing: return "The space's folder can't be opened."
        case let .failed(reason): return reason
        }
    }
}

public struct SearchLimits: Equatable, Sendable {
    public var matches = 1_000
    public var bytes = 5 << 20
    public var deadline: Duration = .seconds(10)
    public init(matches: Int = 1_000, bytes: Int = 5 << 20, deadline: Duration = .seconds(10)) {
        self.matches = matches; self.bytes = bytes; self.deadline = deadline
    }
}

public struct SearchOutcome: Equatable, Sendable {
    public var hits: [SearchHit] = []
    /// Set when a limit stopped the search: "1,000 matches", "5 MB of results" or "10 seconds".
    public var stoppedAt: String?
    /// Folders or files ripgrep couldn't read.
    public var problems: [String] = []
    public init(hits: [SearchHit] = [], stoppedAt: String? = nil, problems: [String] = []) {
        self.hits = hits; self.stoppedAt = stoppedAt; self.problems = problems
    }
}

/// Runs ripgrep in the space's folder, on this Mac or over SSH.
public enum ContentSearch {
    /// Args: ripgrep's path ("" to look for it), the space folder, then
    /// ripgrep's own arguments. On a device, a copy installed by uHerdr in
    /// ~/.local/share/uherdr/bin is used when there is no rg on PATH.
    static let findRipgrep = #"""
    r=$1; shift
    cd "$1" 2>/dev/null || exit 21
    shift
    if [ -z "$r" ]; then
      r=$(command -v rg 2>/dev/null)
      [ -z "$r" ] && [ -x "$HOME/.local/share/uherdr/bin/rg" ] && r="$HOME/.local/share/uherdr/bin/rg"
    fi
    [ -n "$r" ] || exit 30
    """#

    /// For quick runs (the file list).
    static let script = findRipgrep + "\n" + #"exec "$r" "$@""#

    /// For searches, which may run long: ripgrep runs in the background while
    /// the script reads stdin, held open by uHerdr. When uHerdr stops the
    /// search (or goes away), stdin ends and ripgrep is stopped. Over SSH this
    /// is the only signal the device gets: a closed session sends no hangup
    /// to a job without a terminal.
    static let watchedScript = findRipgrep + "\n" + #"""
    exec 3<&0
    "$r" "$@" </dev/null &
    p=$!
    ( while read -r _ <&3; do :; done; kill -TERM "$p" 2>/dev/null ) &
    w=$!
    wait "$p"; s=$?
    kill "$w" 2>/dev/null
    exit "$s"
    """#

    /// ripgrep on this Mac: the copy bundled with the app, then Homebrew's.
    public static func localRipgrep(bundle: Bundle = .main) -> String? {
        let candidates: [String?] = [bundle.resourceURL?.appendingPathComponent("ripgrep/rg").path, "/opt/homebrew/bin/rg", "/usr/local/bin/rg"]
        return candidates.compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public static func search(_ options: SearchOptions, root: String, runner: ScriptRunner, ripgrep: String? = nil,
                              limits: SearchLimits = SearchLimits()) async throws -> SearchOutcome {
        var outcome = SearchOutcome()
        guard !options.query.isEmpty else { return outcome }
        let events = try runner.events(watchedScript, [ripgrep ?? "", root] + options.ripgrepArguments,
                                       maxBytes: limits.bytes, timeout: limits.deadline)
        var buffer = Data()
        var matches = 0
        do {
            reading: for try await event in events {
                switch event {
                case let .output(data):
                    buffer.append(data)
                    while let newline = buffer.firstIndex(of: 10) {
                        let line = buffer[buffer.startIndex..<newline]
                        buffer = Data(buffer[buffer.index(after: newline)...])
                        if case let .match(hit)? = RipgrepJSON.decode(Data(line)),
                           Glob.allows(hit.path, include: options.includeGlobs, exclude: []) {
                            outcome.hits.append(hit)
                            matches += hit.ranges.count
                            if matches >= limits.matches {
                                outcome.stoppedAt = "\(limits.matches.formatted()) matches"
                                break reading // ending the stream stops ripgrep
                            }
                        }
                    }
                case let .exit(status, stderr):
                    switch status {
                    case 0, 1: break // matches, or none
                    case 2: outcome.problems = RipgrepJSON.problems(stderr) // some paths unreadable
                    case 21: throw SearchError.folderMissing
                    case 30, 127: throw SearchError.ripgrepMissing
                    default:
                        let reason = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                        throw SearchError.failed(reason.isEmpty ? "ripgrep exited with status \(status)" : reason)
                    }
                }
            }
        } catch let failure as StreamingProcess.Failure {
            switch failure {
            case .tooMuchOutput: outcome.stoppedAt = "\(ByteCountFormatter.string(fromByteCount: Int64(limits.bytes), countStyle: .file)) of results"
            case .timedOut: outcome.stoppedAt = "\(limits.deadline.components.seconds) seconds"
            default: throw SearchError.failed(failure.localizedDescription)
            }
        }
        return outcome
    }

    /// Replaces disk hits of files open with unsaved edits by hits in their
    /// current text. `unsaved` maps relative paths to text.
    public static func merging(_ outcome: SearchOutcome, unsaved: [String: String], options: SearchOptions) -> SearchOutcome {
        guard !unsaved.isEmpty else { return outcome }
        var merged = outcome
        merged.hits.removeAll { unsaved[$0.path] != nil }
        for (path, text) in unsaved.sorted(by: { $0.key < $1.key })
        where Glob.allows(path, include: options.includeGlobs, exclude: options.excludeGlobs) {
            merged.hits += TextSearch.hits(in: text, path: path, options: options)
        }
        return merged
    }
}

/// Quick Open's file list: every file ripgrep would search (ignore rules
/// respected, no hidden files), or Git's list when there is no ripgrep.
public enum FileList {
    static let gitScript = GitChangesReader.preamble + "\n" + #"""
    cd "$1" 2>/dev/null || exit 21
    exec git --no-pager -c core.quotepath=false ls-files -z --cached --others --exclude-standard
    """#

    public static func files(root: String, runner: ScriptRunner, ripgrep: String? = nil, limit: Int = 200_000) async throws -> [String] {
        let result = try await runner.run(ContentSearch.script, [ripgrep ?? "", root, "--files", "-0", "--no-config"],
                                          maxBytes: 64 << 20, timeout: .seconds(20))
        switch result.status {
        case 0, 2: return paths(result.stdout, limit: limit)
        case 21: throw SearchError.folderMissing
        case 30, 127:
            let git = try await runner.run(gitScript, [root], maxBytes: 64 << 20, timeout: .seconds(20))
            guard git.status == 0 else { throw SearchError.ripgrepMissing }
            return paths(git.stdout, limit: limit)
        default:
            let reason = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw SearchError.failed(reason.isEmpty ? "ripgrep exited with status \(result.status)" : reason)
        }
    }

    static func paths(_ data: Data, limit: Int) -> [String] {
        data.split(separator: 0).prefix(limit).map { bytes in
            var path = String(decoding: bytes, as: UTF8.self)
            if path.hasPrefix("./") { path.removeFirst(2) }
            return path
        }
    }
}
