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
