import Foundation
import HerdrCore

enum WorkspaceFilesTests {
    static func run() throws {
        let fm = FileManager.default
        let base = PathBoundary.canonical(NSTemporaryDirectory())! + "/uherdr-files-\(UUID().uuidString)"
        let root = base + "/space"
        defer {
            chmod(root + "/locked", 0o755)
            try? fm.removeItem(atPath: base)
        }
        for dir in ["space/Sources", "space/.git", "space/locked", "space/empty", "space-other", "outside"] {
            try fm.createDirectory(atPath: base + "/" + dir, withIntermediateDirectories: true)
        }
        let names = ["file10.txt", "file2.txt", "README.md", ".gitignore", "new\nline.txt", "ünï cødé.swift", "it's.md", ".uherdr-x.swift-123"]
        for name in names { fm.createFile(atPath: root + "/" + name, contents: Data("x".utf8)) }
        fm.createFile(atPath: base + "/outside/secret.env", contents: Data("x".utf8))
        try fm.createSymbolicLink(atPath: root + "/link-in", withDestinationPath: "Sources")
        try fm.createSymbolicLink(atPath: root + "/link-out", withDestinationPath: "../outside/secret.env")
        try fm.createSymbolicLink(atPath: root + "/link-dir-out", withDestinationPath: "../outside")
        try fm.createSymbolicLink(atPath: root + "/dangling", withDestinationPath: "nowhere")
        mkfifo(root + "/pipe", 0o600)
        chmod(root + "/locked", 0o000)

        // The boundary: component-wise, symlink-resolved containment.
        let boundary = try PathBoundary(root: base + "/space/../space")
        XCTAssertEqual(boundary.root, root)
        XCTAssertTrue(boundary.contains(root + "/Sources"))
        XCTAssertTrue(!boundary.contains(base + "/space-other"))
        XCTAssertTrue(!boundary.contains(root + "/../outside"))
        XCTAssertTrue(!boundary.contains(root + "/link-out"))
        XCTAssertTrue(boundary.contains(root + "/link-in"))
        XCTAssertTrue(!boundary.contains(root + "/does-not-exist"))
        XCTAssertEqual(boundary.relative(root + "/Sources"), "Sources")
        XCTAssertEqual(boundary.relative(root), "")
        XCTAssertTrue(boundary.relative(base + "/space-other") == nil)
        XCTAssertThrowsError(try PathBoundary(root: base + "/missing")) { XCTAssertEqual($0 as? FileListingError, .missing(base + "/missing")) }
        XCTAssertThrowsError(try PathBoundary(root: root + "/README.md")) { XCTAssertEqual($0 as? FileListingError, .notDirectory(root + "/README.md")) }

        // Listing: folders first, natural order, every odd name, no .git or save temp files.
        let entries = try LocalFileListing.list(root, in: boundary)
        let listed = entries.map(\.name)
        XCTAssertEqual(Array(listed.prefix(4)), ["empty", "link-in", "locked", "Sources"])
        XCTAssertTrue(!listed.contains(".git") && !listed.contains(".uherdr-x.swift-123"))
        for name in names where !LocalFileListing.isAlwaysHidden(name) { XCTAssertTrue(listed.contains(name)) }
        XCTAssertTrue(listed.firstIndex(of: "file2.txt")! < listed.firstIndex(of: "file10.txt")!)
        func kind(_ name: String) -> FileEntry.Kind? { entries.first { $0.name == name }?.kind }
        XCTAssertEqual(kind("link-in"), .symlink(target: "Sources", inside: true, isDirectory: true))
        XCTAssertEqual(kind("link-out"), .symlink(target: "../outside/secret.env", inside: false, isDirectory: false))
        XCTAssertEqual(kind("link-dir-out"), .symlink(target: "../outside", inside: false, isDirectory: true))
        XCTAssertEqual(kind("dangling"), .symlink(target: "nowhere", inside: false, isDirectory: false))
        XCTAssertEqual(kind("pipe"), .other)
        XCTAssertTrue(entries.first { $0.name == "link-in" }!.isExpandable)
        XCTAssertTrue(!entries.first { $0.name == "link-dir-out" }!.isExpandable)
        XCTAssertTrue(entries.first { $0.name == ".gitignore" }!.isHidden)

        // Errors are distinct: no permission, empty, gone, not a folder, outside the space.
        XCTAssertThrowsError(try LocalFileListing.list(root + "/locked", in: boundary)) { XCTAssertEqual($0 as? FileListingError, .denied(root + "/locked")) }
        XCTAssertEqual(try LocalFileListing.list(root + "/empty", in: boundary), [])
        XCTAssertThrowsError(try LocalFileListing.list(root + "/gone", in: boundary)) { XCTAssertEqual($0 as? FileListingError, .missing(root + "/gone")) }
        XCTAssertThrowsError(try LocalFileListing.list(root + "/README.md", in: boundary)) { XCTAssertEqual($0 as? FileListingError, .notDirectory(root + "/README.md")) }
        XCTAssertThrowsError(try LocalFileListing.list(root + "/link-dir-out", in: boundary)) { XCTAssertEqual($0 as? FileListingError, .outsideSpace(root + "/link-dir-out")) }
        XCTAssertThrowsError(try LocalFileListing.list(root + "/..", in: boundary)) { XCTAssertEqual($0 as? FileListingError, .outsideSpace(root + "/..")) }
        // A link to a folder inside the space can be expanded.
        XCTAssertEqual(try LocalFileListing.list(root + "/link-in", in: boundary), [])
        print("PASS: space boundary and local listing: containment, links in/out/dangling, odd names, natural order, permission/missing/outside errors")
    }
}
