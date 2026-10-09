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
    /// Type filters narrow the files read without overriding ignore rules, as
    /// positive --glob would. Full path globs are still checked on results.
    public var ripgrepArguments: [String] {
        var args = ["--json", "--no-config", "--fixed-strings", caseSensitive ? "--case-sensitive" : "--ignore-case"]
        if wholeWord { args.append("--word-regexp") }
        if !includeGlobs.isEmpty {
            args.append("--hidden")
            for glob in includeGlobs {
                let name = glob.hasSuffix("/") ? "*" : (glob as NSString).lastPathComponent
                args += ["--type-add", "uherdrinclude:" + name]
            }
            args += ["--type", "uherdrinclude", "--glob", "!.git"]
        }
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
    private static func expression(_ pattern: String) -> NSRegularExpression? {
        var pattern = pattern
        let anchored = pattern.dropLast().contains("/")
        if pattern.hasPrefix("/") { pattern.removeFirst() }
        if pattern.hasSuffix("/") { pattern += "**" }
        return try? NSRegularExpression(pattern: "^" + (anchored ? "" : "(?:.*/)?") + translate(pattern) + "(?:/.*)?$")
    }

    public static func matches(_ pattern: String, _ path: String) -> Bool {
        expression(pattern)?.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)) != nil
    }

    /// Compile once per search, rather than once per returned hit.
    public struct Filter {
        private let includes: [NSRegularExpression]
        private let excludes: [NSRegularExpression]
        private let hasIncludes: Bool
        public init(include: [String], exclude: [String]) {
            hasIncludes = !include.isEmpty
            includes = include.compactMap { Glob.expression($0) }
            excludes = exclude.compactMap { Glob.expression($0) }
        }
        public func allows(_ path: String) -> Bool {
            let range = NSRange(path.startIndex..., in: path)
            return (!hasIncludes || includes.contains { $0.firstMatch(in: path, range: range) != nil })
                && !excludes.contains { $0.firstMatch(in: path, range: range) != nil }
        }
    }

    /// Whether a relative path passes the include and exclude lists.
    public static func allows(_ path: String, include: [String], exclude: [String]) -> Bool {
        Filter(include: include, exclude: exclude).allows(path)
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
        let budget = SearchBudget(limits: SearchLimits(), isCancelled: { false })
        return hits(in: text, path: path, options: options, budget: budget)
    }

    fileprivate static func hits(in text: String, path: String, options: SearchOptions, budget: SearchBudget) -> [SearchHit] {
        guard !options.query.isEmpty else { return [] }
        var hits: [SearchHit] = []
        var number = 0
        text.enumerateLines { line, stop in
            guard budget.check() else { stop = true; return }
            number += 1
            let bytes = line.utf8.count + 1
            guard bytes <= budget.scanBytes else { budget.stoppedAt = budget.byteNotice + " of searched text"; stop = true; return }
            budget.scanBytes -= bytes
            let ns = line as NSString
            var ranges: [Range<Int>] = []
            var start = 0
            while start <= ns.length {
                guard budget.check() else { stop = true; return }
                let found = ns.range(of: options.query, options: options.caseSensitive ? [.literal] : [.literal, .caseInsensitive],
                                     range: NSRange(location: start, length: ns.length - start))
                guard found.location != NSNotFound, found.length > 0 else { break }
                if !options.wholeWord || isWholeWord(ns, found) {
                    ranges.append(found.location..<(found.location + found.length))
                    if ranges.count >= budget.matches { break }
                }
                start = found.location + max(found.length, 1)
            }
            if !ranges.isEmpty, let hit = budget.take(SearchHit(path: path, line: number, text: line, ranges: ranges)) { hits.append(hit) }
            if !budget.check() { stop = true }
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
        let filter = Glob.Filter(include: options.includeGlobs, exclude: [])
        var matches = 0
        do {
            reading: for try await event in events {
                switch event {
                case let .output(data):
                    buffer.append(data)
                    var cursor = buffer.startIndex
                    while let newline = buffer[cursor...].firstIndex(of: 10) {
                        let line = buffer[cursor..<newline]
                        cursor = buffer.index(after: newline)
                        if case let .match(hit)? = RipgrepJSON.decode(Data(line)),
                           filter.allows(hit.path) {
                            let ranges = Array(hit.ranges.prefix(max(0, limits.matches - matches)))
                            outcome.hits.append(SearchHit(path: hit.path, line: hit.line, text: hit.text, ranges: ranges))
                            matches += ranges.count
                            if matches >= limits.matches {
                                outcome.stoppedAt = "\(limits.matches.formatted()) matches"
                                break reading // ending the stream stops ripgrep
                            }
                        }
                    }
                    if cursor != buffer.startIndex { buffer = Data(buffer[cursor...]) }
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
    public static func merging(_ outcome: SearchOutcome, unsaved: [String: String], options: SearchOptions,
                               limits: SearchLimits = SearchLimits(), isCancelled: @escaping () -> Bool = { false }) -> SearchOutcome {
        let budget = SearchBudget(limits: limits, isCancelled: isCancelled)
        var merged = SearchOutcome(stoppedAt: outcome.stoppedAt, problems: outcome.problems)
        for hit in outcome.hits where unsaved[hit.path] == nil {
            guard budget.check(), let bounded = budget.take(hit) else { break }
            merged.hits.append(bounded)
        }
        let filter = Glob.Filter(include: options.includeGlobs, exclude: options.excludeGlobs)
        for (path, text) in unsaved.sorted(by: { $0.key < $1.key }) {
            guard budget.check() else { break }
            if filter.allows(path) {
                merged.hits += TextSearch.hits(in: text, path: path, options: options, budget: budget)
            }
        }
        merged.stoppedAt = budget.stoppedAt ?? merged.stoppedAt
        return merged
    }
}

/// One budget shared by disk results and all dirty buffers. The scanned-byte
/// budget also bounds work when dirty text contains no matches.
fileprivate final class SearchBudget {
    let limits: SearchLimits
    let end: ContinuousClock.Instant
    let isCancelled: () -> Bool
    var matches: Int
    var bytes: Int
    var scanBytes: Int
    var stoppedAt: String?
    var byteNotice: String { ByteCountFormatter.string(fromByteCount: Int64(limits.bytes), countStyle: .file) }
    init(limits: SearchLimits, isCancelled: @escaping () -> Bool) {
        self.limits = limits; self.isCancelled = isCancelled
        end = ContinuousClock.now.advanced(by: limits.deadline)
        matches = max(0, limits.matches); bytes = max(0, limits.bytes); scanBytes = max(0, limits.bytes)
    }
    func check() -> Bool {
        if isCancelled() { return false }
        if stoppedAt != nil { return false }
        if ContinuousClock.now >= end { stoppedAt = "\(limits.deadline.components.seconds) seconds"; return false }
        if matches == 0 { stoppedAt = "\(limits.matches.formatted()) matches"; return false }
        return true
    }
    func take(_ hit: SearchHit) -> SearchHit? {
        guard check() else { return nil }
        let ranges = Array(hit.ranges.prefix(matches))
        let cost = hit.text.utf8.count + hit.path.utf8.count + ranges.count * MemoryLayout<Range<Int>>.stride
        guard cost <= bytes else { stoppedAt = byteNotice + " of results"; return nil }
        bytes -= cost; matches -= ranges.count
        return SearchHit(path: hit.path, line: hit.line, text: hit.text, ranges: ranges)
    }
}

/// Quick Open's file list: every file ripgrep would search (ignore rules
/// respected, no hidden files), or Git's list when there is no ripgrep.
public enum FileList {
    static let gitScript = GitChangesReader.preamble + "\n" + #"""
    cd "$1" 2>/dev/null || exit 21
    exec git --no-pager -c core.quotepath=false ls-files -z --cached --others --exclude-standard
    """#

    public static func files(root: String, runner: ScriptRunner, ripgrep: String? = nil, limit: Int = 200_000,
                             outputLimit: Int = 64 << 20) async throws -> [String] {
        guard limit > 0 else { return [] }
        let result = try await listing(ContentSearch.watchedScript, args: [ripgrep ?? "", root, "--files", "-0", "--no-config"],
                                       runner: runner, limit: limit, outputLimit: outputLimit)
        switch result.status {
        case 0, 1, 2: return result.paths
        case 21: throw SearchError.folderMissing
        case 30, 127:
            let git = try await listing(gitScript, args: [root], runner: runner, limit: limit, outputLimit: outputLimit)
            guard git.status == 0 else { throw SearchError.ripgrepMissing }
            return git.paths
        default:
            let reason = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw SearchError.failed(reason.isEmpty ? "ripgrep exited with status \(result.status)" : reason)
        }
    }

    private static func listing(_ script: String, args: [String], runner: ScriptRunner, limit: Int,
                                outputLimit: Int) async throws -> (paths: [String], status: Int32, stderr: String) {
        var paths: [String] = [], pending = Data()
        var received = 0
        let events = try runner.events(script, args, maxBytes: Int.max, timeout: .seconds(20))
        for try await event in events {
            try Task.checkCancellation()
            switch event {
            case let .output(chunk):
                let count = min(chunk.count, max(0, outputLimit - received))
                for byte in chunk.prefix(count) {
                    if byte == 0 {
                        var path = String(decoding: pending, as: UTF8.self)
                        if path.hasPrefix("./") { path.removeFirst(2) }
                        if !path.isEmpty, !path.split(separator: "/").contains(where: { $0.hasPrefix(".") }) { paths.append(path) }
                        pending.removeAll(keepingCapacity: true)
                        if paths.count >= limit { return (paths, 0, "") }
                    } else {
                        // No supported filesystem has a 16 KiB relative name.
                        guard pending.count < 16_384 else { return (paths, 0, "") }
                        pending.append(byte)
                    }
                }
                received += count
                if received >= outputLimit { return (paths, 0, "") }
            case let .exit(status, stderr): return (paths, status, stderr)
            }
        }
        return (paths, 0, "")
    }

    static func paths(_ data: Data, limit: Int) -> [String] {
        data.split(separator: 0).prefix(limit).map { bytes in
            var path = String(decoding: bytes, as: UTF8.self)
            if path.hasPrefix("./") { path.removeFirst(2) }
            return path
        }
    }
}
