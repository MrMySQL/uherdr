import Foundation
import HerdrCore

enum GitChangesTests {
    static func run() async throws {
        try parserCases()
        try await unstagedRename()
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../Fixtures/ssh-shell-fixture.py").standardized.path
        let fm = FileManager.default
        let base = PathBoundary.canonical(NSTemporaryDirectory())! + "/uherdr-git-\(UUID().uuidString)"
        defer { try? fm.removeItem(atPath: base) }
        try fm.createDirectory(atPath: base, withIntermediateDirectories: true)
        let repo = base + "/repo"

        @discardableResult
        func git(_ args: String..., in folder: String = repo) throws -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-c", "user.email=t@example.com", "-c", "user.name=Test", "-c", "init.defaultBranch=main",
                                 "-c", "commit.gpgsign=false", "-C", folder] + args
            process.environment = GitIgnoreCheck.environment()
            let out = Pipe()
            process.standardOutput = out
            process.standardError = FileHandle.nullDevice
            try process.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            precondition(process.terminationStatus == 0 || args.first == "merge", "git \(args) failed")
            return String(decoding: data, as: UTF8.self)
        }
        func write(_ path: String, _ text: String) { fm.createFile(atPath: repo + "/" + path, contents: Data(text.utf8)) }

        // A repository with every kind of change, odd names, a rename, deletes and a conflict.
        try fm.createDirectory(atPath: repo + "/src/deep", withIntermediateDirectories: true)
        try git("init", "-q", in: base + "/repo")
        write("src/a.swift", "let a = 1\nlet b = 2\n")
        write("src/old name.swift", "old\n")
        write("src/gone.swift", "gone\n")
        write("src/staged-gone.swift", "bye\n")
        write("src/both.swift", "1\n")
        write("src/conflict.txt", "base\n")
        write("top.md", "top\n")
        write("src/[ab].swift", "glob\n")
        write("src/index-only.swift", "v1\n")
        try git("add", "-A")
        try git("commit", "-qm", "init")
        try git("branch", "other")
        write("src/conflict.txt", "main side\n")
        try git("commit", "-qam", "main side")
        try git("checkout", "-q", "other")
        write("src/conflict.txt", "other side\n")
        try git("commit", "-qam", "other side")
        try git("checkout", "-q", "main")
        try git("merge", "-q", "other")
        write("src/a.swift", "let a = 1\nlet b = 3\nlet c = 4\n")
        try git("mv", "src/old name.swift", "src/new name.swift")
        try fm.removeItem(atPath: repo + "/src/gone.swift")
        try git("rm", "-q", "src/staged-gone.swift")
        write("src/both.swift", "2\n")
        try git("add", "src/both.swift")
        write("src/both.swift", "3\n")
        write("src/[ab].swift", "glob!\n")
        write("src/index-only.swift", "v2\n")
        try git("add", "src/index-only.swift")
        try fm.removeItem(atPath: repo + "/src/index-only.swift")
        let odd = ["src/deep/new\nline.txt", "src/it's $(touch PWNED).txt", "src/ünï.md", "top-untracked.txt"]
        for name in odd { write(name, "x\n") }

        let profile = DeviceProfile(name: "Fixture box", kind: .ssh, host: "dev-box", executable: "/tmp/herdr")
        func remote(_ extra: [String: String] = [:], shell: String = "/bin/sh") -> ScriptRunner {
            .remote(RemoteShell(profile: profile, ssh: fixture,
                                environment: ProcessInfo.processInfo.environment.merging(["UHERDR_FIXTURE_SHELL": shell].merging(extra) { $1 }) { $1 }))
        }
        var runners: [(String, ScriptRunner)] = [("local", .local), ("sh", remote())]
        if fm.isExecutableFile(atPath: "/bin/dash") { runners.append(("dash", remote(shell: "/bin/dash"))) }

        for (name, runner) in runners {
            let whole = try await GitChangesReader.read(root: repo, runner: runner)
            XCTAssertEqual(whole.repositoryRoot, repo)
            XCTAssertEqual(whole.prefix, "")
            XCTAssertEqual(whole.outside, 0)
            XCTAssertEqual(whole.branch.head, "main")
            let rows = Set(whole.changes.map { "\($0.group.title) \($0.letter) \($0.path)" + ($0.originalPath.map { " <- " + $0 } ?? "") })
            XCTAssertEqual(rows, [
                "Conflicts C src/conflict.txt",
                "Changes M src/a.swift",
                "Staged R src/new name.swift <- src/old name.swift",
                "Changes D src/gone.swift",
                "Staged D src/staged-gone.swift",
                "Staged M src/both.swift",
                "Changes M src/both.swift",
                "Changes M src/[ab].swift",
                "Staged M src/index-only.swift",
                "Changes D src/index-only.swift",
                "Untracked U src/deep/new\nline.txt",
                "Untracked U src/it's $(touch PWNED).txt",
                "Untracked U src/ünï.md",
                "Untracked U top-untracked.txt",
            ])
            XCTAssertEqual(whole.fileCount, 12)
            XCTAssertTrue(!fm.fileExists(atPath: repo + "/src/PWNED") && !fm.fileExists(atPath: "PWNED"))

            // The space folder inside a bigger repository: only its changes, the rest counted.
            let sub = try await GitChangesReader.read(root: repo + "/src/deep", runner: runner)
            XCTAssertEqual(sub.prefix, "src/deep/")
            XCTAssertEqual(sub.changes.map(\.path), ["src/deep/new\nline.txt"])
            XCTAssertEqual(sub.outside, 11)

            // Diffs: unstaged, staged, staged rename, untracked, deletes, base versions.
            func change(_ group: GitChange.Group, _ path: String) -> GitChange { whole.changes.first { $0.group == group && $0.path == path }! }
            let unstaged = try await GitDiffReader.read(change(.changes, "src/a.swift"), repositoryRoot: repo, runner: runner)
            XCTAssertEqual(unstaged.hunks.count, 1)
            XCTAssertEqual(unstaged.hunks[0].lines.map { "\($0.kind) \($0.old ?? 0) \($0.new ?? 0) \($0.text)" }, [
                "context 1 1 let a = 1", "removed 2 0 let b = 2", "added 0 2 let b = 3", "added 0 3 let c = 4"])
            // Names are literal, never globs: "[ab]" doesn't also match a.swift.
            let glob = try await GitDiffReader.read(change(.changes, "src/[ab].swift"), repositoryRoot: repo, runner: runner)
            XCTAssertEqual(glob.hunks.flatMap(\.lines).map(\.text), ["glob", "glob!"])
            // An unstaged delete's base is the index, a staged one's is HEAD.
            XCTAssertEqual(try await GitDiffReader.baseVersion(change(.changes, "src/index-only.swift"), repositoryRoot: repo, runner: runner), Data("v2\n".utf8))
            let staged = try await GitDiffReader.read(change(.staged, "src/both.swift"), repositoryRoot: repo, runner: runner)
            XCTAssertEqual(staged.hunks.flatMap(\.lines).map(\.text), ["1", "2"])
            let worktree = try await GitDiffReader.read(change(.changes, "src/both.swift"), repositoryRoot: repo, runner: runner)
            XCTAssertEqual(worktree.hunks.flatMap(\.lines).map(\.text), ["2", "3"])
            let renamed = try await GitDiffReader.read(change(.staged, "src/new name.swift"), repositoryRoot: repo, runner: runner)
            XCTAssertEqual(renamed.hunks.count, 0) // a pure rename has no line changes
            XCTAssertTrue(!renamed.isBinary)
            let untracked = try await GitDiffReader.read(change(.untracked, "src/it's $(touch PWNED).txt"), repositoryRoot: repo, runner: runner)
            XCTAssertEqual(untracked.hunks.flatMap(\.lines).map { "\($0.kind) \($0.text)" }, ["added x"])
            let newline = try await GitDiffReader.read(change(.untracked, "src/deep/new\nline.txt"), repositoryRoot: repo, runner: runner)
            XCTAssertEqual(newline.added, 1)
            let deleted = try await GitDiffReader.read(change(.changes, "src/gone.swift"), repositoryRoot: repo, runner: runner)
            XCTAssertEqual(deleted.removed, 1)
            XCTAssertEqual(try await GitDiffReader.baseVersion(change(.changes, "src/gone.swift"), repositoryRoot: repo, runner: runner), Data("gone\n".utf8))
            XCTAssertEqual(try await GitDiffReader.baseVersion(change(.staged, "src/staged-gone.swift"), repositoryRoot: repo, runner: runner), Data("bye\n".utf8))
            XCTAssertTrue(!fm.fileExists(atPath: repo + "/src/PWNED") && !fm.fileExists(atPath: "PWNED"))

            // Not a repository, and a missing folder.
            try fm.createDirectory(atPath: base + "/plain", withIntermediateDirectories: true)
            await expect(.notRepository, name) { try await GitChangesReader.read(root: base + "/plain", runner: runner) }
            await expect(.folderMissing, name) { try await GitChangesReader.read(root: base + "/missing", runner: runner) }
        }

        // A linked worktree (its .git is a file) reports its own folder and branch.
        try git("worktree", "add", "-q", "-b", "feature", base + "/wt")
        fm.createFile(atPath: base + "/wt/feature.txt", contents: Data("f\n".utf8))
        let worktree = try await GitChangesReader.read(root: base + "/wt", runner: .local)
        XCTAssertEqual(worktree.repositoryRoot, base + "/wt")
        XCTAssertEqual(worktree.branch.head, "feature")
        XCTAssertEqual(worktree.changes.map(\.path), ["feature.txt"])

        // Ahead/behind an upstream, and a detached HEAD.
        let clean = base + "/clean"
        try fm.createDirectory(atPath: clean, withIntermediateDirectories: true)
        try git("init", "-q", in: clean)
        fm.createFile(atPath: clean + "/f", contents: Data("1".utf8))
        try git("add", "f", in: clean)
        try git("commit", "-qm", "one", in: clean)
        try git("branch", "base", in: clean)
        try git("branch", "-q", "-u", "base", in: clean)
        fm.createFile(atPath: clean + "/f", contents: Data("2".utf8))
        try git("commit", "-qam", "two", in: clean)
        let ahead = try await GitChangesReader.read(root: clean, runner: .local)
        XCTAssertEqual(ahead.branch.upstream, "base")
        XCTAssertEqual(ahead.branch.ahead, 1)
        XCTAssertEqual(ahead.branch.behind, 0)
        XCTAssertEqual(ahead.changes, [])
        try git("checkout", "-q", "--detach", in: clean)
        let detached = try await GitChangesReader.read(root: clean, runner: .local)
        XCTAssertTrue(detached.branch.head == nil && detached.branch.label.hasPrefix("detached at "))

        // Git missing, and Git refusing a repository another user owns.
        let bin = base + "/bin"
        try fm.createDirectory(atPath: bin, withIntermediateDirectories: true)
        // Only what the scripts and the fixture itself (python3) need.
        let python = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
            .map { $0 + "/python3" }.first { fm.isExecutableFile(atPath: $0) } ?? "/usr/bin/python3"
        for tool in ["/bin/sh", "/usr/bin/env", "/usr/bin/sed", python] {
            try fm.createSymbolicLink(atPath: bin + "/" + (tool as NSString).lastPathComponent, withDestinationPath: tool)
        }
        await expect(.gitMissing, "no git") { try await GitChangesReader.read(root: repo, runner: remote(["PATH": bin])) }
        await expect(.gitMissing, "no git, diff") {
            _ = try await GitDiffReader.read(GitChange(group: .changes, path: "src/a.swift", letter: "M"), repositoryRoot: repo, runner: remote(["PATH": bin]))
        }
        fm.createFile(atPath: bin + "/git", contents: Data("#!/bin/sh\necho \"fatal: detected dubious ownership in repository at '$PWD'\" >&2\nexit 128\n".utf8),
                      attributes: [.posixPermissions: 0o755])
        await expect(.dubiousOwnership, "dubious") { try await GitChangesReader.read(root: repo, runner: remote(["PATH": bin])) }
        // The user's GIT_* variables never point Git elsewhere.
        let isolated = try await GitChangesReader.read(root: repo, runner: remote(["GIT_DIR": clean + "/.git", "GIT_WORK_TREE": clean]))
        XCTAssertEqual(isolated.repositoryRoot, repo)
        print("PASS: git changes here and over SSH (sh, dash): every change kind, odd names, renames, deletes, conflicts, folder in a bigger repo, worktree, ahead/behind, detached, diffs and base versions, not a repo, missing folder, no git, dubious ownership, GIT_* ignored")
    }

    static func expect(_ error: GitChangesError, _ label: String, _ body: () async throws -> Void) async {
        do {
            try await body()
            preconditionFailure("\(label): expected \(error)")
        } catch let thrown as GitChangesError {
            precondition(thrown == error, "\(label): expected \(error), got \(thrown)")
        } catch {
            preconditionFailure("\(label): expected \(error), got \(error)")
        }
    }

    static func unstagedRename() async throws {
  let root = NSTemporaryDirectory() + "diff-review-" + UUID().uuidString
  let fm = FileManager.default
  try fm.createDirectory(atPath: root, withIntermediateDirectories: true)
  defer { try? fm.removeItem(atPath: root) }
  func git(_ args: [String]) throws {
   let p = Process();p.executableURL=URL(fileURLWithPath:"/usr/bin/git");p.arguments=["-C",root]+args
   p.environment=GitIgnoreCheck.environment();p.standardOutput=FileHandle.nullDevice;p.standardError=FileHandle.nullDevice
   try p.run();p.waitUntilExit();precondition(p.terminationStatus==0)
  }
  try git(["init", "-q"])
  fm.createFile(atPath: root+"/old", contents:Data("same\nunchanged\n".utf8))
  try git(["add", "old"])
  try fm.moveItem(atPath:root+"/old",toPath:root+"/new")
  try git(["add", "-N", "new"])
  let change = GitChange(group:.changes,path:"new",originalPath:"old",letter:"R")
  let diff = try await GitDiffReader.read(change,repositoryRoot:root,runner:.local)
  precondition(diff.hunks.isEmpty, "Pure unstaged rename has no full-add hunk")
    }

    static func parserCases() throws {
        // Branch lines, a path with spaces, an unknown record kind, and ignored entries.
        let status = "# branch.oid (initial)\0# branch.head (detached)\0# branch.upstream origin/main\0# branch.ab +3 -2\0"
            + "1 A. N... 000000 100644 100644 0000000000000000000000000000000000000000 1111111111111111111111111111111111111111 a b c.txt\0"
            + "2 .R N... 100644 100644 100644 1111111111111111111111111111111111111111 1111111111111111111111111111111111111111 R90 to me\0from me\0"
            + "! ignored.log\0z future\0? new.txt\0"
            // An original path that looks like a record must not be read as one.
            + "2 R. N... 100644 100644 100644 1111111111111111111111111111111111111111 1111111111111111111111111111111111111111 R100 moved\0? trick\0"
        let parsed = GitStatusParser.parse(Data(status.utf8))
        XCTAssertEqual(parsed.branch, GitBranch(head: nil, oid: nil, upstream: "origin/main", ahead: 3, behind: 2))
        XCTAssertEqual(parsed.branch.label, "detached")
        XCTAssertEqual(parsed.changes, [
            GitChange(group: .staged, path: "a b c.txt", letter: "A"),
            GitChange(group: .changes, path: "to me", originalPath: "from me", letter: "R"),
            GitChange(group: .untracked, path: "new.txt", letter: "U"),
            GitChange(group: .staged, path: "moved", originalPath: "? trick", letter: "R"),
        ])

        // Hunks: counts of zero, no newline at the end, CRLF, binary.
        let diff = "diff --git a/x b/x\nindex 1..2 100644\n--- a/x\n+++ b/x\n@@ -0,0 +1,2 @@\n+one\r\n+two\n\\ No newline at end of file\n@@ -10,2 +11 @@ func f() {\n ctx\n-gone\n"
        let parsedDiff = UnifiedDiffParser.parse(Data(diff.utf8))
        XCTAssertEqual(parsedDiff.hunks.map(\.header), ["@@ -0,0 +1,2 @@", "@@ -10,2 +11 @@ func f() {"])
        XCTAssertEqual(parsedDiff.hunks[0].lines, [
            GitDiff.Line(kind: .added, text: "one", old: nil, new: 1),
            GitDiff.Line(kind: .added, text: "two", old: nil, new: 2, noNewlineAtEnd: true),
        ])
        XCTAssertEqual(parsedDiff.hunks[1].lines, [
            GitDiff.Line(kind: .context, text: "ctx", old: 10, new: 11),
            GitDiff.Line(kind: .removed, text: "gone", old: 11, new: nil),
        ])
        XCTAssertEqual(parsedDiff.added, 2)
        XCTAssertEqual(parsedDiff.removed, 1)
        let blank = UnifiedDiffParser.parse(Data("@@ -1,2 +1,2 @@\n a\n\n b\n".utf8))
        XCTAssertEqual(blank.hunks[0].lines.map(\.new), [1, 2])
        // Split rows: removed beside added, extra lines on one side alone, context on both.
        let split = UnifiedDiffParser.parse(Data("@@ -1,5 +1,4 @@\n a\n-b\n-c\n+B\n d\n+e\n-f\n-g\n".utf8)).hunks[0].splitRows
        XCTAssertEqual(split.map { "\($0.old?.text ?? "_")|\($0.new?.text ?? "_")" }, ["a|a", "b|B", "c|_", "d|d", "_|e", "f|_", "g|_"])
        XCTAssertTrue(UnifiedDiffParser.parse(Data("diff --git a/i b/i\nBinary files a/i and b/i differ\n".utf8)).isBinary)
        XCTAssertEqual(UnifiedDiffParser.parse(Data()), GitDiff())
    }
}
