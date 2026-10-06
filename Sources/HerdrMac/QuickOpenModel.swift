import Foundation
import HerdrCore

/// Whether the Quick Open palette is up, for the menus: while it is, ⌘↩ means
/// "open and keep tab" there, not Zoom Pane.
@MainActor
final class PaletteState: ObservableObject {
    static let shared = PaletteState()
    @Published var quickOpenShown = false
}

/// Quick Open's file list for the shown space's folder. The list is read when
/// the palette opens (kept from last time meanwhile), ranked as you type.
@MainActor
final class QuickOpenModel: ObservableObject {
    enum Files: Equatable { case loading, loaded([String]), failed(String) }

    @Published private(set) var files: Files = .loading
    @Published var query = "" { didSet { if query != oldValue { selection = 0 } } }
    @Published var selection = 0
    /// Paths (relative) of files open in tabs, and those with unsaved edits.
    var open: Set<String> = []
    var unsaved: Set<String> = []

    private var key = ""
    private var loading: Task<Void, Never>?

    /// Starts reading the folder's files; an earlier list for the same folder
    /// stays visible until the new one arrives.
    func load(root: String, runner: ScriptRunner, ripgrep: String?, key newKey: String) {
        if newKey != key { files = .loading; key = newKey }
        query = ""
        loading?.cancel()
        loading = Task { [weak self] in
            let result: Files
            do { result = .loaded(try await FileList.files(root: root, runner: runner, ripgrep: ripgrep)) } catch {
                result = .failed(error.localizedDescription)
            }
            guard !Task.isCancelled, let self, self.key == newKey else { return }
            self.files = result
        }
    }

    var total: Int { if case let .loaded(paths) = files { return paths.count } else { return 0 } }

    var matches: [FuzzyMatcher.Match] {
        guard case let .loaded(paths) = files else { return [] }
        return FuzzyMatcher.rank(query, paths, open: open, limit: 50)
    }

    func move(_ delta: Int) {
        let count = matches.count
        guard count > 0 else { return }
        selection = (selection + delta + count) % count
    }
}
