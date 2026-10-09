import Foundation
import HerdrCore
@main struct ChangeSelectionTests {
 @MainActor static func main() throws {
  let root = PathBoundary.canonical(NSTemporaryDirectory())! + "/selection-review-" + UUID().uuidString
  let fm = FileManager.default
  try fm.createDirectory(atPath: root + "/real", withIntermediateDirectories: true)
  defer { try? fm.removeItem(atPath: root) }
  try fm.createSymbolicLink(atPath: root + "/alias", withDestinationPath: root + "/real")
  let canonical = try PathBoundary(root: root + "/alias").root
  let change = GitChange(group: .changes, path: "a.swift", letter: "M")
  let status = GitChanges(repositoryRoot: root + "/alias", prefix: "", branch: GitBranch(), changes: [change], outside: 0)
  let spec = EditorStore.DiffSpec(change: change, path: canonical + "/a.swift", root: canonical, repository: status.repositoryRoot)
  precondition(RightSidebarView.changeTabID(change, changes: status, root: canonical) == EditorStore.diffID(spec))
  // Both sides of the selection contract must receive the same spelling.
  let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Sources/HerdrMac")
  let rows = try String(contentsOf: sources.appendingPathComponent("ChangesView.swift"))
  let sidebar = try String(contentsOf: sources.appendingPathComponent("RightSidebarView.swift"))
  precondition(rows.components(separatedBy: "changeTabID(change, changes: changes, root: root)").count - 1 == 1)
  precondition(sidebar.components(separatedBy: "activeID: activeEditorPath, root: files.canonicalRoot").count - 1 == 1)
  print("PASS: symlink selection IDs and canonical-root wiring")
 }
}
