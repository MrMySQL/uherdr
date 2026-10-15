import Foundation
import HerdrCore

enum GitIgnoreCheckTests {
    static func run() async throws {
        let fm = FileManager.default
        let base = PathBoundary.canonical(NSTemporaryDirectory())! + "/uherdr-ignore-\(UUID().uuidString)"
        defer { try? fm.removeItem(atPath: base) }
        let repo = base + "/repo"
        try fm.createDirectory(atPath: repo + "/Sources", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: repo + "/node_modules", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: base + "/plain", withIntermediateDirectories: true)
        let initialized = try await StreamingProcess.run(executable: GitIgnoreCheck.gitPath, arguments: ["init", "-q", repo],
                                                         environment: GitIgnoreCheck.environment())
        XCTAssertEqual(initialized.status, 0)
        try "node_modules/\n*.log\nnew\nline.txt\nSources/gen.swift\n".write(toFile: repo + "/.gitignore", atomically: true, encoding: .utf8)
        let names = ["node_modules", "debug.log", "keep.txt", "Sources", "new\nline.txt", "ünï.log", ".gitignore"]
        let ignored = await GitIgnoreCheck.ignoredNames(names, in: repo)
        XCTAssertEqual(ignored, ["node_modules", "debug.log", "ünï.log"])
        // Nested folder: rules are relative to the repository, names to the folder.
        XCTAssertEqual(await GitIgnoreCheck.ignoredNames(["gen.swift", "real.swift"], in: repo + "/Sources"), ["gen.swift"])
        // Nothing ignored, outside a repository, no Git: an empty answer, not an error.
        XCTAssertEqual(await GitIgnoreCheck.ignoredNames(["keep.txt"], in: repo), [])
        XCTAssertEqual(await GitIgnoreCheck.ignoredNames(["a.log"], in: base + "/plain"), [])
        XCTAssertEqual(await GitIgnoreCheck.ignoredNames(["debug.log"], in: repo, git: "/no/such/git"), [])
        XCTAssertEqual(await GitIgnoreCheck.ignoredNames([], in: repo), [])
        // An inherited GIT_DIR can't redirect the check to another repository.
        let env = GitIgnoreCheck.environment(["GIT_DIR": "/elsewhere", "GIT_INDEX_FILE": "/x", "PATH": "/usr/bin", "HOME": "/tmp"])
        XCTAssertTrue(env["GIT_DIR"] == nil && env["GIT_INDEX_FILE"] == nil)
        XCTAssertEqual(env["PATH"], "/usr/bin")
        XCTAssertEqual(env["GIT_OPTIONAL_LOCKS"], "0")
        // Over SSH: the same answers from the device's own Git, through the fixture under sh and dash.
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../Fixtures/ssh-shell-fixture.py").standardized.path
        let profile = DeviceProfile(name: "Fixture box", kind: .ssh, host: "dev-box", executable: "/tmp/herdr")
        for shellPath in ["/bin/sh", "/bin/dash"] where fm.isExecutableFile(atPath: shellPath) {
            let shell = RemoteShell(profile: profile, ssh: fixture,
                                    environment: ProcessInfo.processInfo.environment.merging(["UHERDR_FIXTURE_SHELL": shellPath, "GIT_DIR": "/elsewhere"]) { $1 })
            XCTAssertEqual(await GitIgnoreCheck.ignoredNames(names, in: repo, shell: shell), ["node_modules", "debug.log", "ünï.log"])
            XCTAssertEqual(await GitIgnoreCheck.ignoredNames(["gen.swift", "real.swift"], in: repo + "/Sources", shell: shell), ["gen.swift"])
            XCTAssertEqual(await GitIgnoreCheck.ignoredNames(["a.log"], in: base + "/plain", shell: shell), [])
            // A missing folder answers nothing, not the rules of wherever the shell started.
            XCTAssertEqual(await GitIgnoreCheck.ignoredNames(["debug.log", "node_modules"], in: base + "/missing", shell: RemoteShell(profile: profile, ssh: fixture,
                environment: ProcessInfo.processInfo.environment.merging(["UHERDR_FIXTURE_SHELL": shellPath, "UHERDR_FIXTURE_CWD": repo]) { $1 })), [])
        }
        let noGit = RemoteShell(profile: profile, ssh: fixture, environment: ProcessInfo.processInfo.environment.merging(["PATH": "/nonexistent"]) { $1 })
        XCTAssertEqual(await GitIgnoreCheck.ignoredNames(["debug.log"], in: repo, shell: noGit), [])
        print("PASS: git ignore check: ignored names per folder, nested rules, odd names, no repo/no git/none ignored, cleaned GIT_* environment, the same over SSH (sh, dash)")
    }
}
