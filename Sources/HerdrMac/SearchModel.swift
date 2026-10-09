import Foundation
import HerdrCore

/// The Search panel's state for the shown space. Typing restarts the search
/// after a short pause; a new search cancels the one before (which stops
/// ripgrep). Files open with unsaved edits are searched in their tab's text.
@MainActor
final class SearchModel: ObservableObject {
    enum State: Equatable {
        case idle
        case searching
        case done(SearchOutcome, elapsed: Duration)
        case failed(SearchError)
    }

    struct FileGroup: Identifiable, Equatable {
        let path: String
        let hits: [SearchHit]
        let unsaved: Bool
        var id: String { path }
        var matchCount: Int { hits.reduce(0) { $0 + $1.ranges.count } }
    }

    @Published var options = SearchOptions(query: "") { didSet { if options != oldValue { schedule() } } }
    @Published private(set) var state: State = .idle
    @Published var collapsed: Set<String> = []

    enum Install: Equatable { case idle, installing, failed(String) }
    /// "Install for uHerdr" on an SSH device without ripgrep.
    @Published private(set) var install: Install = .idle
    /// Installs ripgrep on the device and returns its version line; nil where
    /// there is nothing to install (this Mac).
    var installer: (() async throws -> String)?
    /// What the install would copy, for the explanation ("15.2.0 (Linux, x86-64)").
    var installTarget: String?

    /// Debounce before a search starts.
    var delay: Duration = .milliseconds(250)
    /// The current text of tabs with unsaved edits, by path relative to the folder.
    var unsavedText: () -> [String: String] = { [:] }

    private(set) var root: String?
    private var runner: ScriptRunner = .local
    private var ripgrep: String?
    private var key = ""
    private var task: Task<Void, Never>?

    /// Points the panel at a space's folder; the query stays, results start over.
    func open(root newRoot: String?, runner newRunner: ScriptRunner, ripgrep newRipgrep: String?, key newKey: String) {
        guard newKey != key else { return }
        key = newKey
        root = newRoot
        runner = newRunner
        ripgrep = newRipgrep
        collapsed = []
        schedule(immediately: true)
    }

    /// Copies uHerdr's ripgrep to the device, then searches again.
    func installRipgrep() {
        guard let installer, install != .installing else { return }
        install = .installing
        Task { [weak self] in
            do {
                _ = try await installer()
                self?.install = .idle
                self?.rerun()
            } catch {
                self?.install = .failed(error.localizedDescription)
            }
        }
    }

    /// Runs the search again now (Return in the field, or the refresh button).
    func rerun() { schedule(immediately: true) }

    func cancel() {
        task?.cancel()
        task = nil
        if state == .searching { state = .idle }
    }

    private func schedule(immediately: Bool = false) {
        task?.cancel()
        let options = self.options
        guard let root, !options.query.isEmpty else {
            task = nil
            state = .idle
            return
        }
        let runner = self.runner, ripgrep = self.ripgrep, delay = self.delay
        // Results for an older query never sit beside a newer one.
        state = .searching
        task = Task { [weak self] in
            if !immediately { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled, let self else { return }
            let clock = ContinuousClock()
            let started = clock.now
            let result: State
            do {
                let outcome = try await ContentSearch.search(options, root: root, runner: runner, ripgrep: ripgrep)
                guard !Task.isCancelled else { return }
                let unsaved = self.unsavedText()
                let remaining = max(.zero, SearchLimits().deadline - (clock.now - started))
                let worker = Task.detached {
                    ContentSearch.merging(outcome, unsaved: unsaved, options: options,
                                          limits: SearchLimits(deadline: remaining), isCancelled: { Task.isCancelled })
                }
                let merged = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
                result = .done(merged, elapsed: clock.now - started)
            } catch let error as SearchError {
                result = .failed(error)
            } catch {
                guard !Task.isCancelled else { return }
                result = .failed(.failed(error.localizedDescription))
            }
            guard !Task.isCancelled else { return }
            self.state = result
        }
    }

    /// Results grouped by file, in path order; unsaved files are marked.
    var groups: [FileGroup] {
        guard case let .done(outcome, _) = state else { return [] }
        let unsaved = Set(unsavedText().keys)
        var order: [String] = []
        var byPath: [String: [SearchHit]] = [:]
        for hit in outcome.hits {
            if byPath[hit.path] == nil { order.append(hit.path) }
            byPath[hit.path, default: []].append(hit)
        }
        return order.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { FileGroup(path: $0, hits: byPath[$0]!.sorted { $0.line < $1.line }, unsaved: unsaved.contains($0)) }
    }

    func toggle(_ path: String) {
        if collapsed.contains(path) { collapsed.remove(path) } else { collapsed.insert(path) }
    }
}
