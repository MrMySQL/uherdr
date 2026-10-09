import Foundation
import HerdrCore

/// A file on a fake disk that refuses stale saves the way the real savers do.
actor FakeFile {
    var bytes: Data
    var failNext: FileSaveError?
    var holdWrites = false
    var holdingReads = false
    var reads = 0
    var writes = 0
    init(_ text: String) { bytes = Data(text.utf8) }

    func set(_ text: String) { bytes = Data(text.utf8) }
    func fail(_ error: FileSaveError?) { failNext = error }
    func hold(_ on: Bool) { holdWrites = on }
    func holdReads(_ on: Bool) { holdingReads = on }
    func text() -> String { String(decoding: bytes, as: UTF8.self) }

    func read() async -> FileContents {
        while holdingReads { try? await Task.sleep(for: .milliseconds(5)) }
        reads += 1
        return FileContents.decode(bytes)
    }

    func write(_ text: String, _ baseline: FileContents, _ mode: SaveMode) async throws -> FileContents {
        while holdWrites { try await Task.sleep(for: .milliseconds(5)) }
        if let error = failNext {
            failNext = nil
            if case .outcomeUnknown = error { bytes = FileContents.encode(text, lineEnding: baseline.lineEnding, bom: baseline.hasBOM) }
            throw error
        }
        if mode == .safe, FileContents.decode(bytes).sha256 != baseline.sha256 { throw FileSaveError.conflict }
        bytes = FileContents.encode(text, lineEnding: baseline.lineEnding, bom: baseline.hasBOM)
        writes += 1
        return FileContents.decode(bytes)
    }

    nonisolated var io: EditorFileIO {
        EditorFileIO(read: { await self.read() }, write: { text, baseline, mode in try await self.write(text, baseline, mode) })
    }
}

@main struct EditorEditingTests {
    @MainActor static func main() async throws {
        let draftsFolder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("uherdr-edit-drafts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: draftsFolder) }
        let drafts = DraftStore(directory: draftsFolder)
        let device = UUID()
        func makeStore() -> EditorStore {
            let store = EditorStore()
            store.drafts = drafts
            store.draftContext = { _ in (device, "uherdr", "/p") }
            store.draftDelay = .milliseconds(40)
            return store
        }
        func settle(_ ms: Int = 80) async throws { try await Task.sleep(for: .milliseconds(ms)) }
        var diskText = ""

        // Editing: dirty, kept (no longer a preview), and a draft after typing pauses.
        let store = makeStore()
        let file = FakeFile("one\n")
        store.open("/p/a.swift", in: "w1", preview: true, io: file.io)
        try await settle()
        precondition(store.tab("/p/a.swift", in: "w1")?.isDirty == false)
        store.edit("/p/a.swift", in: "w1", text: "one\ntwo\n")
        var tab = store.tab("/p/a.swift", in: "w1")!
        precondition(tab.isDirty && !tab.isPreview, "Editing marks the tab dirty and keeps it")
        try await settle()
        precondition(drafts.load(profile: device, workspace: "w1", path: "/p/a.swift")?.text == "one\ntwo\n", "A draft is written after typing pauses")

        // Saving: written, clean, draft gone.
        await store.save("/p/a.swift", in: "w1")
        diskText = await file.text(); precondition(diskText == "one\ntwo\n")
        tab = store.tab("/p/a.swift", in: "w1")!
        precondition(!tab.isDirty && tab.saveState == .idle)
        precondition(drafts.load(profile: device, workspace: "w1", path: "/p/a.swift") == nil, "Saving removes the draft")

        // Typing during a save keeps the newer text unsaved.
        store.edit("/p/a.swift", in: "w1", text: "v2\n")
        await file.hold(true)
        let saving = Task { await store.save("/p/a.swift", in: "w1") }
        try await settle(30)
        store.edit("/p/a.swift", in: "w1", text: "v3\n")
        await file.hold(false)
        await saving.value
        tab = store.tab("/p/a.swift", in: "w1")!
        diskText = await file.text(); precondition(diskText == "v2\n" && tab.text == "v3\n" && tab.isDirty, "Only the saved version becomes the baseline")
        await store.save("/p/a.swift", in: "w1")

        // Changed on disk: Save stops at a conflict; Overwrite and Discard both work.
        store.edit("/p/a.swift", in: "w1", text: "mine\n")
        await file.set("agent\n")
        await store.save("/p/a.swift", in: "w1")
        precondition(store.tab("/p/a.swift", in: "w1")?.saveState == .conflict)
        diskText = await file.text(); precondition(diskText == "agent\n", "A conflict leaves the disk alone")
        diskText = await store.diskVersion("/p/a.swift", in: "w1") ?? ""; precondition(diskText == "agent\n")
        await store.save("/p/a.swift", in: "w1", mode: .overwrite)
        diskText = await file.text(); precondition(diskText == "mine\n" && store.tab("/p/a.swift", in: "w1")?.isDirty == false)
        store.edit("/p/a.swift", in: "w1", text: "throwaway\n")
        await file.set("agent2\n")
        store.discardEdits("/p/a.swift", in: "w1")
        try await settle()
        tab = store.tab("/p/a.swift", in: "w1")!
        precondition(tab.text == "agent2\n" && !tab.isDirty, "Discard my edits loads the disk version")

        // Hard link / unwritable folder: the user is asked, then in place works.
        store.edit("/p/a.swift", in: "w1", text: "linked\n")
        await file.fail(.hardLinked(count: 2))
        await store.save("/p/a.swift", in: "w1")
        guard case .needsInPlace? = store.tab("/p/a.swift", in: "w1")?.saveState else { preconditionFailure("Expected the in-place question") }
        await store.save("/p/a.swift", in: "w1", mode: .inPlace)
        diskText = await file.text(); precondition(diskText == "linked\n")

        // SSH reply lost: if the file holds what was sent, it counts as saved; otherwise say so.
        store.edit("/p/a.swift", in: "w1", text: "maybe\n")
        await file.fail(.outcomeUnknown("reset"))
        await store.save("/p/a.swift", in: "w1")
        tab = store.tab("/p/a.swift", in: "w1")!
        precondition(tab.saveState == .idle && !tab.isDirty && tab.note?.hasPrefix("Saved") == true, "A confirmed write counts as saved")
        let other = FakeFile("x\n")
        store.open("/p/b.swift", in: "w1", preview: false, io: EditorFileIO(read: { await other.read() }, write: { _, _, _ in
            throw FileSaveError.outcomeUnknown("reset")
        }))
        try await settle()
        store.edit("/p/b.swift", in: "w1", text: "y\n")
        await store.save("/p/b.swift", in: "w1")
        guard case .outcomeUnknown? = store.tab("/p/b.swift", in: "w1")?.saveState else { preconditionFailure("Expected an unknown outcome") }
        precondition(store.tab("/p/b.swift", in: "w1")?.isDirty == true, "Unconfirmed edits stay unsaved")

        // Disk changes: a clean tab reloads with a note; an edited tab doesn't.
        await file.set("from agent\n")
        store.fileChangedOnDisk("/p/a.swift", in: "w1")
        try await settle()
        tab = store.tab("/p/a.swift", in: "w1")!
        precondition(tab.text == "from agent\n" && tab.note == "Reloaded · changed on disk")
        await other.set("agent\n")
        store.fileChangedOnDisk("/p/b.swift", in: "w1")
        try await settle()
        precondition(store.tab("/p/b.swift", in: "w1")?.text == "y\n", "Edited tabs never reload by themselves")

        // A preview never replaces an edited tab; remembered tabs skip a clean preview.
        let previews = makeStore()
        let p1 = FakeFile("1"), p2 = FakeFile("2"), p3 = FakeFile("3")
        previews.open("/p/one", in: "w1", preview: true, io: p1.io)
        try await settle()
        previews.edit("/p/one", in: "w1", text: "1!")
        previews.open("/p/two", in: "w1", preview: true, io: p2.io)
        previews.open("/p/three", in: "w1", preview: true, io: p3.io)
        try await settle()
        precondition(previews.tabs(in: "w1").map(\.id) == ["/p/one", "/p/three"], "An edited tab is kept; only the clean preview is replaced")
        precondition(previews.openTabs == ["w1": ["/p/one"]])
        precondition(previews.hasUnsavedEdits(in: "w1") && previews.hasUnsavedEdits)

        // Pruning a vanished space keeps its unsaved text as a draft.
        previews.prune(keeping: [])
        precondition(drafts.load(profile: device, workspace: "w1", path: "/p/one")?.text == "1!", "A vanished space's edits are kept as a draft")

        // A draft from an earlier session is offered when its file reopens.
        let reopened = makeStore()
        reopened.open("/p/one", in: "w1", preview: false, io: p1.io)
        try await settle()
        precondition(reopened.tab("/p/one", in: "w1")?.recoveredDraft?.text == "1!")
        precondition(reopened.tab("/p/one", in: "w1")?.isDirty == false, "A recovered draft waits for Keep")
        reopened.keepDraft("/p/one", in: "w1")
        precondition(reopened.tab("/p/one", in: "w1")?.text == "1!" && reopened.tab("/p/one", in: "w1")?.isDirty == true)
        // A draft recorded for a different space label isn't attached.
        try drafts.save(Draft(profileID: device, workspaceID: "w1", spaceLabel: "other", root: "/p", path: "/p/two", text: "x", baselineSHA: ""))
        reopened.open("/p/two", in: "w1", preview: false, io: p2.io)
        try await settle()
        precondition(reopened.tab("/p/two", in: "w1")?.recoveredDraft == nil, "Drafts never attach to a different space")
        reopened.discardDraft("/p/one", in: "w1")

        // B2: the same file in independent spaces has independent recovery.
        let siblings = makeStore()
        let sharedFile = FakeFile("shared baseline")
        for space in ["w1", "w2", "w3"] { siblings.open("/p/shared", in: space, preview: false, io: sharedFile.io) }
        try await settle()
        siblings.edit("/p/shared", in: "w1", text: "first draft")
        siblings.edit("/p/shared", in: "w2", text: "second draft")
        siblings.flushDrafts()
        siblings.close("/p/shared", in: "w3")
        let recoveredSiblings = makeStore()
        for space in ["w1", "w2"] { recoveredSiblings.open("/p/shared", in: space, preview: false, io: sharedFile.io) }
        try await settle()
        precondition(recoveredSiblings.tab("/p/shared", in: "w1")?.recoveredDraft?.text == "first draft", "B2: clean sibling cannot delete another space's draft")
        precondition(recoveredSiblings.tab("/p/shared", in: "w2")?.recoveredDraft?.text == "second draft")

        // B1: Keep never authorizes replacing a newer disk version.
        let recoveryFile = FakeFile("original")
        let original = await recoveryFile.read()
        try drafts.save(Draft(profileID: device, workspaceID: "w1", spaceLabel: "uherdr", root: "/p", path: "/p/recovery", text: "draft", baselineSHA: original.sha256))
        await recoveryFile.set("newer on disk")
        let recovery = makeStore()
        recovery.open("/p/recovery", in: "w1", preview: false, io: recoveryFile.io)
        try await settle()
        recovery.keepDraft("/p/recovery", in: "w1")
        await recovery.save("/p/recovery", in: "w1")
        precondition(recovery.tab("/p/recovery", in: "w1")?.saveState == .conflict, "B1: recovery requires explicit overwrite")
        diskText = await recoveryFile.text()
        precondition(diskText == "newer on disk")
        recovery.edit("/p/recovery", in: "w1", text: "draft edited again")
        recovery.flushDrafts()
        precondition(drafts.load(profile: device, workspace: "w1", path: "/p/recovery")?.baselineSHA == original.sha256, "B1: repeated recovery preserves the original baseline")
        await recovery.save("/p/recovery", in: "w1", mode: .overwrite)
        precondition(recovery.tab("/p/recovery", in: "w1")?.isDirty == false)

        // Closing: a clean tab closes at once; an edited one asks, and Save closes only once written.
        let closing = makeStore()
        let c1 = FakeFile("c\n")
        closing.open("/p/c", in: "w1", preview: false, io: c1.io)
        try await settle()
        closing.requestClose("/p/c", in: "w1")
        precondition(closing.tabs(in: "w1").isEmpty && closing.pendingClose == nil, "A clean tab closes without asking")
        closing.open("/p/c", in: "w1", preview: false, io: c1.io)
        try await settle()
        closing.edit("/p/c", in: "w1", text: "c!\n")
        closing.requestClose("/p/c", in: "w1")
        precondition(closing.pendingClose == .init(space: "w1", id: "/p/c") && closing.tab("/p/c", in: "w1") != nil, "An edited tab asks first")
        await c1.set("agent\n")
        await closing.saveAndClose(closing.pendingClose!)
        precondition(closing.tab("/p/c", in: "w1")?.saveState == .conflict && closing.pendingClose == nil, "A failed save keeps the tab open")
        await closing.save("/p/c", in: "w1", mode: .overwrite)
        closing.requestClose("/p/c", in: "w1")
        precondition(closing.tabs(in: "w1").isEmpty, "Saved, it closes")
        closing.open("/p/c", in: "w1", preview: false, io: c1.io)
        try await settle()
        closing.edit("/p/c", in: "w1", text: "again\n")
        closing.requestClose("/p/c", in: "w1")
        await closing.saveAndClose(closing.pendingClose!)
        diskText = await c1.text()
        precondition(diskText == "again\n" && closing.tabs(in: "w1").isEmpty, "Save in the prompt writes, then closes")

        // Quit: Save All writes every edited tab; a tab that can't be saved stops the quit and shows.
        let quitting = makeStore()
        let q1 = FakeFile("1\n"), q2 = FakeFile("2\n")
        quitting.open("/p/q1", in: "w1", preview: false, io: q1.io)
        quitting.open("/p/q2", in: "w2", preview: false, io: q2.io)
        try await settle()
        quitting.edit("/p/q1", in: "w1", text: "1!\n")
        quitting.edit("/p/q2", in: "w2", text: "2!\n")
        precondition(quitting.dirtyTabs.map(\.id) == ["/p/q1", "/p/q2"])
        quitting.showTerminals(in: "w2")
        await q2.set("agent\n")
        var allSaved = await quitting.saveAll()
        diskText = await q1.text()
        precondition(!allSaved && diskText == "1!\n" && quitting.activeTab(in: "w2")?.id == "/p/q2", "A conflict stops the quit and shows its tab")
        quitting.edit("/p/q2", in: "w2", text: "2!!\n")
        await quitting.save("/p/q2", in: "w2", mode: .overwrite)
        allSaved = await quitting.saveAll()
        precondition(allSaved && quitting.dirtyTabs.isEmpty)
        // Don't Save drops the drafts too.
        quitting.edit("/p/q1", in: "w1", text: "lost\n")
        try await settle()
        precondition(drafts.load(profile: device, workspace: "w1", path: "/p/q1") != nil)
        quitting.discardUnsaved()
        precondition(drafts.load(profile: device, workspace: "w1", path: "/p/q1") == nil, "Don't Save removes the draft")

        // Watching the disk: a changed stamp reloads a clean tab in every space showing it;
        // a failed check, our own save, and an unchanged file do nothing.
        let watching = makeStore()
        let w1 = FakeFile("w\n")
        watching.open("/p/w", in: "w1", preview: false, io: w1.io)
        watching.open("/p/w", in: "w2", preview: false, io: w1.io)
        try await settle()
        var stampOnDisk = FileStamp(size: 2, modified: 1, inode: 1)
        var checked: [[String]] = []
        let reader: @MainActor ([String]) async throws -> [String: FileStamp] = { paths in checked.append(paths); return ["/p/w": stampOnDisk] }
        await watching.checkDisk(reader: reader)
        precondition(checked == [["/p/w"]], "Each open file is checked once")
        let readsAtStart = await w1.reads
        await watching.checkDisk(reader: reader)
        try await settle()
        let readsUnchanged = await w1.reads
        precondition(readsUnchanged == readsAtStart, "An unchanged stamp reads nothing")
        await w1.set("agent\n")
        stampOnDisk.size = 6
        await watching.checkDisk(reader: { _ in throw CancellationError() })
        try await settle()
        precondition(watching.tab("/p/w", in: "w1")?.text == "w\n", "A failed check changes nothing")
        await watching.checkDisk(reader: reader)
        try await settle()
        precondition(watching.tab("/p/w", in: "w1")?.text == "agent\n" && watching.tab("/p/w", in: "w2")?.text == "agent\n", "A new stamp reloads every space's tab")
        precondition(watching.tab("/p/w", in: "w1")?.note == "Reloaded · changed on disk")
        watching.edit("/p/w", in: "w1", text: "mine\n")
        await watching.save("/p/w", in: "w1")
        try await settle()
        precondition(watching.tab("/p/w", in: "w2")?.text == "mine\n", "The same file in another space sees the save")
        // Something else writes before the next check: still caught, though the
        // stamp after our own save was never seen.
        await w1.set("agent wrote after the save\n")
        stampOnDisk.size = 5
        await watching.checkDisk(reader: reader)
        try await settle()
        precondition(watching.tab("/p/w", in: "w1")?.text == "agent wrote after the save\n"
                     && watching.tab("/p/w", in: "w1")?.note == "Reloaded · changed on disk", "A write right after our save is caught")
        // Our own save alone reloads nothing visible.
        watching.edit("/p/w", in: "w1", text: "mine again\n")
        await watching.save("/p/w", in: "w1")
        stampOnDisk.size = 11
        await watching.checkDisk(reader: reader)
        try await settle()
        let ownTab = watching.tab("/p/w", in: "w1")!
        precondition(ownTab.text == "mine again\n" && ownTab.note == nil && !ownTab.isDirty, "Our own save isn't a change on disk")
        let readsBefore = await w1.reads
        await watching.checkDisk(reader: reader)
        try await settle()
        let readsAfter = await w1.reads
        precondition(readsAfter == readsBefore, "Once checked, an unchanged stamp reads nothing")
        // The same content again (a touch): no reload note.
        watching.discardEdits("/p/w", in: "w1")
        try await settle()
        watching.fileChangedOnDisk("/p/w", in: "w1")
        try await settle()
        precondition(watching.tab("/p/w", in: "w1")?.note == nil, "An unchanged file says nothing")
        // Typing while a reload is on its way keeps the typing.
        await w1.set("agent again\n")
        await w1.holdReads(true)
        watching.fileChangedOnDisk("/p/w", in: "w1")
        watching.edit("/p/w", in: "w1", text: "typed\n")
        await w1.holdReads(false)
        try await settle()
        precondition(watching.tab("/p/w", in: "w1")?.text == "typed\n", "A reload never replaces new typing")

        // Diff tabs: preview rules like files, read-only, reloaded on request, never remembered or watched.
        let diffs = makeStore()
        let change = GitChange(group: .changes, path: "src/d.swift", letter: "M")
        let spec = EditorStore.DiffSpec(change: change, path: "/p/src/d.swift", root: "/p", repository: "/p")
        var diffReads = 0
        let hunkA = GitDiff(hunks: [GitDiff.Hunk(header: "@@ -1 +1 @@", lines: [GitDiff.Line(kind: .added, text: "a", old: nil, new: 1)])])
        diffs.openDiff(spec, in: "w1", preview: true) { diffReads += 1; return hunkA }
        try await settle()
        let diffID = EditorStore.diffID(spec)
        precondition(diffID != "/p/src/d.swift" && EditorStore.diffID(EditorStore.DiffSpec(change: GitChange(group: .staged, path: "src/d.swift", letter: "M"), path: "/p/src/d.swift", root: "/p", repository: "/p")) != diffID,
                     "A diff tab is distinct from the file's tab and per group")
        var diffTab = diffs.tab(diffID, in: "w1")!
        precondition(diffTab.load == .diff(hunkA) && diffTab.isPreview && !diffTab.canEdit && diffTab.name == "d.swift")
        diffs.edit(diffID, in: "w1", text: "nope")
        precondition(diffs.tab(diffID, in: "w1")?.isDirty == false, "A diff can't be edited")
        diffs.reloadDiffs(in: "w1")
        try await settle()
        precondition(diffReads == 2, "Diffs reload on request")
        // A file preview replaces a diff preview; a kept diff stays.
        let f1 = FakeFile("f")
        diffs.open("/p/f", in: "w1", preview: true, io: f1.io)
        try await settle()
        precondition(diffs.tabs(in: "w1").map(\.id) == ["/p/f"])
        diffs.openDiff(spec, in: "w1", preview: false) { hunkA }
        diffs.open("/p/base", in: "w1", preview: false, readOnlyNote: "Deleted", transient: true, io: f1.io)
        try await settle()
        diffTab = diffs.tab(diffID, in: "w1")!
        precondition(!diffTab.isPreview)
        diffs.keep("/p/f", in: "w1")
        precondition(diffs.remembered == ["w1": [.init(path: "/p/f")]], "Diff and base-version tabs aren't remembered")
        var watched: [String] = []
        await diffs.checkDisk { paths in watched = paths; return [:] }
        precondition(watched == ["/p/f"], "Only real files are watched")

        // Images and PDFs load their bytes through readData, never as text; too large says so.
        let media = makeStore()
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0, 0, 0, 0])
        var textReads = 0
        let mediaIO = EditorFileIO(read: { textReads += 1; return FileContents.decode(png) }, write: { _, _, _ in throw FileSaveError.readOnly },
                                   readData: { .data(png) })
        media.open("/p/logo.png", in: "w1", preview: true, io: mediaIO)
        media.open("/p/guide.PDF", in: "w1", preview: false, io: EditorFileIO(read: { FileContents.decode(Data()) },
            write: { _, _, _ in throw FileSaveError.readOnly }, readData: { .tooLarge(60 << 20) }))
        try await settle()
        precondition(media.tab("/p/logo.png", in: "w1")?.load == .media(.data(png)) && textReads == 0, "Images load as bytes")
        precondition(media.tab("/p/guide.PDF", in: "w1")?.load == .media(.tooLarge(60 << 20)), "Too large media says so")
        precondition(media.tab("/p/logo.png", in: "w1")?.canEdit == false && media.tab("/p/logo.png", in: "w1")?.baseline == nil)
        // A text file with a readData reader still opens as text.
        media.open("/p/notes.md", in: "w1", preview: false, io: EditorFileIO(read: { FileContents.decode(Data("# Hi\n".utf8)) },
            write: { _, _, _ in throw FileSaveError.readOnly }, readData: { .data(png) }))
        try await settle()
        guard case .loaded? = media.tab("/p/notes.md", in: "w1")?.load else { preconditionFailure("Markdown opens as text") }
        // Edit / Preview, with a heading to scroll to.
        media.setPreview("/p/notes.md", in: "w1", true, fragment: "build")
        precondition(media.tab("/p/notes.md", in: "w1")?.showsPreview == true && media.tab("/p/notes.md", in: "w1")?.previewFragment == "build")
        media.setPreview("/p/notes.md", in: "w1", false)
        precondition(media.tab("/p/notes.md", in: "w1")?.showsPreview == false && media.tab("/p/notes.md", in: "w1")?.previewFragment == nil)

        // A new folder for the space closes tabs left from the old one, unless edited.
        let moving = makeStore()
        let m1 = FakeFile("a"), m2 = FakeFile("b"), m3 = FakeFile("c")
        moving.open("/old/a.swift", in: "w1", preview: false, io: m1.io)
        moving.open("/old/b.swift", in: "w1", preview: false, io: m2.io)
        moving.open("/new/c.swift", in: "w1", preview: false, io: m3.io)
        moving.open("/old/a.swift", in: "w2", preview: false, io: m1.io)
        try await settle()
        moving.edit("/old/b.swift", in: "w1", text: "b!")
        moving.closeTabs(in: "w1", keepingUnder: ["/new", "/private/new"])
        precondition(moving.tabs(in: "w1").map(\.id) == ["/old/b.swift", "/new/c.swift"], "Clean tabs outside the new folder close; edited ones stay")
        precondition(moving.tabs(in: "w2").map(\.id) == ["/old/a.swift"], "Other spaces are untouched")
        let m4 = FakeFile("d")
        moving.open("/newer/d.swift", in: "w1", preview: false, io: m4.io)
        try await settle()
        moving.closeTabs(in: "w1", keepingUnder: ["/new"])
        precondition(moving.tab("/newer/d.swift", in: "w1") == nil && moving.tab("/new/c.swift", in: "w1") != nil, "A folder named like the new one isn't inside it")

        // Remembered tabs: kept ones (and edited previews) per space, saved per device, reopened behind the terminals.
        let defaultsName = "uherdr-editor-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let stores = EditorStores(drafts: drafts, defaults: defaults)
        stores.spaceInfo = { _, _ in ("uherdr", "/p") }
        let first = stores.store(for: device)
        let r1 = FakeFile("r1"), r2 = FakeFile("r2"), r3 = FakeFile("r3")
        first.open("/p/r1", in: "w1", preview: false, io: r1.io)
        first.open("/p/r2", in: "w1", preview: false, readOnlyNote: EditorStore.outsideNote, io: r2.io)
        first.open("/p/r3", in: "w1", preview: true, io: r3.io)
        try await settle()
        precondition(first.remembered == ["w1": [.init(path: "/p/r1"), .init(path: "/p/r2", outsideLink: true)]], "Clean previews aren't remembered")
        let relaunched = EditorStores(drafts: drafts, defaults: defaults).store(for: device)
        precondition(relaunched.waitingToReopen == first.remembered, "Tabs are saved for the next launch")
        precondition(relaunched.remembered == first.remembered, "Spaces not reopened yet stay remembered")
        var asked: [EditorStore.Remembered] = []
        relaunched.reopen(in: "w1") { entry in asked.append(entry); return entry.path == "/p/r1" ? r1.io : r2.io }
        try await settle()
        precondition(asked.map(\.outsideLink) == [false, true] && relaunched.tabs(in: "w1").map(\.id) == ["/p/r1", "/p/r2"])
        precondition(relaunched.activeTab(in: "w1") == nil, "Reopened tabs wait behind the terminals")
        precondition(relaunched.tab("/p/r2", in: "w1")?.canEdit == false, "A link outside the space reopens read-only")
        precondition(relaunched.waitingToReopen.isEmpty)
        // The menus' state follows the shown editor's edits.
        precondition(stores.menuState[device] == .init(shown: ["w1"], savable: []))
        first.edit("/p/r1", in: "w1", text: "r1!")
        precondition(stores.menuState[device] == .init(shown: ["w1"], savable: []), "Only the shown editor counts")
        first.show("/p/r1", in: "w1")
        precondition(stores.menuState[device] == .init(shown: ["w1"], savable: ["w1"]))
        first.showTerminals(in: "w1")
        precondition(stores.menuState[device] == .init(), "Terminals shown: no editor commands")
        first.discardEdits("/p/r1", in: "w1")
        try await settle()
        // ⌥⌘V is offered only while a Markdown file shows.
        let md = FakeFile("# x\n")
        first.open("/p/readme.md", in: "w1", preview: false, io: md.io)
        try await settle()
        precondition(stores.menuState[device]?.markdown == ["w1"], "Markdown shown: the preview command is on")
        first.show("/p/r1", in: "w1")
        precondition(stores.menuState[device]?.markdown == [], "Other files: off")
        // Pruned spaces forget what was waiting; a removed device forgets everything.
        let pruning = EditorStores(drafts: drafts, defaults: defaults).store(for: device)
        pruning.prune(keeping: ["w9"])
        precondition(pruning.waitingToReopen.isEmpty)
        try drafts.save(Draft(profileID: device, workspaceID: "w1", spaceLabel: "uherdr", root: "/p", path: "/p/z", text: "z", baselineSHA: ""))
        stores.forget(profile: device)
        precondition(defaults.data(forKey: EditorStores.tabsKey(device)) == nil && drafts.all(profile: device).isEmpty, "Removing a device drops its tabs and drafts")
        print("PASS: editing: dirty and kept, drafts after typing, save, typing during save, conflict/overwrite/discard, in-place question, unknown SSH outcome both ways, reload on disk change, previews never replace edits, remembered tabs, pruning keeps drafts, recovered drafts, close prompt, quit Save All / Don't Save, remembered and reopened tabs, device removal, disk watching, reload guards, diff tabs, media and Markdown preview tabs")
    }
}
