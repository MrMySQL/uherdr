import CryptoKit
import Foundation
import HerdrCore

enum FileContentsTests {
    static func run() async throws {
        // Decoding: text, BOM, line endings, binary, non-UTF-8, size cap, fingerprint.
        let plain = FileContents.decode(Data("a\nb\n".utf8))
        XCTAssertEqual(plain.kind, .text("a\nb\n"))
        XCTAssertEqual(plain.lineEnding, .lf)
        XCTAssertTrue(!plain.hasBOM)
        XCTAssertEqual(plain.sha256, SHA256.hash(data: Data("a\nb\n".utf8)).map { String(format: "%02x", $0) }.joined())
        XCTAssertEqual(FileContents.decode(Data("a\r\nb".utf8)).lineEnding, .crlf)
        XCTAssertEqual(FileContents.decode(Data("a\rb".utf8)).lineEnding, .cr)
        XCTAssertEqual(FileContents.decode(Data("no break".utf8)).lineEnding, .lf)
        let bom = FileContents.decode(Data([0xEF, 0xBB, 0xBF]) + Data("ünï\n".utf8))
        XCTAssertEqual(bom.kind, .text("ünï\n"))
        XCTAssertTrue(bom.hasBOM)
        XCTAssertEqual(FileContents.decode(Data([0x50, 0x4B, 0x03, 0x04, 0x00, 0x01])).kind, .unsupported(reason: "binary"))
        XCTAssertEqual(FileContents.decode(Data([0x63, 0x61, 0x66, 0xE9])).kind, .unsupported(reason: "not UTF-8 text"))
        XCTAssertEqual(FileContents.decode(Data(repeating: 0x61, count: 11), limit: 10).kind, .tooLarge(bytes: 11, limit: 10))
        XCTAssertEqual(FileContents.decode(Data(), limit: 10).kind, .text(""))

        // Reading on this Mac and through the login-shell ssh fixture gives the same answers.
        let fm = FileManager.default
        let base = PathBoundary.canonical(NSTemporaryDirectory())! + "/uherdr-read-\(UUID().uuidString)"
        let root = base + "/space"
        defer {
            chmod(root + "/secret.txt", 0o644)
            try? fm.removeItem(atPath: base)
        }
        try fm.createDirectory(atPath: root + "/dir", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: base + "/outside", withIntermediateDirectories: true)
        let swift = Data("struct A {}\r\n".utf8)
        fm.createFile(atPath: root + "/it's ünï.swift", contents: swift)
        fm.createFile(atPath: root + "/big.log", contents: Data(repeating: 0x61, count: 64))
        fm.createFile(atPath: root + "/secret.txt", contents: Data("x".utf8))
        chmod(root + "/secret.txt", 0o000)
        fm.createFile(atPath: base + "/outside/env", contents: Data("TOKEN".utf8))
        try fm.createSymbolicLink(atPath: root + "/link-out", withDestinationPath: "../outside/env")
        try fm.createSymbolicLink(atPath: root + "/link-in", withDestinationPath: "it's ünï.swift")
        // "evil\n" is a plain file; "evil" leads outside. Reading the first must never serve the second.
        fm.createFile(atPath: root + "/evil\n", contents: Data("inside".utf8))
        try fm.createSymbolicLink(atPath: root + "/evil", withDestinationPath: "../outside/env")
        let boundary = try PathBoundary(root: root)
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../Fixtures/ssh-shell-fixture.py").standardized.path
        let profile = DeviceProfile(name: "Fixture box", kind: .ssh, host: "dev-box", executable: "/tmp/herdr")

        let local = try FileReader.readLocal(root + "/it's ünï.swift", in: boundary)
        XCTAssertEqual(local.kind, .text("struct A {}\r\n"))
        XCTAssertEqual(local.lineEnding, .crlf)
        XCTAssertEqual(try FileReader.readLocal(root + "/link-in", in: boundary), local)
        XCTAssertEqual(try FileReader.readLocal(root + "/big.log", in: boundary, limit: 10).kind, .tooLarge(bytes: 64, limit: 10))
        func expectLocal(_ path: String, _ expected: FileListingError) {
            XCTAssertThrowsError(try FileReader.readLocal(path, in: boundary)) { XCTAssertEqual($0 as? FileListingError, expected) }
        }
        expectLocal(root + "/link-out", .outsideSpace(root + "/link-out"))
        // A link in the space may be opened (read-only) even though its target is outside;
        // nothing else outside the space can, even when asked.
        XCTAssertEqual(try FileReader.readLocal(root + "/link-out", in: boundary, allowingLinkOutside: true).kind, .text("TOKEN"))
        XCTAssertThrowsError(try FileReader.readLocal(base + "/outside/env", in: boundary, allowingLinkOutside: true)) {
            XCTAssertEqual($0 as? FileListingError, .outsideSpace(base + "/outside/env"))
        }
        expectLocal(root + "/dir", .notFile(root + "/dir"))
        expectLocal(root + "/gone", .missing(root + "/gone"))
        expectLocal(root + "/secret.txt", .denied(root + "/secret.txt"))

        for shellPath in RemoteFileListingTests.loginShells where fm.isExecutableFile(atPath: shellPath) {
            let shell = RemoteShell(profile: profile, ssh: fixture,
                                    environment: ProcessInfo.processInfo.environment.merging(["UHERDR_FIXTURE_SHELL": shellPath]) { $1 })
            XCTAssertEqual(try await FileReader.readRemote(root + "/it's ünï.swift", root: root, shell: shell), local)
            XCTAssertEqual(try await FileReader.readRemote(root + "/link-in", root: root, shell: shell), local)
            XCTAssertEqual(try await FileReader.readRemote(root + "/evil\n", root: root, shell: shell).kind, .text("inside"))
            XCTAssertEqual(try await FileReader.readRemote(root + "/big.log", root: root, shell: shell, limit: 10).kind, .tooLarge(bytes: 64, limit: 10))
            XCTAssertEqual(try await FileReader.readRemote(root + "/link-out", root: root, shell: shell, allowingLinkOutside: true).kind, .text("TOKEN"))
            do {
                _ = try await FileReader.readRemote(base + "/outside/env", root: root, shell: shell, allowingLinkOutside: true)
                XCTFail("A plain file outside the space must stay refused")
            } catch { XCTAssertEqual(error as? FileListingError, .outsideSpace(base + "/outside/env")) }
            for (path, expected) in [(root + "/link-out", FileListingError.outsideSpace(root + "/link-out")),
                                     (root + "/dir", .notFile(root + "/dir")),
                                     (root + "/gone", .missing(root + "/gone")),
                                     (root + "/secret.txt", .denied(root + "/secret.txt"))] {
                do {
                    _ = try await FileReader.readRemote(path, root: root, shell: shell)
                    XCTFail("Expected \(expected)")
                } catch { XCTAssertEqual(error as? FileListingError, expected) }
            }
        }
        print("PASS: file contents: UTF-8, BOM, line endings, binary, non-UTF-8, size cap, fingerprint; local and SSH reads agree, links, and errors")
    }
}
