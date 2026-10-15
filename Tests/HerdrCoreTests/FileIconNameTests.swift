import Foundation
import HerdrCore

enum FileIconNameTests {
    static func run() {
        let cases: [(String, Bool, String)] = [
            ("SessionStore.swift", false, "swift"), ("page.tsx", false, "react_ts"), ("next.config.ts", false, "typescript"),
            ("package.json", false, "nodejs"), ("Package.resolved", false, "json"), (".gitignore", false, "git"),
            ("LICENSE", false, "certificate"), ("README.md", false, "readme"), ("notes.md", false, "markdown"),
            (".env.local", false, "tune"), ("Dockerfile", false, "docker"), ("build-app.sh", false, "console"),
            ("claude.png", false, "image"), ("guide.PDF", false, "pdf"), ("no-extension", false, "document"),
            ("weird.unknownext", false, "document"),
            ("Sources", true, "folder-src"), ("Tests", true, "folder-test"), ("docs", true, "folder-docs"),
            ("node_modules", true, "folder-node"), (".build", true, "folder-dist"), ("HerdrMac", true, "folder"),
        ]
        for (name, isDirectory, expected) in cases {
            XCTAssertEqual(FileIconName.name(for: name, isDirectory: isDirectory), expected)
        }
        // Every name the mapping can produce exists in the bundled icon folder.
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Sources/HerdrMac/Resources/FileIcons").standardized
        let bundled = Set(((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0.hasSuffix(".svg") }.map { String($0.dropLast(4)) })
        let missing = FileIconName.allNames.subtracting(bundled)
        XCTAssertTrue(bundled.count > 50)
        XCTAssertEqual(missing, [])
        print("PASS: file icons: names, extensions, special folders, and every mapped icon is bundled (\(FileIconName.allNames.count) of \(bundled.count))")
    }
}
