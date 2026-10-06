import Foundation
import HerdrCore

enum DraftStoreTests {
    static func run() throws {
        let fm = FileManager.default
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("uherdr-drafts-\(UUID().uuidString)/Drafts")
        defer { try? fm.removeItem(at: folder.deletingLastPathComponent()) }
        let store = DraftStore(directory: folder)
        let mac = UUID(), box = UUID()
        let when = Date(timeIntervalSince1970: 1_790_000_000)
        let env = Draft(profileID: mac, workspaceID: "w1", spaceLabel: "uherdr", root: "/p", path: "/p/.env",
                        text: "TOKEN=secret-value\n", baselineSHA: "abc", savedAt: when)
        try store.save(env)
        XCTAssertEqual(store.load(profile: mac, path: "/p/.env"), env)
        XCTAssertTrue(store.load(profile: box, path: "/p/.env") == nil)
        // Private folder and file; the name reveals neither the path nor the text.
        let files = try fm.subpathsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".json") }
        XCTAssertEqual(files.count, 1)
        XCTAssertTrue(!files[0].contains("env") && !files[0].contains("secret"))
        XCTAssertEqual((try fm.attributesOfItem(atPath: folder.appendingPathComponent(files[0]).path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual((try fm.attributesOfItem(atPath: folder.path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual((try fm.attributesOfItem(atPath: folder.appendingPathComponent(mac.uuidString).path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)

        // Replacing, per-device lists, removal, and a removed device's drafts.
        var newer = env
        newer.text = "TOKEN=other\n"
        newer.savedAt = when.addingTimeInterval(60)
        try store.save(newer)
        XCTAssertEqual(store.all(profile: mac), [newer])
        let swift = Draft(profileID: mac, workspaceID: "w1", spaceLabel: "uherdr", root: "/p", path: "/p/a.swift",
                          text: "let x = 1", baselineSHA: "def", savedAt: when)
        try store.save(swift)
        try store.save(Draft(profileID: box, workspaceID: "w1", spaceLabel: "api", root: "/srv", path: "/srv/a.go",
                             text: "package a", baselineSHA: "123", savedAt: when))
        XCTAssertEqual(store.all(profile: mac).map(\.path), ["/p/a.swift", "/p/.env"])
        store.remove(profile: mac, path: "/p/.env")
        XCTAssertEqual(store.all(profile: mac).map(\.path), ["/p/a.swift"])
        store.removeAll(profile: mac)
        XCTAssertEqual(store.all(profile: mac), [])
        XCTAssertEqual(store.all(profile: box).map(\.path), ["/srv/a.go"])
        // A damaged draft file is skipped, not fatal; no temp files are left.
        try Data("not json".utf8).write(to: folder.appendingPathComponent(box.uuidString).appendingPathComponent("junk.json"))
        XCTAssertEqual(store.all(profile: box).map(\.path), ["/srv/a.go"])
        let temps = try fm.subpathsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".tmp") }
        XCTAssertEqual(temps, [])
        print("PASS: drafts: saved and loaded per device and path, private folder and files, hashed names, replace, remove, device removal, damaged files skipped")
    }
}
