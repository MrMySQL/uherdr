import Foundation
import HerdrCore

enum RemoteFileListingTests {
    /// Login shells the ssh fixture parses commands with, where installed.
    /// fish isn't among them; `RemoteShell`'s own words are checked instead.
    static let loginShells = ["/bin/sh", "/bin/dash", "/bin/bash", "/bin/zsh", "/bin/csh", "/bin/tcsh"]

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
                     "ünï cødé.swift", ".gitignore", "a\\b", "semi;colon", ".uherdr-x-1",
                     "\\';touch PWNED3;#", "ends in \\", "two\n\n", "!history"]
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

        for shellPath in RemoteFileListingTests.loginShells where fm.isExecutableFile(atPath: shellPath) {
            let shell = RemoteShell(profile: profile, ssh: fixture,
                                    environment: ProcessInfo.processInfo.environment.merging(["UHERDR_FIXTURE_SHELL": shellPath]) { $1 })
            // Same answer as listing the folder on this Mac, entry for entry.
            let remote = try await RemoteFileListing.list(root, root: root, shell: shell)
            XCTAssertEqual(remote, local)
            XCTAssertTrue(["PWNED", "PWNED2", "PWNED3"].allSatisfy { !fm.fileExists(atPath: root + "/" + $0) && !fm.fileExists(atPath: $0) })
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
        // A space whose folder is "/" lists like any other.
        let shell = RemoteShell(profile: profile, ssh: fixture)
        XCTAssertEqual(try await RemoteFileListing.list(root, root: "/", shell: shell), try LocalFileListing.list(root, in: PathBoundary(root: "/")))

        // ssh's own failure (exit 255) is reported with its message.
        let tools = base + "/tools"
        try fm.createDirectory(atPath: tools, withIntermediateDirectories: true)
        func tool(_ name: String, _ body: String) throws -> String {
            let path = tools + "/" + name
            try Data(("#!/bin/sh\n" + body + "\n").utf8).write(to: URL(fileURLWithPath: path))
            chmod(path, 0o755)
            return path
        }
        let refused = RemoteShell(profile: profile, ssh: try tool("refused", "echo 'ssh: connect to host dev-box port 22: Connection refused' >&2; exit 255"))
        do {
            _ = try await RemoteFileListing.list(root, root: root, shell: refused)
            XCTFail("Expected an ssh failure")
        } catch {
            XCTAssertEqual(error as? FileListingError, .failed(root, "ssh: connect to host dev-box port 22: Connection refused"))
        }
        // A name that isn't UTF-8 (possible on Linux) can't become a usable path, so it isn't listed.
        let raw = RemoteShell(profile: profile, ssh: try tool("raw", #"printf 'f\0\377bad\0\0\0f\0good\0\0\0'"#))
        XCTAssertEqual(try await RemoteFileListing.list("/r", root: "/r", shell: raw), [FileEntry(name: "good", path: "/r/good", kind: .file)])
        // What the login shell parses: plain words and single-quoted words with
        // no quote, backslash or newline inside, which fish, csh and POSIX
        // shells all read the same way, whatever the arguments hold.
        for word in RemoteShell.remoteWords("printf '%s\\n' \"$1\"", names + ["", "\\", "'", "\n"]) {
            let safe = ["sh", "-c", "uherdr"].contains(word)
                || (word.count >= 2 && word.hasPrefix("'") && word.hasSuffix("'")
                    && !word.dropFirst().dropLast().contains { "'\\\n".contains($0) })
            if !safe { XCTFail("Unsafe login-shell word: \(word)") }
        }
        print("PASS: SSH listing through a login-shell fixture (sh, dash, bash, zsh, csh, tcsh) matches local listing, survives hostile names, and maps every error")
    }
}
