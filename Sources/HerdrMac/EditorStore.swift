import Combine
import Foundation
import HerdrCore

/// How one editor tab reads and writes its file: on this Mac or over SSH.
struct EditorFileIO {
    var read: @Sendable () async throws -> FileContents
    var write: @Sendable (_ text: String, _ baseline: FileContents, _ mode: SaveMode) async throws -> FileContents
    /// The file's bytes, for images and PDFs (capped at 50 MB).
    var readData: (@Sendable () async throws -> FileReader.Raw)? = nil
}

/// Editor tabs for one device. herdr knows nothing about them: each space has
/// its own ordered editor tabs beside its terminal tabs, and at most one of
/// them is shown in place of the terminals.
@MainActor
final class EditorStore: ObservableObject {
    enum Load: Equatable {
        case loading
        case loaded(FileContents)
        /// A diff tab's content.
        case diff(GitDiff)
        /// An image or PDF, shown read-only: its bytes, or its size when too large.
        case media(FileReader.Raw)
        case failed(String)
    }

    /// A place in a tab to scroll to and select (a search result): 1-based
    /// line, UTF-16 columns. A new id asks again for the same place.
    struct Reveal: Equatable {
        let line: Int
        let columns: Range<Int>
        /// Go to Line moves the keyboard into the editor; a search result leaves it in the results.
        var focus = false
        let id = UUID()
    }

    /// What a read-only diff tab compares: one row of the Changes panel.
    struct DiffSpec: Equatable {
        let change: GitChange
        /// The file's full path on the device, for Open file.
        let path: String
        /// The space folder, for the path shown in the header.
        let root: String
        /// The repository's top folder, where Git runs.
        let repository: String
    }

    enum SaveState: Equatable {
        case idle
        case saving
        /// The file changed on disk since it was opened; the user chooses.
        case conflict
        /// A hard link or an unwritable folder: the user may write in place.
        case needsInPlace(String)
        /// SSH failed mid-save and reading the file back didn't settle it.
        case outcomeUnknown(String)
        case failed(String)
    }

    struct Tab: Identifiable, Equatable {
        /// The file's path on its device; one tab per file per space.
        let id: String
        var name: String { (id as NSString).lastPathComponent }
        /// A preview tab (italic) is replaced by the next file opened with a
        /// single click, until it is kept by a double-click or an edit.
        var isPreview: Bool
        var load: Load
        /// Why this tab can never be saved, such as a link pointing outside the space.
        var readOnlyNote: String? = nil
        /// The text being edited; nil until the file has loaded as text.
        var text: String? = nil
        var saveState: SaveState = .idle
        /// Partial-write consent alone never authorizes a stale overwrite.
        var inPlaceConsent = false
        /// A short note in the tab header, such as "Reloaded · changed on disk".
        var note: String? = nil
        /// Unsaved text found from an earlier session, waiting for Keep or Discard.
        var recoveredDraft: Draft? = nil
        /// Original baseline of recovered edits, until saved or discarded.
        var recoveredBaselineSHA: String? = nil
        /// Set for a read-only diff tab.
        var diff: DiffSpec? = nil
        /// Not a file on disk (a diff, a deleted file's last version): never
        /// remembered for the next launch nor watched for changes.
        var isTransient = false
        /// The last place asked for; the editor view shows it once.
        var reveal: Reveal? = nil
        /// A Markdown tab showing its rendered preview instead of its text.
        var showsPreview = false
        /// A heading to scroll the preview to (a link with "#heading").
        var previewFragment: String? = nil

        /// The file this tab is about (a diff's or a base version's file, too).
        var filePath: String {
            if let diff { return diff.path }
            return id.hasPrefix(EditorStore.basePrefix) ? String(id.dropFirst(EditorStore.basePrefix.count)) : id
        }
        /// A word after the name in the tab strip.
        var kindLabel: String? { diff != nil ? "Diff" : id.hasPrefix(EditorStore.basePrefix) ? "Base" : nil }

        /// The version on disk the edits started from.
        var baseline: FileContents? { if case let .loaded(contents) = load { return contents } else { return nil } }
        var baselineText: String? { if case let .text(text)? = baseline?.kind { return text } else { return nil } }
        var isDirty: Bool { text != nil && text != baselineText }
        var canEdit: Bool { readOnlyNote == nil && baselineText != nil }
    }

    @Published private(set) var tabs: [String: [Tab]] = [:]
    /// The editor shown instead of the terminals, per space; nil shows terminals.
    @Published private(set) var active: [String: String] = [:]
    struct PendingClose: Equatable { let space: String; let id: String }
    /// An edited tab waiting for Save / Don't Save / Cancel before it closes.
    @Published var pendingClose: PendingClose?
    private var io: [String: EditorFileIO] = [:]
    private var loads: [String: Task<Void, Never>] = [:]
    private var diffLoaders: [String: @Sendable () async throws -> GitDiff] = [:]
    private var draftTimers: [String: Task<Void, Never>] = [:]
    private var revisions: [String: Int] = [:]
    /// Captured while the buffer's space/root exists; metadata may vanish before pruning.
    private var draftContexts: [String: (profile: UUID, label: String, root: String)] = [:]

    /// Where drafts go, and what a draft records about its space. Nil in tests
    /// that don't need drafts.
    var drafts: DraftStore?
    var draftContext: ((_ space: String) -> (profile: UUID, label: String, root: String)?)?
    /// Called whenever the set of open tabs changes, so it can be remembered.
    var onTabsChanged: (() -> Void)?
    /// How long typing must pause before a draft is written.
    var draftDelay: Duration = .seconds(2)

    func tabs(in space: String) -> [Tab] { tabs[space] ?? [] }
    func activeTab(in space: String) -> Tab? { active[space].flatMap { id in tabs[space]?.first { $0.id == id } } }
    func tab(_ id: String, in space: String) -> Tab? { tabs[space]?.first { $0.id == id } }
    func hasUnsavedEdits(in space: String) -> Bool { tabs(in: space).contains(where: \.isDirty) }
    var hasUnsavedEdits: Bool { tabs.values.joined().contains(where: \.isDirty) }

    /// Opens a file in a space: a single click reuses the preview tab, a
    /// double-click (preview false) keeps the tab. An open file is just shown.
    func open(_ path: String, in space: String, preview: Bool, readOnlyNote: String? = nil, transient: Bool = false, io fileIO: EditorFileIO) {
        open(path, in: space, preview: preview, readOnlyNote: readOnlyNote, diff: nil, transient: transient, io: fileIO)
    }

    /// The id of a diff tab, distinct from the file's own tab and per group
    /// (a file can have a staged and an unstaged diff).
    static func diffID(_ spec: DiffSpec) -> String { "diff:\(spec.change.group.rawValue):" + spec.path }

    /// Opens a Changes row as a read-only diff tab, with the same preview rules as files.
    func openDiff(_ spec: DiffSpec, in space: String, preview: Bool, load: @escaping @Sendable () async throws -> GitDiff) {
        let id = Self.diffID(spec)
        diffLoaders[key(space, id)] = load
        open(id, in: space, preview: preview, readOnlyNote: "Diff", diff: spec, transient: true,
             io: EditorFileIO(read: { throw FileSaveError.failed("A diff tab has no file.") },
                              write: { _, _, _ in throw FileSaveError.failed("A diff tab can't be saved.") }))
    }

    /// Switches a Markdown tab between its text and its rendered preview (⌥⌘V).
    func setPreview(_ id: String, in space: String, _ on: Bool, fragment: String? = nil) {
        update(id, in: space) { $0.showsPreview = on; $0.previewFragment = fragment }
    }

    /// Scrolls a tab to a line and selects the columns, now or once it loads.
    func reveal(_ id: String, in space: String, line: Int, columns: Range<Int>, focus: Bool = false) {
        update(id, in: space) { $0.reveal = Reveal(line: line, columns: columns, focus: focus) }
    }

    /// Reads a space's diff tabs again (the status changed).
    func reloadDiffs(in space: String) {
        for tab in tabs(in: space) where tab.diff != nil && loads[key(space, tab.id)] == nil { startLoad(tab.id, in: space) }
    }

    private func open(_ path: String, in space: String, preview: Bool, readOnlyNote: String?, diff: DiffSpec?, transient: Bool, io fileIO: EditorFileIO) {
        var list = tabs[space] ?? []
        if let index = list.firstIndex(where: { $0.id == path }) {
            if !preview { list[index].isPreview = false }
            tabs[space] = list
            active[space] = path
            return
        }
        var tab = Tab(id: path, isPreview: preview, load: .loading, readOnlyNote: readOnlyNote)
        tab.diff = diff
        tab.isTransient = transient
        // A preview never replaces a tab with unsaved edits.
        if preview, let index = list.firstIndex(where: { $0.isPreview && !$0.isDirty }) {
            forget(list[index].id, in: space)
            list[index] = tab
        } else {
            list.append(tab)
        }
        tabs[space] = list
        active[space] = path
        draftContexts[key(space, path)] = draftContext?(space)
        io[key(space, path)] = fileIO
        startLoad(path, in: space)
        onTabsChanged?()
    }

    /// Convenience for tests and read-only tabs: a reader with no writer.
    func open(_ path: String, in space: String, preview: Bool, readOnlyNote: String? = nil,
              read: @escaping @Sendable () async throws -> FileContents) {
        open(path, in: space, preview: preview, readOnlyNote: readOnlyNote,
             io: EditorFileIO(read: read, write: { _, _, _ in throw FileSaveError.failed("This tab can't be saved.") }))
    }

    private func startLoad(_ path: String, in space: String, note: String? = nil) {
        let k = key(space, path)
        guard let read = io[k]?.read else { return }
        let readDiff = diffLoaders[k]
        let kind = FileKind.of((path as NSString).lastPathComponent)
        let readData = kind == .image || kind == .pdf ? io[k]?.readData : nil
        loads[k]?.cancel()
        loads[k] = Task { [weak self] in
            let result: Load
            do {
                if let readDiff { result = .diff(try await readDiff()) }
                else if let readData { result = .media(try await readData()) }
                else { result = .loaded(try await read()) }
            } catch { result = .failed(error.localizedDescription) }
            guard !Task.isCancelled, let self else { return }
            self.loads[k] = nil
            if note != nil, let current = self.tab(path, in: space) {
                // A reload never replaces typing that started meanwhile, and
                // says nothing when the disk holds what the tab already shows.
                if current.isDirty { return }
                if case let .loaded(contents) = result, contents.sha256 == current.baseline?.sha256 { return }
            }
            self.update(path, in: space) { tab in
                tab.load = result
                if case let .loaded(contents) = result, case let .text(text) = contents.kind {
                    tab.text = text
                } else {
                    tab.text = nil
                }
                tab.note = note
            }
            self.attachDraft(path, in: space)
        }
    }

    // MARK: Editing and saving

    /// The user typed. Editing keeps a preview tab, and a draft follows shortly.
    func edit(_ id: String, in space: String, text: String) {
        guard let current = tab(id, in: space), current.canEdit, current.text != text else { return }
        update(id, in: space) { tab in
            tab.text = text
            tab.isPreview = false
            tab.note = nil
        }
        revisions[key(space, id), default: 0] += 1
        scheduleDraft(id, in: space)
        onTabsChanged?()
    }

    /// Saves what the tab holds now. Typing during the save keeps the tab
    /// dirty: only the version that was written becomes the baseline.
    func save(_ id: String, in space: String, mode: SaveMode = .safe) async {
        let k = key(space, id)
        guard let current = tab(id, in: space), current.canEdit, let text = current.text, let baseline = current.baseline,
              let write = io[k]?.write, current.saveState != .saving else { return }
        if mode != .overwrite && mode != .overwriteInPlace, let original = current.recoveredBaselineSHA, original != baseline.sha256 {
            update(id, in: space) { $0.saveState = .conflict; if mode == .inPlace { $0.inPlaceConsent = true } }
            return
        }
        let writeMode: SaveMode = mode == .overwrite && current.inPlaceConsent ? .overwriteInPlace : mode
        let revision = revisions[k, default: 0]
        update(id, in: space) { $0.saveState = .saving; if mode == .inPlace { $0.inPlaceConsent = true } }
        do {
            let saved = try await write(text, baseline, writeMode)
            update(id, in: space) { tab in
                // The baseline becomes what was written; later typing stays unsaved.
                let latest = tab.text
                tab.load = .loaded(saved)
                tab.recoveredBaselineSHA = nil
                tab.text = latest
                tab.saveState = .idle
                tab.inPlaceConsent = false
                tab.note = nil
            }
            if revisions[k, default: 0] == revision { removeDraft(id, in: space) }
            else { writeDraft(id, in: space) }
            // The stamp after our write isn't known yet, and something else may
            // write before the next check. So the next check always compares
            // contents: our own version reloads silently (same hash), anything
            // newer reloads with its note. The same file open in another
            // space does see the save.
            stamps[id] = .some(Self.unknownStamp)
            for (other, list) in tabs where other != space && list.contains(where: { $0.id == id }) { fileChangedOnDisk(id, in: other) }
        } catch let error as FileSaveError {
            switch error {
            case .conflict: update(id, in: space) { $0.saveState = .conflict }
            case .hardLinked, .folderNotWritable: update(id, in: space) { $0.saveState = .needsInPlace(error.localizedDescription) }
            case let .outcomeUnknown(reason): await settleUnknownOutcome(id, in: space, text: text, baseline: baseline, revision: revision, reason: reason)
            default: update(id, in: space) { $0.saveState = .failed(error.localizedDescription) }
            }
        } catch {
            update(id, in: space) { $0.saveState = .failed(error.localizedDescription) }
        }
    }

    /// After an SSH save whose reply was lost, read the file back to learn
    /// whether it was written; never guess.
    private func settleUnknownOutcome(_ id: String, in space: String, text: String, baseline: FileContents, revision: Int, reason: String) async {
        let expected = FileContents.decode(FileContents.encode(text, lineEnding: baseline.lineEnding, bom: baseline.hasBOM), limit: .max)
        if let read = io[key(space, id)]?.read, let disk = try? await read(), disk.sha256 == expected.sha256 {
            update(id, in: space) { tab in
                let latest = tab.text
                tab.load = .loaded(disk)
                tab.recoveredBaselineSHA = nil
                tab.text = latest
                tab.saveState = .idle
                tab.inPlaceConsent = false
                tab.note = "Saved (checked after the connection dropped)"
            }
            if revisions[key(space, id), default: 0] == revision { removeDraft(id, in: space) }
            else { writeDraft(id, in: space) }
        } else {
            update(id, in: space) { $0.saveState = .outcomeUnknown(reason) }
        }
    }

    /// "Discard my edits": the disk version replaces the tab's text.
    func discardEdits(_ id: String, in space: String) {
        update(id, in: space) { tab in
            tab.text = tab.baselineText
            tab.saveState = .idle
            tab.inPlaceConsent = false
            tab.recoveredDraft = nil
            tab.recoveredBaselineSHA = nil
        }
        removeDraft(id, in: space)
        startLoad(id, in: space)
    }

    func dismissSaveProblem(_ id: String, in space: String) { update(id, in: space) { $0.saveState = .idle; $0.inPlaceConsent = false } }

    /// The file changed on disk (an agent, git, another editor). A tab
    /// without edits reloads by itself; a tab with edits waits for Save.
    func fileChangedOnDisk(_ id: String, in space: String) {
        guard let current = tab(id, in: space), !current.isDirty, current.saveState != .saving else { return }
        startLoad(id, in: space, note: "Reloaded · changed on disk")
    }

    // MARK: Watching the disk

    /// Last stamp seen per open file; a missing file is stored as nil.
    private var stamps: [String: FileStamp?] = [:]
    /// Stands for "unknown, compare contents next time"; matches no real file.
    private static let unknownStamp = FileStamp(size: -1, modified: -1, inode: 0)

    /// Checks the open files every `interval` until cancelled (the window's
    /// task for this device ends).
    func watchDisk(every interval: Duration, reader: @escaping @MainActor ([String]) async throws -> [String: FileStamp]) async {
        while !Task.isCancelled {
            await checkDisk(reader: reader)
            try? await Task.sleep(for: interval)
        }
    }

    /// One pass: tabs whose file's stamp changed hear about it. A failed read
    /// (device unreachable) changes nothing.
    func checkDisk(reader: @MainActor ([String]) async throws -> [String: FileStamp]) async {
        let paths = Set(tabs.values.joined().filter { $0.baseline != nil && !$0.isTransient }.map(\.id))
        for path in stamps.keys where !paths.contains(path) { stamps[path] = nil }
        guard !paths.isEmpty, let current = try? await reader(Array(paths).sorted()) else { return }
        for path in paths {
            let stamp = current[path]
            if let previous = stamps[path], previous != stamp {
                for (space, list) in tabs where list.contains(where: { $0.id == path }) { fileChangedOnDisk(path, in: space) }
            }
            stamps[path] = .some(stamp)
        }
    }

    /// The disk version, for the conflict's Compare view.
    func diskVersion(_ id: String, in space: String) async -> String? {
        guard let read = io[key(space, id)]?.read, let disk = try? await read(), case let .text(text) = disk.kind else { return nil }
        return text
    }

    // MARK: Drafts

    private func scheduleDraft(_ id: String, in space: String) {
        let k = key(space, id)
        draftTimers[k]?.cancel()
        let delay = draftDelay
        draftTimers[k] = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.writeDraft(id, in: space)
        }
    }

    /// Writes every pending draft now (on quit, or before a space's tabs go).
    func flushDrafts() {
        let pending = draftTimers
        draftTimers = [:]
        for (k, timer) in pending {
            timer.cancel()
            let parts = k.split(separator: "\0", maxSplits: 1).map(String.init)
            if parts.count == 2 { writeDraft(parts[1], in: parts[0]) }
        }
    }

    private func writeDraft(_ id: String, in space: String) {
        draftTimers[key(space, id)] = nil
        guard let drafts, let context = draftContexts[key(space, id)], let current = tab(id, in: space),
              current.isDirty, let text = current.text else { return }
        try? drafts.save(Draft(profileID: context.profile, workspaceID: space, spaceLabel: context.label, root: context.root,
                               path: id, text: text, baselineSHA: current.recoveredBaselineSHA ?? current.baseline?.sha256 ?? ""))
    }

    private func removeDraft(_ id: String, in space: String) {
        draftTimers[key(space, id)]?.cancel()
        draftTimers[key(space, id)] = nil
        guard let drafts, let context = draftContexts[key(space, id)] else { return }
        drafts.remove(profile: context.profile, workspace: space, path: id)
    }

    /// A tab just loaded: if an earlier session left unsaved text for it in
    /// this same space, offer it.
    private func attachDraft(_ id: String, in space: String) {
        guard let drafts, let context = draftContexts[key(space, id)],
              let draft = drafts.load(profile: context.profile, workspace: space, path: id),
              draft.workspaceID == space, draft.spaceLabel == context.label,
              let current = tab(id, in: space), current.canEdit, !current.isDirty, draft.text != current.baselineText else { return }
        update(id, in: space) { $0.recoveredDraft = draft }
    }

    /// "Keep draft": its text becomes the tab's unsaved edits.
    func keepDraft(_ id: String, in space: String) {
        guard let draft = tab(id, in: space)?.recoveredDraft else { return }
        update(id, in: space) { tab in
            tab.text = draft.text
            tab.recoveredBaselineSHA = draft.baselineSHA
            tab.recoveredDraft = nil
            tab.isPreview = false
        }
        revisions[key(space, id), default: 0] += 1
        onTabsChanged?()
    }

    func discardDraft(_ id: String, in space: String) {
        update(id, in: space) { $0.recoveredDraft = nil }
        removeDraft(id, in: space)
    }

    // MARK: Tabs

    func keep(_ id: String, in space: String) {
        update(id, in: space) { $0.isPreview = false }
        onTabsChanged?()
    }

    func show(_ id: String, in space: String) {
        guard tabs[space]?.contains(where: { $0.id == id }) == true else { return }
        active[space] = id
    }

    /// Shows the space's terminals again (a terminal tab was chosen).
    func showTerminals(in space: String) {
        if active[space] != nil { active[space] = nil }
    }

    /// Closes a tab, or asks first (through `pendingClose`) when it has unsaved edits.
    func requestClose(_ id: String, in space: String) {
        if tab(id, in: space)?.isDirty == true { pendingClose = PendingClose(space: space, id: id) } else { close(id, in: space) }
    }

    /// "Save" in the close prompt: closes only once the save went through.
    func saveAndClose(_ pending: PendingClose) async {
        pendingClose = nil
        await save(pending.id, in: pending.space)
        if tab(pending.id, in: pending.space)?.isDirty == false { close(pending.id, in: pending.space) }
    }

    /// The space's folder changed: tabs of files outside the new folder close,
    /// except those with unsaved edits (they stay until saved or closed).
    /// `roots` lists the folder's spellings (as typed and resolved).
    func closeTabs(in space: String, keepingUnder roots: [String]) {
        let prefixes = roots.map { $0.hasSuffix("/") ? $0 : $0 + "/" }
        for tab in tabs(in: space) where !tab.isDirty && !prefixes.contains(where: { tab.filePath.hasPrefix($0) }) {
            close(tab.id, in: space)
        }
    }

    /// Every edited tab, as (space, id).
    var dirtyTabs: [(space: String, id: String)] {
        tabs.sorted { $0.key < $1.key }.flatMap { space, list in list.filter(\.isDirty).map { (space, $0.id) } }
    }

    /// Quit's "Save All": true when every edited tab was written. A tab that
    /// couldn't be saved (conflict, read-only, device down) is shown instead.
    func saveAll() async -> Bool {
        for (space, id) in dirtyTabs { await save(id, in: space) }
        guard let (space, id) = dirtyTabs.first else { return true }
        show(id, in: space)
        return false
    }

    /// Quit's "Don't Save": the edits are dropped, drafts included.
    func discardUnsaved() {
        for (space, id) in dirtyTabs {
            draftTimers[key(space, id)]?.cancel()
            draftTimers[key(space, id)] = nil
            removeDraft(id, in: space)
        }
    }

    /// Closes an editor tab; callers ask about unsaved edits first. If it was
    /// showing, the editor to its right (or left) takes its place; with no
    /// editors left, the terminals show.
    func close(_ id: String, in space: String) {
        guard var list = tabs[space], let index = list.firstIndex(where: { $0.id == id }) else { return }
        removeDraft(id, in: space)
        forget(id, in: space)
        list.remove(at: index)
        tabs[space] = list.isEmpty ? nil : list
        if active[space] == id {
            active[space] = list.isEmpty ? nil : list[min(index, list.count - 1)].id
        }
        onTabsChanged?()
    }

    /// Drops a space's tabs when herdr no longer lists the space; unsaved text
    /// is written to its draft first.
    func prune(keeping spaces: Set<String>) {
        for space in waitingToReopen.keys where !spaces.contains(space) { waitingToReopen[space] = nil }
        for space in tabs.keys where !spaces.contains(space) {
            for tab in tabs[space] ?? [] where tab.isDirty { writeDraft(tab.id, in: space) }
            for tab in tabs[space] ?? [] { forget(tab.id, in: space) }
            tabs[space] = nil
            active[space] = nil
            onTabsChanged?()
        }
    }

    /// The tabs to reopen after a relaunch, per space, in order (a clean
    /// preview tab isn't worth remembering).
    var openTabs: [String: [String]] { remembered.mapValues { $0.map(\.path) } }

    /// A tab worth reopening; `outsideLink` keeps a read-only link read-only.
    struct Remembered: Codable, Equatable, Sendable { var path: String; var outsideLink = false }
    /// Tabs from the last run waiting for their space and folder to be known.
    var waitingToReopen: [String: [Remembered]] = [:]

    /// What to save for the next launch: open tabs, plus spaces not reopened yet.
    var remembered: [String: [Remembered]] {
        var result = waitingToReopen
        for (space, list) in tabs {
            let kept = list.filter { !$0.isTransient && (!$0.isPreview || $0.isDirty) }.map { Remembered(path: $0.id, outsideLink: $0.readOnlyNote != nil) }
            result[space] = kept.isEmpty ? nil : kept
        }
        return result
    }

    /// Reopens a space's tabs from the last run, behind its terminals.
    func reopen(in space: String, io: (Remembered) -> EditorFileIO?) {
        guard let list = waitingToReopen.removeValue(forKey: space) else { return }
        let shown = active[space]
        for entry in list where tab(entry.path, in: space) == nil {
            guard let fileIO = io(entry) else { continue }
            open(entry.path, in: space, preview: false, readOnlyNote: entry.outsideLink ? EditorStore.outsideNote : nil, io: fileIO)
        }
        active[space] = shown
        onTabsChanged?()
    }

    static let outsideNote = "Outside this space · read-only"
    /// Prefix of the id of a deleted file's last-version tab.
    static let basePrefix = "base:"

    private func forget(_ id: String, in space: String) {
        let k = key(space, id)
        loads[k]?.cancel()
        loads[k] = nil
        io[k] = nil
        diffLoaders[k] = nil
        draftTimers[k]?.cancel()
        draftTimers[k] = nil
        draftContexts[k] = nil
        revisions[k] = nil
    }

    private func update(_ id: String, in space: String, _ change: (inout Tab) -> Void) {
        guard var list = tabs[space], let index = list.firstIndex(where: { $0.id == id }) else { return }
        change(&list[index])
        tabs[space] = list
    }

    private func key(_ space: String, _ id: String) -> String { space + "\0" + id }
}

/// One EditorStore per device, so menus and the window share them. Each keeps
/// its unsaved text in `drafts` and its open tabs in `defaults` for the next launch.
@MainActor
final class EditorStores: ObservableObject {
    private var stores: [UUID: EditorStore] = [:]
    private var watchers: [UUID: AnyCancellable] = [:]

    /// What the menus need, per device: the spaces showing an editor, and
    /// those whose shown editor has edits to save. Published only when it
    /// changes, so typing doesn't rebuild the menus.
    struct MenuState: Equatable { var shown: Set<String> = []; var savable: Set<String> = []; var markdown: Set<String> = [] }
    @Published private(set) var menuState: [UUID: MenuState] = [:]
    /// Refresh numbered navigation menus when tabs open, close or change order.
    @Published private(set) var tabIDs: [UUID: [String: [String]]] = [:]
    let drafts: DraftStore?
    let defaults: UserDefaults?
    /// A space's name and folder on a device, for drafts.
    var spaceInfo: ((_ profile: UUID, _ space: String) -> (label: String, root: String)?)?

    init(drafts: DraftStore? = nil, defaults: UserDefaults? = nil) {
        self.drafts = drafts
        self.defaults = defaults
    }

    static func tabsKey(_ profile: UUID) -> String { "editorTabs.\(profile.uuidString)" }

    func store(for profile: UUID) -> EditorStore {
        if let store = stores[profile] { return store }
        let store = EditorStore()
        store.drafts = drafts
        store.draftContext = { [weak self] space in
            self?.spaceInfo?(profile, space).map { (profile, $0.label, $0.root) }
        }
        if let defaults {
            let key = Self.tabsKey(profile)
            if let data = defaults.data(forKey: key),
               let saved = try? JSONDecoder().decode([String: [EditorStore.Remembered]].self, from: data) {
                store.waitingToReopen = saved
            }
            store.onTabsChanged = { [weak store] in
                guard let store, let data = try? JSONEncoder().encode(store.remembered) else { return }
                defaults.set(data, forKey: key)
            }
        }
        stores[profile] = store
        watchers[profile] = store.$tabs.combineLatest(store.$active).sink { [weak self] tabs, active in
            var state = MenuState()
            let ids = tabs.mapValues { $0.map(\.id) }
            if self?.tabIDs[profile] != ids { self?.tabIDs[profile] = ids }
            for (space, id) in active {
                guard let tab = tabs[space]?.first(where: { $0.id == id }) else { continue }
                state.shown.insert(space)
                if tab.isDirty && tab.saveState != .saving { state.savable.insert(space) }
                if tab.diff == nil, FileKind.of(tab.name) == .markdown, case .loaded = tab.load { state.markdown.insert(space) }
            }
            if self?.menuState[profile] != state { self?.menuState[profile] = state }
        }
        return store
    }

    /// Removing a connection retains local recovery and its remembered tabs.
    func forget(profile: UUID) {
        stores[profile]?.flushDrafts()
        stores[profile] = nil
        watchers[profile] = nil
        menuState[profile] = nil
        tabIDs[profile] = nil
    }

    var all: [EditorStore] { Array(stores.values) }
}
