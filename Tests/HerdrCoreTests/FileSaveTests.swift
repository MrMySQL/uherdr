import Foundation
import HerdrCore

enum FileSaveTests {
    static func run() throws {
        // Encoding keeps the file's line ending and BOM whatever the editor produced.
        XCTAssertEqual(FileContents.encode("a\nb\r\nc\rd", lineEnding: .crlf, bom: false), Data("a\r\nb\r\nc\r\nd".utf8))
        XCTAssertEqual(FileContents.encode("a\r\nb", lineEnding: .lf, bom: true), Data([0xEF, 0xBB, 0xBF]) + Data("a\nb".utf8))
        XCTAssertEqual(FileContents.encode("a\nb", lineEnding: .cr, bom: false), Data("a\rb".utf8))

        let fm = FileManager.default
        let base = PathBoundary.canonical(NSTemporaryDirectory())! + "/uherdr-save-\(UUID().uuidString)"
        let root = base + "/space"
        defer {
            chmod(root + "/locked", 0o755)
            try? fm.removeItem(atPath: base)
        }
        try fm.createDirectory(atPath: root + "/locked", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: base + "/outside", withIntermediateDirectories: true)
        let boundary = try PathBoundary(root: root)
        func read(_ path: String) throws -> FileContents { try FileReader.readLocal(path, in: boundary) }
        func bytes(_ path: String) -> Data { fm.contents(atPath: path) ?? Data() }
        func leftovers() -> [String] {
            ((try? fm.subpathsOfDirectory(atPath: root)) ?? []).filter { ($0 as NSString).lastPathComponent.hasPrefix(".uherdr-") }
        }

        // A normal save keeps CRLF and the file's mode.
        let file = root + "/it's.swift"
        fm.createFile(atPath: file, contents: Data("one\r\ntwo\r\n".utf8))
        chmod(file, 0o640)
        let opened = try read(file)
        let saved = try LocalFileSaver.save("one\nTWO\nthree\n", to: file, in: boundary, baseline: opened)
        XCTAssertEqual(bytes(file), Data("one\r\nTWO\r\nthree\r\n".utf8))
        XCTAssertEqual(saved, try read(file))
        XCTAssertEqual((try fm.attributesOfItem(atPath: file)[.posixPermissions] as? NSNumber)?.intValue, 0o640)

        // Changed on disk since it was opened: refused and untouched, unless the user overwrites.
        fm.createFile(atPath: file, contents: Data("agent edit\r\n".utf8))
        XCTAssertThrowsError(try LocalFileSaver.save("mine\n", to: file, in: boundary, baseline: saved)) {
            XCTAssertEqual($0 as? FileSaveError, .conflict)
        }
        XCTAssertEqual(bytes(file), Data("agent edit\r\n".utf8))
        XCTAssertThrowsError(try LocalFileSaver.save("mine\n", to: file, in: boundary, baseline: saved, mode: .inPlace)) {
            XCTAssertEqual($0 as? FileSaveError, .conflict)
        }
        XCTAssertEqual(bytes(file), Data("agent edit\r\n".utf8))
        _ = try LocalFileSaver.save("mine\n", to: file, in: boundary, baseline: saved, mode: .overwrite)
        XCTAssertEqual(bytes(file), Data("mine\r\n".utf8))

        // BOM survives; deleted after opening is a conflict, then can be written back.
        let bomFile = root + "/bom.txt"
        fm.createFile(atPath: bomFile, contents: Data([0xEF, 0xBB, 0xBF]) + Data("x".utf8))
        let bomOpened = try read(bomFile)
        _ = try LocalFileSaver.save("y", to: bomFile, in: boundary, baseline: bomOpened)
        XCTAssertEqual(bytes(bomFile), Data([0xEF, 0xBB, 0xBF]) + Data("y".utf8))
        let bomNow = try read(bomFile)
        try fm.removeItem(atPath: bomFile)
        XCTAssertThrowsError(try LocalFileSaver.save("z", to: bomFile, in: boundary, baseline: bomNow)) { XCTAssertEqual($0 as? FileSaveError, .conflict) }
        _ = try LocalFileSaver.save("z", to: bomFile, in: boundary, baseline: bomNow, mode: .overwrite)
        XCTAssertEqual(bytes(bomFile), Data([0xEF, 0xBB, 0xBF]) + Data("z".utf8))

        // Saving through a link inside the space updates the target and keeps the link.
        let target = root + "/target.md"
        fm.createFile(atPath: target, contents: Data("t".utf8))
        try fm.createSymbolicLink(atPath: root + "/link.md", withDestinationPath: "target.md")
        _ = try LocalFileSaver.save("via link", to: root + "/link.md", in: boundary, baseline: try read(root + "/link.md"))
        XCTAssertEqual(bytes(target), Data("via link".utf8))
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: root + "/link.md"), "target.md")

        // A link pointing outside the space is never written.
        fm.createFile(atPath: base + "/outside/env", contents: Data("TOKEN".utf8))
        try fm.createSymbolicLink(atPath: root + "/env", withDestinationPath: "../outside/env")
        let outsideOpened = try FileReader.readLocal(root + "/env", in: boundary, allowingLinkOutside: true)
        XCTAssertThrowsError(try LocalFileSaver.save("x", to: root + "/env", in: boundary, baseline: outsideOpened)) {
            XCTAssertEqual($0 as? FileSaveError, .outsideSpace)
        }
        XCTAssertEqual(bytes(base + "/outside/env"), Data("TOKEN".utf8))

        // Hard links: refused by default, written in place when the user agrees (both names change).
        let first = root + "/a.txt"
        fm.createFile(atPath: first, contents: Data("1".utf8))
        XCTAssertEqual(link(first, root + "/b.txt"), 0)
        let linked = try read(first)
        XCTAssertThrowsError(try LocalFileSaver.save("2", to: first, in: boundary, baseline: linked)) {
            XCTAssertEqual($0 as? FileSaveError, .hardLinked(count: 2))
        }
        _ = try LocalFileSaver.save("2", to: first, in: boundary, baseline: linked, mode: .inPlace)
        XCTAssertEqual(bytes(root + "/b.txt"), Data("2".utf8))

        XCTAssertThrowsError(try LocalFileSaver.save("3", to: first, in: boundary, baseline: linked, mode: .inPlace)) {
            XCTAssertEqual($0 as? FileSaveError, .conflict)
        }
        _ = try LocalFileSaver.save("3", to: first, in: boundary, baseline: linked, mode: .overwriteInPlace)
        XCTAssertEqual(bytes(root + "/b.txt"), Data("3".utf8))

        // A writable file in a folder you can't write to: refused, then in place on request.
        let lockedFile = root + "/locked/conf.yml"
        fm.createFile(atPath: lockedFile, contents: Data("a: 1".utf8))
        let lockedOpened = try read(lockedFile)
        chmod(root + "/locked", 0o555)
        XCTAssertThrowsError(try LocalFileSaver.save("a: 2", to: lockedFile, in: boundary, baseline: lockedOpened)) {
            XCTAssertEqual($0 as? FileSaveError, .folderNotWritable)
        }
        _ = try LocalFileSaver.save("a: 2", to: lockedFile, in: boundary, baseline: lockedOpened, mode: .inPlace)
        XCTAssertEqual(bytes(lockedFile), Data("a: 2".utf8))
        // A read-only file is refused even though its folder is writable.
        let readOnly = root + "/ro.txt"
        fm.createFile(atPath: readOnly, contents: Data("r".utf8))
        chmod(readOnly, 0o444)
        XCTAssertThrowsError(try LocalFileSaver.save("w", to: readOnly, in: boundary, baseline: try read(readOnly))) {
            XCTAssertEqual($0 as? FileSaveError, .readOnly)
        }
        XCTAssertEqual(bytes(readOnly), Data("r".utf8))
        XCTAssertEqual(leftovers(), [])
        print("PASS: local save: read-only refused, line endings and BOM kept, mode kept, changed-on-disk refused, overwrite, deleted file, symlink kept, outside link never written, hard links and unwritable folders, no temp files left")
    }
}
