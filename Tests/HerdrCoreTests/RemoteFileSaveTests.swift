import Foundation
import HerdrCore

enum RemoteFileSaveTests {
    static func run() async throws {
        let fm = FileManager.default
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../Fixtures/ssh-shell-fixture.py").standardized.path
        let profile = DeviceProfile(name: "Fixture box", kind: .ssh, host: "dev-box", executable: "/tmp/herdr")
        for shellPath in ["/bin/sh", "/bin/dash"] where fm.isExecutableFile(atPath: shellPath) {
            let shell = RemoteShell(profile: profile, ssh: fixture,
                                    environment: ProcessInfo.processInfo.environment.merging(["UHERDR_FIXTURE_SHELL": shellPath]) { $1 })
            let base = PathBoundary.canonical(NSTemporaryDirectory())! + "/uherdr-rsave-\(UUID().uuidString)"
            let root = base + "/space"
            defer {
                chmod(root + "/locked", 0o755)
                try? fm.removeItem(atPath: base)
            }
            try fm.createDirectory(atPath: root + "/locked", withIntermediateDirectories: true)
            try fm.createDirectory(atPath: base + "/outside", withIntermediateDirectories: true)
            func read(_ path: String, outside: Bool = false) async throws -> FileContents {
                try await FileReader.readRemote(path, root: root, shell: shell, allowingLinkOutside: outside)
            }
            func bytes(_ path: String) -> Data { fm.contents(atPath: path) ?? Data() }
            func expectError(_ wanted: FileSaveError, _ body: () async throws -> Void) async {
                do { try await body(); XCTFail("Expected \(wanted)") } catch { XCTAssertEqual(error as? FileSaveError, wanted) }
            }

            // Normal save: CRLF and mode kept, the device's hash checked.
            let file = root + "/it's ünï.swift"
            fm.createFile(atPath: file, contents: Data("one\r\ntwo\r\n".utf8))
            chmod(file, 0o640)
            let opened = try await read(file)
            let saved = try await RemoteFileSaver.save("one\nTWO\n", to: file, root: root, shell: shell, baseline: opened)
            XCTAssertEqual(bytes(file), Data("one\r\nTWO\r\n".utf8))
            XCTAssertEqual(saved, try await read(file))
            XCTAssertEqual((try fm.attributesOfItem(atPath: file)[.posixPermissions] as? NSNumber)?.intValue, 0o640)

            // Changed on disk: refused and untouched; overwrite on request.
            fm.createFile(atPath: file, contents: Data("agent\r\n".utf8))
            await expectError(.conflict) { _ = try await RemoteFileSaver.save("mine\n", to: file, root: root, shell: shell, baseline: saved) }
            XCTAssertEqual(bytes(file), Data("agent\r\n".utf8))
            _ = try await RemoteFileSaver.save("mine\n", to: file, root: root, shell: shell, baseline: saved, mode: .overwrite)
            XCTAssertEqual(bytes(file), Data("mine\r\n".utf8))

            // Deleted after opening: a conflict, then written back on request.
            let gone = root + "/gone.txt"
            fm.createFile(atPath: gone, contents: Data("g".utf8))
            let goneOpened = try await read(gone)
            try fm.removeItem(atPath: gone)
            await expectError(.conflict) { _ = try await RemoteFileSaver.save("back", to: gone, root: root, shell: shell, baseline: goneOpened) }
            _ = try await RemoteFileSaver.save("back", to: gone, root: root, shell: shell, baseline: goneOpened, mode: .overwrite)
            XCTAssertEqual(bytes(gone), Data("back".utf8))

            // A link inside the space stays a link; a link outside is never written.
            fm.createFile(atPath: root + "/target.md", contents: Data("t".utf8))
            try fm.createSymbolicLink(atPath: root + "/link.md", withDestinationPath: "target.md")
            _ = try await RemoteFileSaver.save("via link", to: root + "/link.md", root: root, shell: shell, baseline: try await read(root + "/link.md"))
            XCTAssertEqual(bytes(root + "/target.md"), Data("via link".utf8))
            XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: root + "/link.md"), "target.md")
            fm.createFile(atPath: base + "/outside/env", contents: Data("TOKEN".utf8))
            try fm.createSymbolicLink(atPath: root + "/env", withDestinationPath: "../outside/env")
            let outsideOpened = try await read(root + "/env", outside: true)
            await expectError(.outsideSpace) { _ = try await RemoteFileSaver.save("x", to: root + "/env", root: root, shell: shell, baseline: outsideOpened) }
            XCTAssertEqual(bytes(base + "/outside/env"), Data("TOKEN".utf8))

            // Hard links, an unwritable folder and a read-only file.
            fm.createFile(atPath: root + "/a.txt", contents: Data("1".utf8))
            XCTAssertEqual(link(root + "/a.txt", root + "/b.txt"), 0)
            let linked = try await read(root + "/a.txt")
            await expectError(.hardLinked(count: 2)) { _ = try await RemoteFileSaver.save("2", to: root + "/a.txt", root: root, shell: shell, baseline: linked) }
            _ = try await RemoteFileSaver.save("2", to: root + "/a.txt", root: root, shell: shell, baseline: linked, mode: .inPlace)
            XCTAssertEqual(bytes(root + "/b.txt"), Data("2".utf8))
            fm.createFile(atPath: root + "/locked/conf.yml", contents: Data("a: 1".utf8))
            let lockedOpened = try await read(root + "/locked/conf.yml")
            chmod(root + "/locked", 0o555)
            await expectError(.folderNotWritable) { _ = try await RemoteFileSaver.save("a: 2", to: root + "/locked/conf.yml", root: root, shell: shell, baseline: lockedOpened) }
            _ = try await RemoteFileSaver.save("a: 2", to: root + "/locked/conf.yml", root: root, shell: shell, baseline: lockedOpened, mode: .inPlace)
            XCTAssertEqual(bytes(root + "/locked/conf.yml"), Data("a: 2".utf8))
            chmod(root + "/locked", 0o755)
            fm.createFile(atPath: root + "/ro.txt", contents: Data("r".utf8))
            chmod(root + "/ro.txt", 0o444)
            let readOnlyOpened = try await read(root + "/ro.txt")
            await expectError(.readOnly) { _ = try await RemoteFileSaver.save("w", to: root + "/ro.txt", root: root, shell: shell, baseline: readOnlyOpened) }
            XCTAssertEqual(bytes(root + "/ro.txt"), Data("r".utf8))
            let leftovers = ((try? fm.subpathsOfDirectory(atPath: root)) ?? []).filter { ($0 as NSString).lastPathComponent.hasPrefix(".uherdr-") }
            XCTAssertEqual(leftovers, [])
        }

        // ssh itself failing (exit 255) means the outcome is unknown, not "failed".
        let dead = NSTemporaryDirectory() + "uherdr-dead-ssh-\(UUID().uuidString).sh"
        try "#!/bin/sh\necho 'Connection reset by peer' >&2\nexit 255\n".write(toFile: dead, atomically: true, encoding: .utf8)
        chmod(dead, 0o755)
        defer { try? fm.removeItem(atPath: dead) }
        let deadShell = RemoteShell(profile: profile, ssh: dead)
        do {
            _ = try await RemoteFileSaver.save("x", to: "/tmp/x", root: "/tmp", shell: deadShell, baseline: FileContents.decode(Data("y".utf8)))
            XCTFail("Expected an unknown outcome")
        } catch {
            guard case .outcomeUnknown? = error as? FileSaveError else { XCTFail("Expected .outcomeUnknown, got \(error)"); return }
        }
        // Content that arrives incomplete (the connection dropped mid-transfer:
        // `cat` just sees an early end) never replaces or creates a file, in
        // any mode. A `cat` that drops the last byte stands in for the drop.
        let cutBase = PathBoundary.canonical(NSTemporaryDirectory())! + "/uherdr-rsave-cut-\(UUID().uuidString)"
        defer { try? fm.removeItem(atPath: cutBase) }
        let cutRoot = cutBase + "/space", cutBin = cutBase + "/bin"
        try fm.createDirectory(atPath: cutRoot, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: cutBin, withIntermediateDirectories: true)
        fm.createFile(atPath: cutBin + "/cat", contents: Data("#!/bin/sh\nif [ $# -eq 0 ]; then /bin/cat | /usr/bin/sed '$ s/.$//'; else /bin/cat \"$@\"; fi\n".utf8),
                      attributes: [.posixPermissions: 0o755])
        let env = ProcessInfo.processInfo.environment
        let cutting = RemoteShell(profile: profile, ssh: fixture, environment: env.merging(["PATH": cutBin + ":" + (env["PATH"] ?? "/usr/bin:/bin")]) { $1 })
        let plain = RemoteShell(profile: profile, ssh: fixture)
        let target = cutRoot + "/keep.txt"
        fm.createFile(atPath: target, contents: Data("original\n".utf8))
        let baseline = try await FileReader.readRemote(target, root: cutRoot, shell: plain)
        for mode in [SaveMode.safe, .overwrite, .inPlace] {
            do {
                _ = try await RemoteFileSaver.save("replacement text\n", to: target, root: cutRoot, shell: cutting, baseline: baseline, mode: mode)
                XCTFail("Expected a failed write in \(mode)")
            } catch {
                guard case .failed? = error as? FileSaveError else { XCTFail("Expected .failed, got \(error)"); return }
            }
            XCTAssertEqual(fm.contents(atPath: target), Data("original\n".utf8))
        }
        do {
            _ = try await RemoteFileSaver.save("new file\n", to: cutRoot + "/new.txt", root: cutRoot, shell: cutting, baseline: FileContents.decode(Data()), mode: .overwrite)
            XCTFail("Expected a failed create")
        } catch {
            guard case .failed? = error as? FileSaveError else { XCTFail("Expected .failed, got \(error)"); return }
        }
        XCTAssertTrue(!fm.fileExists(atPath: cutRoot + "/new.txt"))
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: cutRoot), ["keep.txt"]) // no temp files left
        print("PASS: SSH save (sh, dash): line endings and mode kept, changed-on-disk refused, overwrite, deleted file, links, hard links, unwritable folder, read-only file, no temp files, ssh failure is an unknown outcome, incomplete content never replaces or creates a file")
    }
}
