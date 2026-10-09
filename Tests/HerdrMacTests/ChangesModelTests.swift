import Foundation
import HerdrCore

@main struct ChangesModelTests {
    @MainActor static func main() async throws {
        let fm = FileManager.default
        let base = PathBoundary.canonical(NSTemporaryDirectory())! + "/uherdr-changes-\(UUID().uuidString)"
        defer { try? fm.removeItem(atPath: base) }
        let repo = base + "/repo", plain = base + "/plain"
        for folder in [repo, plain] { try fm.createDirectory(atPath: folder, withIntermediateDirectories: true) }
        func git(_ args: String...) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-c", "user.email=t@example.com", "-c", "user.name=Test", "-c", "init.defaultBranch=main", "-c", "commit.gpgsign=false", "-C", repo] + args
            process.environment = GitIgnoreCheck.environment()
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            precondition(process.terminationStatus == 0, "git \(args)")
        }
        try git("init", "-q")
        fm.createFile(atPath: repo + "/a.txt", contents: Data("1\n".utf8))
        try git("add", "a.txt")
        try git("commit", "-qm", "init")

        let model = ChangesModel()
        var changed = 0
        model.onChange = { changed += 1 }
        precondition(model.state == .idle)
        model.open(root: repo, runner: .local, key: "k1")
        precondition(model.state == .loading)
        await model.refresh()
        precondition(model.count == 0 && changed == 0, "The first read isn't a change")
        await model.refresh()
        precondition(changed == 0, "An unchanged status stays quiet")
        fm.createFile(atPath: repo + "/a.txt", contents: Data("2\n".utf8))
        await model.refresh()
        precondition(model.count == 1 && changed == 1, "A new status is published and reported")
        precondition(model.changes?.changes.first?.path == "a.txt")

        fm.createFile(atPath: repo + "/a.txt", contents: Data("3\n".utf8))
        await model.refresh()
        precondition(changed == 2, "Same-status content refresh invalidates open diffs")

        // The same key keeps everything; a new folder starts over.
        model.collapsed = ["g:Changes"]
        model.open(root: repo, runner: .local, key: "k1")
        precondition(model.count == 1 && model.collapsed == ["g:Changes"])
        model.open(root: plain, runner: .local, key: "k2")
        precondition(model.state == .loading && model.collapsed.isEmpty)
        await model.refresh()
        precondition(model.state == .failed(.notRepository))

        // A read for a folder that was replaced meanwhile is dropped.
        model.open(root: repo, runner: .local, key: "k3")
        let late = Task { await model.refresh() }
        try await Task.sleep(for: .milliseconds(2)) // the read is under way
        model.open(root: plain, runner: .local, key: "k4")
        await late.value
        precondition(model.state == .loading, "A stale read never shows")
        await model.refresh()
        precondition(model.state == .failed(.notRepository))

        // No folder: nothing to read.
        model.open(root: nil, runner: .local, key: "k5")
        await model.refresh()
        precondition(model.state == .idle)
        model.toggle("x"); precondition(model.collapsed == ["x"]); model.toggle("x"); precondition(model.collapsed.isEmpty)
        print("PASS: changes model: first read quiet, unchanged quiet, new status reported, same folder kept, new folder starts over, stale reads dropped, not a repository, no folder")
    }
}
