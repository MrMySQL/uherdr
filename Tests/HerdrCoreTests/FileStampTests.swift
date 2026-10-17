import Foundation
import HerdrCore

enum FileStampTests {
    static func run() async throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../Fixtures/ssh-shell-fixture.py").standardized.path
        let fm = FileManager.default
        let base = PathBoundary.canonical(NSTemporaryDirectory())! + "/uherdr-stamps-\(UUID().uuidString)"
        defer { try? fm.removeItem(atPath: base) }
        try fm.createDirectory(atPath: base, withIntermediateDirectories: true)
        let a = base + "/a.txt", odd = base + "/it's $(x)\n.txt", gone = base + "/gone.txt"
        fm.createFile(atPath: a, contents: Data("one".utf8))
        fm.createFile(atPath: odd, contents: Data("12345".utf8))

        let before = FileStamps.local([a, odd, gone])
        XCTAssertEqual(before[a]?.size, 3)
        XCTAssertEqual(before[odd]?.size, 5)
        XCTAssertTrue(before[gone] == nil)
        // Same size, replaced by a rename: the inode tells.
        let temp = base + "/.tmp"
        fm.createFile(atPath: temp, contents: Data("two".utf8))
        XCTAssertEqual(rename(temp, a), 0)
        let after = FileStamps.local([a])
        XCTAssertTrue(after[a] != before[a])
        XCTAssertEqual(after[a]?.size, 3)

        let profile = DeviceProfile(name: "Fixture box", kind: .ssh, host: "dev-box", executable: "/tmp/herdr")
        for shellPath in ["/bin/sh", "/bin/dash"] where fm.isExecutableFile(atPath: shellPath) {
            let shell = RemoteShell(profile: profile, ssh: fixture,
                                    environment: ProcessInfo.processInfo.environment.merging(["UHERDR_FIXTURE_SHELL": shellPath]) { $1 })
            let remote = try await FileStamps.remote([a, odd, gone, a], shell: shell)
            XCTAssertEqual(Set(remote.keys), [a, odd])
            XCTAssertEqual(remote[a]?.size, 3)
            XCTAssertEqual(remote[a]?.inode, after[a]?.inode)
            XCTAssertEqual(remote[a]?.modified, after[a].map { $0.modified.rounded(.down) })
            XCTAssertEqual(remote[odd]?.size, 5)
            XCTAssertEqual(try await FileStamps.remote([], shell: shell), [:])
        }
        print("PASS: file stamps: size, time and inode here and over SSH, a rename noticed, missing files, odd names")
    }
}
