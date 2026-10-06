import Foundation
import HerdrCore

enum ChangeTreeTests {
    static func run() throws {
        func change(_ path: String) -> GitChange { GitChange(group: .changes, path: path, letter: "M") }
        let changes = ["app/Sources/HerdrMac/b.swift", "app/Sources/HerdrMac/a.swift", "app/Sources/HerdrCore/Models.swift",
                       "app/Tests/HerdrCoreTests/T.swift", "app/README.md", "app/file10.txt", "app/file2.txt"].map(change)
        func render(_ nodes: [ChangeTree.Node], _ depth: Int = 0) -> [String] {
            nodes.flatMap { node -> [String] in
                let pad = String(repeating: "  ", count: depth)
                switch node {
                case let .folder(name, path, children): return [pad + name + "/ (" + path + ")"] + render(children, depth + 1)
                case let .file(_, name): return [pad + name]
                }
            }
        }
        XCTAssertEqual(render(ChangeTree.build(changes, prefix: "app/")), [
            "Sources/ (Sources)",
            "  HerdrCore/ (Sources/HerdrCore)",
            "    Models.swift",
            "  HerdrMac/ (Sources/HerdrMac)",
            "    a.swift",
            "    b.swift",
            "Tests/HerdrCoreTests/ (Tests/HerdrCoreTests)",
            "  T.swift",
            "file2.txt",
            "file10.txt",
            "README.md",
        ])
        // At the repository root, and node ids stay distinct per group.
        XCTAssertEqual(render(ChangeTree.build([change("a/b/c.txt")], prefix: "")), ["a/b/ (a/b)", "  c.txt"])
        let staged = GitChange(group: .staged, path: "x", letter: "M")
        XCTAssertTrue(ChangeTree.Node.file(staged, name: "x").id != ChangeTree.Node.file(change("x"), name: "x").id)
        print("PASS: change tree: folders relative to the space, single-folder chains joined, folders first, natural order")
    }
}
