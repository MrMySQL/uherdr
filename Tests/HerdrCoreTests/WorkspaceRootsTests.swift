import Foundation
import HerdrCore

enum WorkspaceRootsTests {
    static func run() {
        var roots = WorkspaceRoots()
        XCTAssertTrue(roots.root(for: "w1") == nil)
        roots.remember("/Users/me/project", for: "w1")
        roots.remember("  /srv/school-next \n", for: "w2")
        roots.remember("   ", for: "w3")
        XCTAssertEqual(roots.root(for: "w1"), "/Users/me/project")
        XCTAssertEqual(roots.root(for: "w2"), "/srv/school-next")
        XCTAssertTrue(roots.root(for: "w3") == nil)
        roots.remember("/Users/me/other", for: "w1")
        XCTAssertEqual(roots.root(for: "w1"), "/Users/me/other")

        // Spaces the server no longer lists are dropped; listed ones stay.
        XCTAssertTrue(roots.prune(keeping: ["w2", "w9"]))
        XCTAssertTrue(roots.root(for: "w1") == nil)
        XCTAssertEqual(roots.root(for: "w2"), "/srv/school-next")
        XCTAssertTrue(!roots.prune(keeping: ["w2"]))
        roots.forget("w2")
        XCTAssertTrue(roots.root(for: "w2") == nil)

        // Saved per profile; two profiles with the same workspace ID stay apart.
        let suite = "uherdr-roots-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let a = UUID(), b = UUID()
        var first = WorkspaceRoots()
        first.remember("/a", for: "w1")
        first.save(profile: a, to: defaults)
        var second = WorkspaceRoots()
        second.remember("/b", for: "w1")
        second.save(profile: b, to: defaults)
        XCTAssertEqual(WorkspaceRoots.load(profile: a, from: defaults).root(for: "w1"), "/a")
        XCTAssertEqual(WorkspaceRoots.load(profile: b, from: defaults).root(for: "w1"), "/b")
        XCTAssertEqual(WorkspaceRoots.load(profile: UUID(), from: defaults), WorkspaceRoots())

        // An emptied list removes its key; unreadable data loads as empty.
        first.forget("w1")
        first.save(profile: a, to: defaults)
        XCTAssertTrue(defaults.object(forKey: WorkspaceRoots.preferencesKey(profile: a)) == nil)
        defaults.set(Data("not json".utf8), forKey: WorkspaceRoots.preferencesKey(profile: a))
        XCTAssertEqual(WorkspaceRoots.load(profile: a, from: defaults), WorkspaceRoots())
        print("PASS: space folders per profile: remember, replace, prune vanished spaces, forget, save and load")
    }
}

enum FolderGuessTests {
    static func run() async throws {
        let fm = FileManager.default
        let base = PathBoundary.canonical(NSTemporaryDirectory())! + "/uherdr-guess-\(UUID().uuidString)"
        defer { try? fm.removeItem(atPath: base) }
        let home = base + "/home", repo = home + "/code/app", plain = home + "/notes/2026", dotfiles = base + "/dothome"
        for folder in [repo + "/Sources/deep", plain, dotfiles + "/proj"] { try fm.createDirectory(atPath: folder, withIntermediateDirectories: true) }
        for folder in [repo, dotfiles] {
            let git = Process()
            git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            git.arguments = ["-C", folder, "init", "-q"]
            git.standardOutput = FileHandle.nullDevice
            try git.run(); git.waitUntilExit()
        }
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../Fixtures/ssh-shell-fixture.py").standardized.path
        let profile = DeviceProfile(name: "Fixture box", kind: .ssh, host: "dev-box", executable: "/tmp/herdr")
        let remote = ScriptRunner.remote(RemoteShell(profile: profile, ssh: fixture,
            environment: ProcessInfo.processInfo.environment.merging(["GIT_DIR": "/elsewhere"]) { $1 }))
        for runner in [ScriptRunner.local, remote] {
            // Inside a repository: its top folder, wherever the terminal is in it.
            let fromDeep = await FolderGuess.folder(for: repo + "/Sources/deep", home: home, runner: runner)
            XCTAssertEqual(fromDeep, repo)
            // Outside a repository: the folder itself.
            let fromPlain = await FolderGuess.folder(for: plain, home: home, runner: runner)
            XCTAssertEqual(fromPlain, plain)
            // Home, "/", or above home: no guess; the sidebar asks.
            let fromHome = await FolderGuess.folder(for: home, home: home, runner: runner)
            let fromRoot = await FolderGuess.folder(for: "/", home: home, runner: runner)
            let fromAbove = await FolderGuess.folder(for: base, home: home, runner: runner)
            XCTAssertTrue(fromHome == nil && fromRoot == nil && fromAbove == nil)
            // A home folder that is itself a repository (dotfiles): the terminal's own folder.
            let fromDotfiles = await FolderGuess.folder(for: dotfiles + "/proj", home: dotfiles, runner: runner)
            XCTAssertEqual(fromDotfiles, dotfiles + "/proj")
            // A folder that is gone: no guess.
            let fromMissing = await FolderGuess.folder(for: base + "/missing", home: home, runner: runner)
            XCTAssertTrue(fromMissing == nil)
        }
        XCTAssertTrue(await FolderGuess.folder(for: "relative/path", home: home, runner: .local) == nil)
        XCTAssertTrue(FolderGuess.isTooBroad("/Users", home: "/Users/me") && FolderGuess.isTooBroad("/Users/me/", home: "/Users/me")
                      && !FolderGuess.isTooBroad("/Users/me2", home: "/Users/me"))
        print("PASS: folder guess: repository top folder, plain folder, never home, / or above, dotfiles home, missing folder, here and over SSH")
    }
}
