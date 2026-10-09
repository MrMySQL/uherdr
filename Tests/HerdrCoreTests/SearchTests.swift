import Foundation
import HerdrCore

enum SearchTests {
    static func run() async throws {
        fuzzy()
        try decoding()
        globs()
        textSearch()
        dirtyLimits()
        try await boundedBatch()
        try await ripgrep()
        links()
        print("PASS: search: fuzzy ranking, rg JSON (text, bytes, UTF-16 offsets), problems, globs, in-memory search, ripgrep here and over SSH with limits, unsaved merge, file lists with Git fallback")
    }

    static func fuzzy() {
        let paths = ["Sources/HerdrMac/SessionStore.swift", "Sources/HerdrCore/SessionControl.swift", "Tests/HerdrCoreTests/SessionControlTests.swift",
                     "Vendor/GhosttyTerminal/Sources/InMemoryTerminalSession.swift", "docs/session-notes.md", "Sources/HerdrMac/WorkspaceView.swift"]
        let ranked = FuzzyMatcher.rank("session", paths)
        XCTAssertEqual(ranked.count, 5)
        XCTAssertTrue(ranked.prefix(4).allSatisfy { ($0.path as NSString).lastPathComponent.lowercased().hasPrefix("session") })
        XCTAssertEqual(ranked.last?.path, "Vendor/GhosttyTerminal/Sources/InMemoryTerminalSession.swift")
        // Word starts: "ss" picks the S of Session and the S of Store.
        let store = FuzzyMatcher.match("ss", "Sources/HerdrMac/SessionStore.swift")!
        XCTAssertEqual(store.positions, [17, 24])
        XCTAssertTrue(FuzzyMatcher.match("xyz", "Sources/a.swift") == nil)
        XCTAssertTrue(FuzzyMatcher.match("wsv", "Sources/HerdrMac/WorkspaceView.swift") != nil)
        // Open files first: always for an empty query, among equal scores otherwise.
        XCTAssertEqual(FuzzyMatcher.rank("", ["b.swift", "a.swift"], open: ["b.swift"]).map(\.path), ["b.swift", "a.swift"])
        // An empty query lists open files first even when they would sort later.
        XCTAssertEqual(FuzzyMatcher.rank("", ["a.swift", "zzzzzzzzzz/long/b.swift"], open: ["zzzzzzzzzz/long/b.swift"]).map(\.path),
                       ["zzzzzzzzzz/long/b.swift", "a.swift"])
        // A match in the file name beats the same match in a folder.
        XCTAssertEqual(FuzzyMatcher.rank("mac", ["aamac/x.swift", "z/xmac.swift"]).map(\.path), ["z/xmac.swift", "aamac/x.swift"])
        // A match at the start of the name beats one at a later word start.
        XCTAssertEqual(FuzzyMatcher.rank("ses", ["a/x_session.swift", "z/session.swift"]).map(\.path), ["z/session.swift", "a/x_session.swift"])
        XCTAssertEqual(FuzzyMatcher.rank("a", ["x/a.swift", "y/a.swift"], open: ["y/a.swift"]).map(\.path), ["y/a.swift", "x/a.swift"])
        XCTAssertEqual(FuzzyMatcher.rank("", (0..<100).map { "f\($0)" }, limit: 7).count, 7)
        XCTAssertEqual(FuzzyMatcher.rank("a", ["a", "ba", "ca"], limit: 1), Array(FuzzyMatcher.rank("a", ["a", "ba", "ca"], limit: 20).prefix(1)))
        XCTAssertEqual(FuzzyMatcher.rank("", ["a"], limit: 0), [])
        XCTAssertEqual(FuzzyMatcher.rank("", ["a"], isCancelled: { true }), [])
        let candidates = (0..<300).map { "folder\($0 % 7)/a\($0).swift" }
        let reference = candidates.compactMap { FuzzyMatcher.match("as", $0) }.sorted {
            $0.score != $1.score ? $0.score > $1.score : $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
        XCTAssertEqual(FuzzyMatcher.rank("as", candidates, limit: 7), Array(reference.prefix(7)))
        // Characters whose lowercase form is longer don't shift offsets.
        XCTAssertEqual(FuzzyMatcher.match("x", "İx")?.positions, [1])
    }

    static func decoding() throws {
        // Recorded from ripgrep 15.2.0.
        let lines = [
            #"{"type":"begin","data":{"path":{"text":"./a.swift"}}}"#,
            #"{"type":"match","data":{"path":{"text":"./a.swift"},"lines":{"text":"print(selectedSpace, selectedSpace)\n"},"line_number":3,"absolute_offset":25,"submatches":[{"match":{"text":"selectedSpace"},"start":6,"end":19},{"match":{"text":"selectedSpace"},"start":21,"end":34}]}}"#,
            #"{"type":"match","data":{"path":{"text":"./sub/latin1.txt"},"lines":{"bytes":"Y2Fm6SBzZWxlY3RlZFNwYWNlCg=="},"line_number":1,"absolute_offset":0,"submatches":[{"match":{"text":"selectedSpace"},"start":5,"end":18}]}}"#,
            #"{"type":"match","data":{"path":{"text":"./sub/u.txt"},"lines":{"text":"ünï selectedSpace 🎉\r\n"},"line_number":1,"absolute_offset":0,"submatches":[{"match":{"text":"selectedSpace"},"start":6,"end":19}]}}"#,
            #"{"data":{"elapsed_total":{"human":"0.008720s","nanos":8720042,"secs":0},"stats":{"matches":5}},"type":"summary"}"#,
        ].map { Data($0.utf8) }
        XCTAssertEqual(RipgrepJSON.decode(lines[0]), .other)
        XCTAssertEqual(RipgrepJSON.decode(lines[1]), .match(SearchHit(path: "a.swift", line: 3, text: "print(selectedSpace, selectedSpace)", ranges: [6..<19, 21..<34])))
        XCTAssertEqual(RipgrepJSON.decode(lines[2]), .match(SearchHit(path: "sub/latin1.txt", line: 1, text: "caf\u{FFFD} selectedSpace", ranges: [5..<18])))
        XCTAssertEqual(RipgrepJSON.decode(lines[3]), .match(SearchHit(path: "sub/u.txt", line: 1, text: "ünï selectedSpace 🎉", ranges: [4..<17])))
        XCTAssertEqual(RipgrepJSON.decode(lines[4]), .other)
        XCTAssertTrue(RipgrepJSON.decode(Data("not json".utf8)) == nil)
        XCTAssertTrue(RipgrepJSON.decode(Data(repeating: 32, count: RipgrepJSON.recordLimit + 1)) == nil)
        XCTAssertEqual(RipgrepJSON.problems("rg: ./locked: Permission denied (os error 13)\nrg: ./a/b: No such file or directory (os error 2)\nnoise\n"),
                       ["locked: no permission", "a/b: No such file or directory (os error 2)"])
    }

    static func globs() {
        XCTAssertEqual(SearchOptions(query: "x", include: "**/*.{swift,m}, docs/**").includeGlobs, ["**/*.{swift,m}", "docs/**"])
        XCTAssertTrue(Glob.matches("**/*.{swift,m}", "Sources/a.swift"))
        XCTAssertTrue(Glob.matches("**/*.{swift,m}", "a.m"))
        XCTAssertTrue(!Glob.matches("**/*.{swift,m}", "a.md"))
        XCTAssertTrue(Glob.matches("*.swift", "Sources/HerdrMac/A.swift"))
        XCTAssertTrue(!Glob.matches("*.swift", "Sources/A.swiftx"))
        XCTAssertTrue(Glob.matches("Sources/**/*.swift", "Sources/A.swift"))
        XCTAssertTrue(Glob.matches("Sources/**/*.swift", "Sources/x/y/A.swift"))
        XCTAssertTrue(!Glob.matches("Sources/**/*.swift", "Tests/Sources/A.swift"))
        XCTAssertTrue(Glob.matches("Vendor", "Vendor/a/b.c") && Glob.matches("Vendor/**", "Vendor/a/b.c") && Glob.matches("Vendor/", "Vendor/x"))
        XCTAssertTrue(Glob.matches("node_modules", "web/node_modules/x.js"))
        XCTAssertTrue(Glob.matches("a?c.txt", "abc.txt") && !Glob.matches("a?c.txt", "a/c.txt"))
        XCTAssertTrue(Glob.matches("[ab].md", "b.md") && !Glob.matches("[!ab].md", "b.md") && Glob.matches("[!ab].md", "c.md"))
        XCTAssertTrue(Glob.matches("a+b(1).txt", "a+b(1).txt"))
        XCTAssertTrue(Glob.allows("Sources/A.swift", include: ["*.swift"], exclude: []))
        XCTAssertTrue(!Glob.allows("Sources/A.md", include: ["*.swift"], exclude: []))
        XCTAssertTrue(!Glob.allows("Vendor/A.swift", include: ["*.swift"], exclude: ["Vendor/**"]))
        XCTAssertEqual(SearchOptions(query: "q", include: " *.swift, ,docs/** ", exclude: "Vendor").ripgrepArguments,
                       ["--json", "--no-config", "--fixed-strings", "--ignore-case", "--hidden", "--type-add", "uherdrinclude:*.swift", "--type-add", "uherdrinclude:**", "--type", "uherdrinclude", "--glob", "!.git", "--glob", "!Vendor", "--", "q", "."])
        let filter = Glob.Filter(include: ["**/*.{swift,m}"], exclude: ["Vendor/**"])
        XCTAssertTrue(filter.allows("Sources/a.swift") && !filter.allows("Vendor/a.swift") && !filter.allows("a.md"))
        XCTAssertEqual(SearchOptions(query: "-e", caseSensitive: true, wholeWord: true).ripgrepArguments,
                       ["--json", "--no-config", "--fixed-strings", "--case-sensitive", "--word-regexp", "--", "-e", "."])
    }

    static func textSearch() {
        let text = "let space = Space()\r\nspaces.forEach { space in }\nnone\n"
        let any = TextSearch.hits(in: text, path: "a.swift", options: SearchOptions(query: "space"))
        XCTAssertEqual(any, [SearchHit(path: "a.swift", line: 1, text: "let space = Space()", ranges: [4..<9, 12..<17]),
                             SearchHit(path: "a.swift", line: 2, text: "spaces.forEach { space in }", ranges: [0..<5, 17..<22])])
        XCTAssertEqual(TextSearch.hits(in: text, path: "a", options: SearchOptions(query: "Space", caseSensitive: true)).map(\.ranges), [[12..<17]])
        XCTAssertEqual(TextSearch.hits(in: text, path: "a", options: SearchOptions(query: "space", wholeWord: true)).map(\.ranges), [[4..<9, 12..<17], [17..<22]])
        XCTAssertEqual(TextSearch.hits(in: "🎉 aa aa", path: "a", options: SearchOptions(query: "aa")).map(\.ranges), [[3..<5, 6..<8]])
        XCTAssertEqual(TextSearch.hits(in: "x", path: "a", options: SearchOptions(query: "")), [])
    }

    static func dirtyLimits() {
        let options = SearchOptions(query: "x")
        let many = ["a": String(repeating: "x ", count: 10_000), "b": String(repeating: "x\n", count: 10_000)]
        let limited = ContentSearch.merging(SearchOutcome(), unsaved: many, options: options, limits: SearchLimits(matches: 3))
        XCTAssertEqual(limited.hits.reduce(0) { $0 + $1.ranges.count }, 3)
        XCTAssertEqual(limited.stoppedAt, "3 matches")
        let disk = SearchOutcome(hits: [SearchHit(path: "disk", line: 1, text: "x x", ranges: [0..<1, 2..<3])])
        let global = ContentSearch.merging(disk, unsaved: ["a": "x x"], options: options, limits: SearchLimits(matches: 3))
        XCTAssertEqual(global.hits.reduce(0) { $0 + $1.ranges.count }, 3)
        let bytes = ContentSearch.merging(SearchOutcome(), unsaved: ["a": String(repeating: "none\n", count: 100)], options: options, limits: SearchLimits(bytes: 20))
        XCTAssertTrue(bytes.stoppedAt?.contains("searched text") == true)
        let output = ContentSearch.merging(SearchOutcome(), unsaved: [String(repeating: "p", count: 100): "x"], options: options, limits: SearchLimits(bytes: 20))
        XCTAssertTrue(output.hits.isEmpty && output.stoppedAt?.contains("of results") == true)
        let timed = ContentSearch.merging(SearchOutcome(), unsaved: many, options: options, limits: SearchLimits(deadline: .zero))
        XCTAssertTrue(timed.hits.isEmpty && timed.stoppedAt?.contains("seconds") == true)
        let cancelled = ContentSearch.merging(SearchOutcome(), unsaved: many, options: options, isCancelled: { true })
        XCTAssertTrue(cancelled.hits.isEmpty)
    }

    static func boundedBatch() async throws {
        let root = NSTemporaryDirectory() + "search-batch-" + UUID().uuidString
        let fm = FileManager.default
        try fm.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: root) }
        let record = #"{"type":"match","data":{"path":{"text":"./a.swift"},"lines":{"text":"print(selectedSpace, selectedSpace)\n"},"line_number":3,"absolute_offset":25,"submatches":[{"match":{"text":"selectedSpace"},"start":6,"end":19},{"match":{"text":"selectedSpace"},"start":21,"end":34}]}}"#
        try Data(String(repeating: record + "\n", count: 500).utf8).write(to: URL(fileURLWithPath: root + "/records"))
        let tool = root + "/rg"
        fm.createFile(atPath: tool, contents: Data(("#!/bin/sh\ncat " + RemoteShell.quote(root + "/records") + "\n").utf8), attributes: [.posixPermissions: 0o755])
        let result = try await ContentSearch.search(SearchOptions(query: "selectedSpace"), root: root, runner: .local, ripgrep: tool)
        XCTAssertEqual(result.hits.count, 500)
        XCTAssertEqual(result.hits.reduce(0) { $0 + $1.ranges.count }, 1_000)
        let limited = try await ContentSearch.search(SearchOptions(query: "selectedSpace"), root: root, runner: .local, ripgrep: tool, limits: SearchLimits(matches: 3))
        XCTAssertEqual(limited.hits.reduce(0) { $0 + $1.ranges.count }, 3)
        XCTAssertEqual(limited.stoppedAt, "3 matches")
    }

    static func ripgrep() async throws {
        guard let rg = ContentSearch.localRipgrep() else { print("SKIP: ripgrep searches (no rg on this Mac)"); return }
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../Fixtures/ssh-shell-fixture.py").standardized.path
        let fm = FileManager.default
        let root = PathBoundary.canonical(NSTemporaryDirectory())! + "/uherdr-search-\(UUID().uuidString)"
        defer { chmod(root + "/locked", 0o755); try? fm.removeItem(atPath: root) }
        for folder in ["Sources/deep", "Vendor", "locked"] { try fm.createDirectory(atPath: root + "/" + folder, withIntermediateDirectories: true) }
        func write(_ path: String, _ text: String) { fm.createFile(atPath: root + "/" + path, contents: Data(text.utf8)) }
        write("Sources/a.swift", "let selectedSpace = 1\nprint(selectedSpace, selectedSpace)\n")
        write("Sources/deep/it's $(touch PWNED).swift", "selectedSpace\n")
        write("Vendor/v.swift", "selectedSpace\n")
        write("notes.md", "SelectedSpace in docs\nselectedSpaces plural\n")
        write("locked/l.swift", "selectedSpace\n")
        write(".hidden.swift", "selectedSpace\n")
        chmod(root + "/locked", 0o000)
        let profile = DeviceProfile(name: "Fixture box", kind: .ssh, host: "dev-box", executable: "/tmp/herdr")
        let base = ProcessInfo.processInfo.environment
        let remote = ScriptRunner.remote(RemoteShell(profile: profile, ssh: fixture,
            environment: base.merging(["PATH": (rg as NSString).deletingLastPathComponent + ":" + (base["PATH"] ?? "/usr/bin:/bin")]) { $1 }))

        for (name, runner, path) in [("local", ScriptRunner.local, rg), ("ssh", remote, nil as String?)] {
            let all = try await ContentSearch.search(SearchOptions(query: "selectedspace"), root: root, runner: runner, ripgrep: path)
            XCTAssertEqual(Set(all.hits.map(\.path)), ["Sources/a.swift", "Sources/deep/it's $(touch PWNED).swift", "Vendor/v.swift", "notes.md"])
            XCTAssertEqual(all.hits.reduce(0) { $0 + $1.ranges.count }, 7)
            XCTAssertEqual(all.problems, ["locked: no permission"])
            XCTAssertTrue(all.stoppedAt == nil)
            XCTAssertTrue(!fm.fileExists(atPath: root + "/PWNED"))
            let exact = try await ContentSearch.search(SearchOptions(query: "selectedSpace", caseSensitive: true, wholeWord: true, include: "*.swift", exclude: "Vendor"),
                                                       root: root, runner: runner, ripgrep: path)
            XCTAssertEqual(Set(exact.hits.map(\.path)), ["Sources/a.swift", "Sources/deep/it's $(touch PWNED).swift", ".hidden.swift"])
            let hidden = try await ContentSearch.search(SearchOptions(query: "selectedSpace", include: ".hidden.swift"), root: root, runner: runner, ripgrep: path)
            XCTAssertEqual(hidden.hits.map(\.path), [".hidden.swift"])
            write(".ignore", "Vendor/\n")
            let ignored = try await ContentSearch.search(SearchOptions(query: "selectedSpace", include: "Vendor/**"), root: root, runner: runner, ripgrep: path)
            XCTAssertTrue(ignored.hits.isEmpty)
            try fm.removeItem(atPath: root + "/.ignore")
            // A query that looks like an option is still text.
            let dash = try await ContentSearch.search(SearchOptions(query: "--files"), root: root, runner: runner, ripgrep: path)
            XCTAssertEqual(dash.hits, [])
            let limited = try await ContentSearch.search(SearchOptions(query: "selected"), root: root, runner: runner, ripgrep: path, limits: SearchLimits(matches: 2))
            XCTAssertEqual(limited.stoppedAt, "2 matches")
            let limitedCount = limited.hits.reduce(0) { $0 + $1.ranges.count }
            XCTAssertEqual(limitedCount, 2) // reading stopped at the limit
            let bytes = try await ContentSearch.search(SearchOptions(query: "selected"), root: root, runner: runner, ripgrep: path, limits: SearchLimits(bytes: 300))
            XCTAssertTrue(bytes.stoppedAt?.hasSuffix("of results") == true)
            do {
                _ = try await ContentSearch.search(SearchOptions(query: "x"), root: root + "/missing", runner: runner, ripgrep: path)
                preconditionFailure("expected a missing folder")
            } catch let error as SearchError { XCTAssertEqual(error, .folderMissing) }

            let files = try await FileList.files(root: root, runner: runner, ripgrep: path)
            XCTAssertEqual(Set(files), ["Sources/a.swift", "Sources/deep/it's $(touch PWNED).swift", "Vendor/v.swift", "notes.md"])
        }

        let listingTool = root + "-listing.sh"
        fm.createFile(atPath: listingTool, contents: Data("#!/bin/sh\nprintf 'first\\000second\\000.hidden\\000fourth\\000fifth\\000'\n".utf8), attributes: [.posixPermissions: 0o755])
        defer { try? fm.removeItem(atPath: listingTool) }
        let truncated = try await FileList.files(root: root, runner: .local, ripgrep: listingTool, outputLimit: 15)
        XCTAssertEqual(truncated, ["first", "second"])
        let first = try await FileList.files(root: root, runner: .local, ripgrep: listingTool, limit: 1)
        XCTAssertEqual(first, ["first"])
        // Stopping a search over SSH stops ripgrep on the device: the fixture's
        // "ssh" dies with the stream, and only the script's stdin watchdog is
        // left to end the search.
        let needle = "uherdr-stop-\(UUID().uuidString)"
        func remoteRipgrep() -> Bool {
            let pgrep = Process()
            pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            pgrep.arguments = ["-f", "[" + String(needle.prefix(1)) + "]" + String(needle.dropFirst())]
            pgrep.standardOutput = FileHandle.nullDevice
            try? pgrep.run(); pgrep.waitUntilExit()
            return pgrep.terminationStatus == 0
        }
        // A stand-in ripgrep that never finishes on its own (its arguments carry the query).
        let slow = root + "-slow-rg.sh"
        fm.createFile(atPath: slow, contents: Data("#!/bin/sh\nsleep 30\n".utf8), attributes: [.posixPermissions: 0o755])
        defer { try? fm.removeItem(atPath: slow) }
        let detached = ScriptRunner.remote(RemoteShell(profile: profile, ssh: fixture,
            environment: base.merging(["UHERDR_FIXTURE_DETACH": "1"]) { $1 }))
        let long = Task { try await ContentSearch.search(SearchOptions(query: needle), root: root, runner: detached, ripgrep: slow) }
        var seen = false
        for _ in 0..<250 where !seen { try await Task.sleep(for: .milliseconds(20)); seen = remoteRipgrep() }
        XCTAssertTrue(seen)
        long.cancel()
        _ = try? await long.value
        var gone = false
        for _ in 0..<100 where !gone { try await Task.sleep(for: .milliseconds(20)); gone = !remoteRipgrep() }
        XCTAssertTrue(gone)

        // Unsaved text replaces the file's disk hits, and globs apply to it.
        let disk = try await ContentSearch.search(SearchOptions(query: "selectedSpace", include: "Sources/**"), root: root, runner: .local, ripgrep: rg)
        let merged = ContentSearch.merging(disk, unsaved: ["Sources/a.swift": "nothing\nselectedSpace here\n", "notes.md": "selectedSpace"],
                                           options: SearchOptions(query: "selectedSpace", include: "Sources/**"))
        XCTAssertEqual(merged.hits.filter { $0.path == "Sources/a.swift" }, [SearchHit(path: "Sources/a.swift", line: 2, text: "selectedSpace here", ranges: [0..<13])])
        XCTAssertTrue(!merged.hits.contains { $0.path == "notes.md" })

        // No ripgrep on the device: search says so; the file list falls back to Git.
        let bin = root + "-bin"
        try fm.createDirectory(atPath: bin, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: bin) }
        let python = (base["PATH"] ?? "").split(separator: ":").map { $0 + "/python3" }.first { fm.isExecutableFile(atPath: $0) } ?? "/usr/bin/python3"
        for tool in ["/bin/sh", "/usr/bin/env", "/usr/bin/sed", "/usr/bin/git", python] {
            try fm.createSymbolicLink(atPath: bin + "/" + (tool as NSString).lastPathComponent, withDestinationPath: tool)
        }
        let bare = ScriptRunner.remote(RemoteShell(profile: profile, ssh: fixture, environment: base.merging(["PATH": bin, "HOME": root]) { $1 }))
        do {
            _ = try await ContentSearch.search(SearchOptions(query: "x"), root: root, runner: bare)
            preconditionFailure("expected no ripgrep")
        } catch let error as SearchError { XCTAssertEqual(error, .ripgrepMissing) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", root, "init", "-q"]
        process.standardOutput = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        let gitFiles = try await FileList.files(root: root, runner: bare)
        XCTAssertTrue(gitFiles.contains("Sources/a.swift") && gitFiles.contains("notes.md"))
        XCTAssertTrue(!gitFiles.contains(".hidden.swift"))
        // A copy installed by uHerdr in ~/.local/share/uherdr/bin is found without PATH.
        try fm.createDirectory(atPath: root + "/.local/share/uherdr/bin", withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: root + "/.local/share/uherdr/bin/rg", withDestinationPath: rg)
        let installed = try await ContentSearch.search(SearchOptions(query: "plural"), root: root, runner: bare)
        XCTAssertEqual(installed.hits.map(\.path), ["notes.md"])
    }

    static func links() {
        let root = "/p", doc = "/p/docs/README.md"
        XCTAssertEqual(MarkdownLink.resolve("guide.md", document: doc, root: root), .file(path: "/p/docs/guide.md", fragment: nil))
        XCTAssertEqual(MarkdownLink.resolve("../Sources/a.swift#L3", document: doc, root: root), .file(path: "/p/Sources/a.swift", fragment: "L3"))
        XCTAssertEqual(MarkdownLink.resolve("/LICENSE", document: doc, root: root), .file(path: "/p/LICENSE", fragment: nil))
        XCTAssertEqual(MarkdownLink.resolve("my%20file.md?raw=1", document: doc, root: root), .file(path: "/p/docs/my file.md", fragment: nil))
        XCTAssertEqual(MarkdownLink.resolve("#build-and-run", document: doc, root: root), .anchor("build-and-run"))
        XCTAssertEqual(MarkdownLink.resolve("https://example.com/x", document: doc, root: root), .external(URL(string: "https://example.com/x")!))
        XCTAssertEqual(MarkdownLink.resolve("mailto:a@b.c", document: doc, root: root), .external(URL(string: "mailto:a@b.c")!))
        XCTAssertEqual(MarkdownLink.resolve("../../etc/passwd", document: doc, root: root), .disabled(reason: "Outside this space's folder"))
        XCTAssertEqual(MarkdownLink.resolve("/../../etc", document: doc, root: root), .disabled(reason: "Outside this space's folder"))
        XCTAssertEqual(MarkdownLink.resolve("../../p2/x.md", document: doc, root: root), .disabled(reason: "Outside this space's folder"))
        XCTAssertEqual(MarkdownLink.resolve("file:///etc/passwd", document: doc, root: root), .disabled(reason: "file: links don't open from the preview"))
        XCTAssertEqual(MarkdownLink.resolve("javascript:alert(1)", document: doc, root: root), .disabled(reason: "javascript: links don't open from the preview"))
        XCTAssertEqual(MarkdownLink.resolve("", document: doc, root: root), .disabled(reason: "Empty link"))
        XCTAssertEqual(FileKind.of("README.md"), .markdown)
        XCTAssertEqual(FileKind.of("a.PNG"), .image)
        XCTAssertEqual(FileKind.of("guide.pdf"), .pdf)
        XCTAssertEqual(FileKind.of("Makefile"), .text)
        XCTAssertTrue(LineTarget.parse("12").map { $0 == (12, 1) } == true)
        XCTAssertTrue(LineTarget.parse(" 12:5 ").map { $0 == (12, 5) } == true)
        for bad in ["", "0", "-3", "a", "12:", "12:0", "1:2:3", "12 5"] { XCTAssertTrue(LineTarget.parse(bad) == nil) }
    }
}
