import Foundation
import HerdrCore

enum RipgrepInstallerTests {
    static func run() async throws {
        XCTAssertEqual(RipgrepInstaller.Platform(uname: "Linux x86_64"), .linuxX86_64)
        XCTAssertEqual(RipgrepInstaller.Platform(uname: "Linux aarch64\n"), .linuxAArch64)
        XCTAssertEqual(RipgrepInstaller.Platform(uname: "Darwin arm64"), .macOS)
        XCTAssertTrue(RipgrepInstaller.Platform(uname: "Linux riscv64") == nil && RipgrepInstaller.Platform(uname: "") == nil)

        let fm = FileManager.default
        let base = PathBoundary.canonical(NSTemporaryDirectory())! + "/uherdr-rg-install-\(UUID().uuidString)"
        defer { try? fm.removeItem(atPath: base) }
        let home = base + "/home", resources = URL(fileURLWithPath: base + "/resources")
        try fm.createDirectory(atPath: home, withIntermediateDirectories: true)
        try fm.createDirectory(at: resources, withIntermediateDirectories: true)
        // A stand-in "ripgrep": a script that prints a version line.
        let fake = Data("#!/bin/sh\necho 'ripgrep 15.2.0 (stand-in)'\n".utf8)
        try fake.write(to: resources.appendingPathComponent("rg"))
        let gz = Process()
        gz.executableURL = URL(fileURLWithPath: "/bin/sh")
        gz.arguments = ["-c", "gzip -n -c \"$1\" > \"$2\"", "sh", resources.appendingPathComponent("rg").path, resources.appendingPathComponent("rg-linux-x86_64.gz").path]
        try gz.run(); gz.waitUntilExit()
        XCTAssertEqual(try RipgrepInstaller.binary(for: .linuxX86_64, in: resources), fake)
        XCTAssertEqual(try RipgrepInstaller.binary(for: .macOS, in: resources), fake)
        do { _ = try RipgrepInstaller.binary(for: .linuxAArch64, in: resources); preconditionFailure("expected notBundled") }
        catch let error as RipgrepInstaller.InstallError { XCTAssertEqual(error, .notBundled) }

        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../Fixtures/ssh-shell-fixture.py").standardized.path
        let profile = DeviceProfile(name: "Fixture box", kind: .ssh, host: "dev-box", executable: "/tmp/herdr")
        let env = ProcessInfo.processInfo.environment
        let shell = RemoteShell(profile: profile, ssh: fixture, environment: env.merging(["HOME": home]) { $1 })
        let platform = try await RipgrepInstaller.platform(of: shell)
        XCTAssertEqual(platform, .macOS) // the fixture runs on this Mac
        let target = home + "/.local/share/uherdr/bin/rg"
        XCTAssertEqual(try await RipgrepInstaller.install(fake, on: shell), "ripgrep 15.2.0 (stand-in)")
        XCTAssertEqual(fm.contents(atPath: target), fake)
        XCTAssertEqual((try fm.attributesOfItem(atPath: target)[.posixPermissions] as? NSNumber)?.intValue, 0o755)
        // Search finds the installed copy without PATH.
        let found = try await RemoteShell(profile: profile, ssh: fixture, environment: env.merging(["HOME": home]) { $1 })
            .run("[ -x \"$HOME/.local/share/uherdr/bin/rg\" ] && echo yes", [])
        XCTAssertEqual(String(decoding: found.stdout, as: UTF8.self), "yes\n")

        // A copy that arrives changed is refused and leaves the old one in place.
        let bin = base + "/bin"
        try fm.createDirectory(atPath: bin, withIntermediateDirectories: true)
        fm.createFile(atPath: bin + "/cat", contents: Data("#!/bin/sh\n/bin/cat \"$@\"; printf x\n".utf8), attributes: [.posixPermissions: 0o755])
        let corrupting = RemoteShell(profile: profile, ssh: fixture, environment: env.merging(["HOME": home, "PATH": bin + ":" + (env["PATH"] ?? "/usr/bin:/bin")]) { $1 })
        do { _ = try await RipgrepInstaller.install(Data("#!/bin/sh\necho other\n".utf8), on: corrupting); preconditionFailure("expected a hash mismatch") }
        catch let error as RipgrepInstaller.InstallError { XCTAssertEqual(error, .hashMismatch) }
        XCTAssertEqual(fm.contents(atPath: target), fake)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: home + "/.local/share/uherdr/bin"), ["rg"]) // no temp file left

        // No sha256sum or shasum on the device.
        let bare = base + "/bare"
        try fm.createDirectory(atPath: bare, withIntermediateDirectories: true)
        let python = (env["PATH"] ?? "").split(separator: ":").map { $0 + "/python3" }.first { fm.isExecutableFile(atPath: $0) } ?? "/usr/bin/python3"
        for tool in ["/bin/sh", "/usr/bin/env", "/bin/mkdir", "/usr/bin/mktemp", "/bin/cat", "/usr/bin/cut", "/bin/chmod", "/bin/mv", "/usr/bin/head", "/bin/rm", python] {
            try fm.createSymbolicLink(atPath: bare + "/" + (tool as NSString).lastPathComponent, withDestinationPath: tool)
        }
        let noHash = RemoteShell(profile: profile, ssh: fixture, environment: env.merging(["HOME": home, "PATH": bare]) { $1 })
        do { _ = try await RipgrepInstaller.install(fake, on: noHash, folder: base + "/elsewhere"); preconditionFailure("expected no hash tool") }
        catch let error as RipgrepInstaller.InstallError { XCTAssertEqual(error, .noHashTool) }
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: base + "/elsewhere"), [])
        print("PASS: ripgrep install: platforms, bundled builds unpacked, copied and checked by hash, executable, corrupted copy refused, no hash tool, no temp files left")
    }
}
