import Foundation
import HerdrCore
@main struct FileTreeModelTests {
 @MainActor static func main() async throws {
  let root = PathBoundary.canonical(NSTemporaryDirectory())! + "/tree-review-" + UUID().uuidString
  let fm = FileManager.default
  try fm.createDirectory(atPath:root,withIntermediateDirectories:true)
  defer { try? fm.removeItem(atPath:root) }
  fm.createFile(atPath:root+"/old",contents:Data())
  let boundary = try PathBoundary(root:root)
  let old = try LocalFileListing.list(root,in:boundary)
  try fm.moveItem(atPath:root+"/old",toPath:root+"/new")
  let new = try LocalFileListing.list(root,in:boundary)
  var waiting: [CheckedContinuation<[FileEntry], Error>] = []
  let tree = FileTreeModel()
  tree.readFolder = { _ in try await withCheckedThrowingContinuation { waiting.append($0) } }
  tree.open(root:root)
  while waiting.count < 1 { await Task.yield() }
  tree.refresh()
  while waiting.count < 2 { await Task.yield() }
  waiting[1].resume(returning:new)
  for _ in 0..<100 { if tree.children(of:root) == new { break }; await Task.yield() }
  waiting[0].resume(returning:old)
  try await Task.sleep(for:.milliseconds(100))
  precondition(tree.children(of:root) == new, "An older same-generation load cannot overwrite a newer listing")
  precondition(tree.listedAt != nil)
  tree.open(root:nil)
  precondition(tree.listedAt == nil && tree.folders.isEmpty, "A new root clears the previous listing time")
  print("PASS: tree rejects old concurrent loads and clears listing time on open")
 }
}
