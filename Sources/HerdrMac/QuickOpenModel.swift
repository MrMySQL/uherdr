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

    @Published private(set) var files: Files = .loading { didSet { scheduleRanking() } }
    @Published var query = "" { didSet { if query != oldValue { selection = 0; scheduleRanking() } } }
    @Published var selection = 0
    /// Paths (relative) of files open in tabs, and those with unsaved edits.
    var open: Set<String> = [] { didSet { if open != oldValue { scheduleRanking() } } }
    var unsaved: Set<String> = []

    @Published private(set) var matches: [FuzzyMatcher.Match] = []
    var rankingDelay: Duration = .milliseconds(100)
    private(set) var rankingRuns = 0
    private var ranking: Task<Void, Never>?
    private var rankingVersion = 0
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

    private func scheduleRanking() {
        ranking?.cancel()
        rankingVersion += 1
        matches = []
        guard case let .loaded(paths) = files else { return }
        let query = query, open = open, version = rankingVersion, delay = rankingDelay
        ranking = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard !Task.isCancelled else { return }
            let worker = Task.detached {
                FuzzyMatcher.rank(query, paths, open: open, limit: 50, isCancelled: { Task.isCancelled })
            }
            let result = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard !Task.isCancelled, let self, version == self.rankingVersion else { return }
            self.rankingRuns += 1
            self.matches = result
        }
    }

    func cancel() {
        loading?.cancel(); ranking?.cancel()
        rankingVersion += 1
    }

    func move(_ delta: Int) {
        let count = matches.count
        guard count > 0 else { return }
        selection = (selection + delta + count) % count
    }
}
