import Foundation
import HerdrCore

/// The Changes panel's state for the shown space: Git status of its folder,
/// read on this Mac or over SSH, refreshed while the sidebar is on screen.
@MainActor
final class ChangesModel: ObservableObject {
    enum State: Equatable {
        case idle
        case loading
        case loaded(GitChanges)
        case failed(GitChangesError)
    }

    @Published private(set) var state: State = .idle
    /// Collapsed groups ("g:Staged") and folders ("Staged:Sources/HerdrMac").
    @Published var collapsed: Set<String> = []
    /// Called after a read whose result differs from the one before, so open
    /// diff tabs can follow.
    var onChange: (() -> Void)?

    private(set) var root: String?
    private var runner: ScriptRunner = .local
    private var key = ""
    private var generation = 0
    private var reading = false

    var changes: GitChanges? { if case let .loaded(changes) = state { return changes } else { return nil } }
    /// The count beside "Changes" in the switcher.
    var count: Int? { changes.map(\.fileCount) }

    /// Points the panel at a space's folder. `key` names the device and folder;
    /// a new key starts over.
    func open(root newRoot: String?, runner newRunner: ScriptRunner, key newKey: String) {
        guard newKey != key else { return }
        key = newKey
        root = newRoot
        runner = newRunner
        generation += 1
        reading = false
        collapsed = []
        state = newRoot == nil ? .idle : .loading
    }

    /// One read. A read for a folder that was replaced meanwhile is dropped.
    func refresh() async {
        guard let root, !reading else { return }
        reading = true
        let expected = generation
        let result: State
        do { result = .loaded(try await GitChangesReader.read(root: root, runner: runner)) } catch let error as GitChangesError {
            result = .failed(error)
        } catch {
            result = .failed(.failed(error.localizedDescription))
        }
        guard expected == generation else { return }
        reading = false
        if state != result {
            let hadContent = state != .loading
            state = result
            if hadContent { onChange?() }
        }
    }

    /// Reads now, then every `interval` until the task is cancelled.
    func watch(every interval: Duration, while live: @escaping @MainActor () -> Bool = { true }) async {
        while !Task.isCancelled {
            if live() { await refresh() }
            try? await Task.sleep(for: interval)
        }
    }

    func toggle(_ id: String) {
        if collapsed.contains(id) { collapsed.remove(id) } else { collapsed.insert(id) }
    }
}
