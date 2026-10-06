import Foundation
import HerdrCore

enum RemoteFileListingTests {
    static func run() async throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../Fixtures/ssh-shell-fixture.py").standardized.path
        let fm = FileManager.default
        let base = PathBoundary.canonical(NSTemporaryDirectory())! + "/uherdr-remote-\(UUID().uuidString)"
        let root = base + "/space"
        defer {
            chmod(root + "/locked", 0o755)
            try? fm.removeItem(atPath: base)
        }
        for dir in ["space/Sources", "space/.git", "space/locked", "space/empty", "space-other", "outside"] {
            try fm.createDirectory(atPath: base + "/" + dir, withIntermediateDirectories: true)
        }
        let names = ["file10.txt", "file2.txt", "it's.md", "new\nline.txt", "$(touch PWNED)", "`touch PWNED2`", "-dash",
                     "ünï cødé.swift", ".gitignore", "a\\b", "semi;colon", ".uherdr-x-1"]
        for name in names { fm.createFile(atPath: root + "/" + name, contents: Data("x".utf8)) }
        fm.createFile(atPath: base + "/outside/secret.env", contents: Data("x".utf8))
        try fm.createSymbolicLink(atPath: root + "/link-in", withDestinationPath: "Sources")
        try fm.createSymbolicLink(atPath: root + "/link-out", withDestinationPath: "../outside/secret.env")
        try fm.createSymbolicLink(atPath: root + "/link-dir-out", withDestinationPath: "../outside")
        try fm.createSymbolicLink(atPath: root + "/dangling", withDestinationPath: "nowhere")
        mkfifo(root + "/pipe", 0o600)
        chmod(root + "/locked", 0o000)
        let profile = DeviceProfile(name: "Fixture box", kind: .ssh, host: "dev-box", executable: "/tmp/herdr")
        let boundary = try PathBoundary(root: root)
        let local = try LocalFileListing.list(root, in: boundary)

        for shellPath in ["/bin/sh", "/bin/dash"] where fm.isExecutableFile(atPath: shellPath) {
            let shell = RemoteShell(profile: profile, ssh: fixture,
                                    environment: ProcessInfo.processInfo.environment.merging(["UHERDR_FIXTURE_SHELL": shellPath]) { $1 })
            // Same answer as listing the folder on this Mac, entry for entry.
            let remote = try await RemoteFileListing.list(root, root: root, shell: shell)
            XCTAssertEqual(remote, local)
            XCTAssertTrue(!fm.fileExists(atPath: root + "/PWNED") && !fm.fileExists(atPath: "PWNED") && !fm.fileExists(atPath: root + "/PWNED2"))
            XCTAssertEqual(try await RemoteFileListing.list(root + "/empty", root: root, shell: shell), [])
            XCTAssertEqual(try await RemoteFileListing.list(root + "/link-in", root: root, shell: shell), [])
            // The same distinct errors as on this Mac.
            for (path, expected) in [(root + "/locked", FileListingError.denied(root + "/locked")),
                                     (root + "/gone", .missing(root + "/gone")),
                                     (root + "/file2.txt", .notDirectory(root + "/file2.txt")),
                                     (root + "/link-dir-out", .outsideSpace(root + "/link-dir-out")),
                                     (base + "/space-other", .outsideSpace(base + "/space-other"))] {
                do {
                    _ = try await RemoteFileListing.list(path, root: root, shell: shell)
                    XCTFail("Expected \(expected)")
                } catch { XCTAssertEqual(error as? FileListingError, expected) }
            }
        }
        // ssh's own failure (exit 255) is reported with its message.
        let broken = RemoteShell(profile: profile, ssh: "/usr/bin/false")
        do {
            _ = try await RemoteFileListing.list(root, root: root, shell: broken)
            XCTFail("Expected an ssh failure")
        } catch {
            guard case .failed? = error as? FileListingError else { XCTFail("Expected .failed, got \(error)"); return }
        }
        XCTAssertEqual(RemoteShell.quote("it's"), "'it'\\''s'")
        print("PASS: SSH listing through a login-shell fixture (sh, dash) matches local listing, survives hostile names, and maps every error")
    }
}
