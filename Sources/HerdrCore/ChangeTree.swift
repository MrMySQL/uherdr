import Foundation

/// The Changes panel's Tree layout for one group: folders relative to the
/// space's folder, a chain of folders with nothing else in them joined into one
/// row ("Sources/HerdrMac"), folders before files, each sorted by name.
public enum ChangeTree {
    public indirect enum Node: Equatable, Sendable, Identifiable {
        case folder(name: String, path: String, children: [Node])
        case file(GitChange, name: String)

        public var id: String {
            switch self {
            case let .folder(_, path, _): return "d:" + path
            case let .file(change, _): return "f:" + change.id
            }
        }
    }

    /// `prefix` is the space folder's place in the repository ("" or ending in "/").
    public static func build(_ changes: [GitChange], prefix: String) -> [Node] {
        final class Folder {
            var folders: [String: Folder] = [:]
            var files: [(GitChange, String)] = []
        }
        let top = Folder()
        for change in changes {
            let relative = String(change.path.dropFirst(change.path.hasPrefix(prefix) ? prefix.count : 0))
            var parts = relative.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            guard let name = parts.popLast() else { continue }
            var folder = top
            for part in parts {
                if let next = folder.folders[part] { folder = next } else {
                    let next = Folder()
                    folder.folders[part] = next
                    folder = next
                }
            }
            folder.files.append((change, name))
        }
        func nodes(_ folder: Folder, path: String) -> [Node] {
            let folders = folder.folders.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { name -> Node in
                var label = name, full = path.isEmpty ? name : path + "/" + name
                var inner = folder.folders[name]!
                while inner.files.isEmpty, inner.folders.count == 1, let (next, child) = inner.folders.first {
                    label += "/" + next
                    full += "/" + next
                    inner = child
                }
                return .folder(name: label, path: full, children: nodes(inner, path: full))
            }
            let files = folder.files.sorted { $0.1.localizedStandardCompare($1.1) == .orderedAscending }.map { Node.file($0.0, name: $0.1) }
            return folders + files
        }
        return nodes(top, path: "")
    }
}
