import Foundation
import HerdrCore

@main struct SearchModelTests {
    @MainActor static func main() async throws {
        guard let rg = ContentSearch.localRipgrep() else { print("SKIP: search model (no rg on this Mac)"); return }
        let fm = FileManager.default
        let root = PathBoundary.canonical(NSTemporaryDirectory())! + "/uherdr-search-model-\(UUID().uuidString)"
        defer { try? fm.removeItem(atPath: root) }
        try fm.createDirectory(atPath: root + "/src", withIntermediateDirectories: true)
        fm.createFile(atPath: root + "/src/b.swift", contents: Data("needle one\nneedle two\n".utf8))
        fm.createFile(atPath: root + "/a.md", contents: Data("a needle\n".utf8))
        func settle(_ ms: Int = 400) async throws { try await Task.sleep(for: .milliseconds(ms)) }

        // A wrapper that logs each ripgrep run, to count searches.
        let log = root + "-runs.log", wrapper = root + "-rg.sh"
        defer { try? fm.removeItem(atPath: log); try? fm.removeItem(atPath: wrapper) }
        fm.createFile(atPath: wrapper, contents: Data("#!/bin/sh\necho run >> '\(log)'\nexec '\(rg)' \"$@\"\n".utf8), attributes: [.posixPermissions: 0o755])
        func runs() -> Int { (try? String(contentsOfFile: log, encoding: .utf8))?.split(separator: "\n").count ?? 0 }
        // Run it once first: macOS checks a new executable, which makes its first run slow.
        let warm = Process()
        warm.executableURL = URL(fileURLWithPath: wrapper)
        warm.arguments = ["--version"]
        warm.standardOutput = FileHandle.nullDevice
        try warm.run(); warm.waitUntilExit()
        try? fm.removeItem(atPath: log)
        let model = SearchModel()
        model.delay = .milliseconds(60)
        model.open(root: root, runner: .local, ripgrep: wrapper, key: "k1")
        precondition(model.state == .idle, "No query, no search")
        // Typing quickly runs one search, after the pause.
        model.options.query = "nee"
        try await settle(20) // a keystroke gap shorter than the pause
        model.options.query = "needle"
        try await settle(20)
        precondition(model.state == .searching, "Results wait for the pause")
        // The wrapper's first run is slow (macOS checks a new executable), so wait for it.
        for _ in 0..<50 { if case .done = model.state { break }; try await settle(100) }
        guard case let .done(outcome, _) = model.state else { preconditionFailure("Expected results, got \(model.state)") }
        precondition(runs() == 1, "Typing quickly runs ripgrep once")
        precondition(outcome.hits.count == 3)
        precondition(model.groups.map(\.path) == ["a.md", "src/b.swift"] && model.groups[1].matchCount == 2)
        // Unsaved text replaces the file's disk hits, and the group is marked.
        model.unsavedText = { ["src/b.swift": "no\nno\nneedle three\n"] }
        model.rerun()
        try await settle()
        precondition(model.groups.first { $0.path == "src/b.swift" }.map { $0.unsaved && $0.hits.map(\.line) == [3] } == true)
        // An empty query clears; options re-run; a new folder starts over with the same query.
        model.options.query = ""
        precondition(model.state == .idle)
        model.unsavedText = { [:] }
        model.options.query = "needle"
        model.options.caseSensitive = true
        model.options.include = "*.md"
        try await settle()
        precondition(model.groups.map(\.path) == ["a.md"], "Options apply")
        let other = root + "/src"
        model.open(root: other, runner: .local, ripgrep: rg, key: "k2")
        try await settle()
        precondition(model.groups.isEmpty || model.groups.allSatisfy { $0.path == "b.swift" })
        model.options.include = ""
        try await settle()
        precondition(model.groups.map(\.path) == ["b.swift"], "A new folder searches there")
        // A newer search wins over one still running; Stop ends a search.
        model.options.query = "one"
        model.options.query = "two"
        try await settle()
        guard case let .done(latest, _) = model.state else { preconditionFailure() }
        precondition(latest.hits.map(\.text) == ["needle two"])
        model.options.query = "needle"
        model.cancel()
        try await settle()
        precondition(model.state == .idle, "Stop keeps nothing running")
        model.toggle("x"); precondition(model.collapsed == ["x"])

        // Stop ends ripgrep itself: a long search over /usr, stopped, leaves no rg behind.
        let unique = "uherdr-stop-\(UUID().uuidString)"
        func running() -> Bool {
            let pgrep = Process()
            pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            pgrep.arguments = ["-f", unique]
            pgrep.standardOutput = FileHandle.nullDevice
            try? pgrep.run(); pgrep.waitUntilExit()
            return pgrep.terminationStatus == 0
        }
        let long = SearchModel()
        long.delay = .zero
        long.open(root: "/usr", runner: .local, ripgrep: rg, key: "usr")
        long.options.query = unique
        var started = false
        for _ in 0..<50 where !started { try await settle(20); started = running() }
        if started {
            long.cancel()
            try await settle(300)
            precondition(!running(), "Stopping a search ends ripgrep")
            precondition(long.state == .idle)
        } else {
            print("SKIP: stop check (the /usr search finished too fast to catch)")
        }

        // Quick Open: loads the list, ranks open files first, wraps the selection.
        let quick = QuickOpenModel()
        quick.open = ["src/b.swift"]
        quick.load(root: root, runner: .local, ripgrep: rg, key: "q1")
        precondition(quick.files == .loading)
        try await settle()
        precondition(quick.files == .loaded(["a.md", "src/b.swift"]) || quick.files == .loaded(["src/b.swift", "a.md"]))
        precondition(quick.matches.first?.path == "src/b.swift" && quick.total == 2, "Open files first")
        quick.query = "amd"
        precondition(quick.matches.map(\.path) == ["a.md"])
        quick.query = ""
        quick.move(1); precondition(quick.selection == 1)
        quick.move(1); precondition(quick.selection == 0, "The selection wraps")
        quick.move(-1); precondition(quick.selection == 1)
        quick.query = ""; precondition(quick.selection == 1, "Writing the same text back (Return) keeps the selection")
        quick.query = "s"; precondition(quick.selection == 0, "Typing resets the selection")
        quick.load(root: root + "/missing", runner: .local, ripgrep: rg, key: "q2")
        try await settle()
        guard case .failed = quick.files else { preconditionFailure("Expected a failure for a missing folder") }
        print("PASS: search model: debounce, one search per pause, unsaved text marked, options re-run, new folder, newest search wins, stop ends ripgrep; quick open list, open files first, selection wraps, failures")
    }
}
