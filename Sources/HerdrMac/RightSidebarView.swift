import AppKit
import SwiftUI
import HerdrCore

enum RightSidebarTab: String, CaseIterable, Identifiable {
    case files, changes, search
    var id: String { rawValue }
    var title: String {
        switch self {
        case .files: return "Files"
        case .changes: return "Changes"
        case .search: return "Search"
        }
    }
}

/// Files, Changes and Search for the selected space's folder.
struct RightSidebarView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var files: FileTreeModel
    @ObservedObject var editors: EditorStore
    @ObservedObject var changes: ChangesModel
    @ObservedObject var search: SearchModel
    /// Bumped by ⇧⌘F to focus the search field.
    var searchFocus = 0
    @AppStorage("rightSidebar.tab") private var tab: RightSidebarTab = .files
    @State private var choosingRemoteFolder = false
    /// The space whose memory was restored; until then nothing is saved, so a
    /// space switch (which clears the tree first) can't overwrite it.
    @State private var restoredKey = ""

    var body: some View {
        VStack(spacing: 0) {
            // The same native segmented control as Spaces / Agents in the left sidebar.
            Picker("Sidebar section", selection: $tab) {
                ForEach(RightSidebarTab.allCases) { item in
                    Text(item == .changes && changes.count.map { $0 > 0 } == true ? "Changes \(changes.count!)" : item.title).tag(item)
                }
            }
            .pickerStyle(.segmented).labelsHidden()
            .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 8)
            if store.currentSpace == nil {
                placeholder("No space selected", "Choose a space in the left sidebar.", systemImage: "square.stack.3d.up")
            } else if store.currentRoot == nil {
                chooseFolder
            } else {
                if store.isRemote && !store.connected { disconnectedBar }
                header
                Divider()
                switch tab {
                case .files: filesTab
                case .changes:
                    ChangesView(model: changes, deviceName: store.displayName, isRemote: store.isRemote,
                                activeID: activeEditorPath, onOpen: openChange)
                case .search:
                    SearchView(model: search, folderLabel: abbreviated(store.currentRoot ?? ""), deviceName: store.displayName, activeResult: activeResult,
                               onOpen: openHit, focusRequest: searchFocus)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { syncRoot() }
        .onChange(of: store.currentRoot) { _, _ in syncRoot() }
        .task(id: changesKey) {
            // Status is read while the sidebar is on screen: every 3 s here,
            // every 10 s over SSH and only while the device is connected.
            let session = store
            let runner: ScriptRunner = store.isRemote ? .remote(store.remoteShell) : .local
            changes.open(root: store.currentRoot, runner: runner, key: changesKey)
            search.open(root: store.currentRoot, runner: runner, ripgrep: store.isRemote ? nil : ContentSearch.localRipgrep(), key: changesKey)
            configureInstaller(session)
            await restoreMemory()
            search.unsavedText = { [weak editors, weak files] in
                guard let editors, let files, let space = session.selectedSpace, let root = files.canonicalRoot else { return [:] }
                return Self.unsavedText(editors.tabs(in: space), root: root)
            }
            changes.onChange = { [weak editors] in if let space = session.selectedSpace { editors?.reloadDiffs(in: space) } }
            guard store.currentRoot != nil else { return }
            await changes.watch(every: store.isRemote ? .seconds(10) : .seconds(3)) { !session.isRemote || session.connected }
        }
        .sheet(isPresented: $choosingRemoteFolder) {
            RemoteFolderSheet(store: store) { path in if let space = store.selectedSpace { folderChanged(to: path, in: space) } }
        }
        .onChange(of: tab) { _, _ in saveMemory() }
        .onChange(of: files.expanded) { _, _ in saveMemory() }
        .onChange(of: search.options) { _, _ in saveMemory() }
    }

    private var activeEditorPath: String? { store.selectedSpace.flatMap { editors.activeTab(in: $0)?.id } }
    private var activeFilePath: String? { store.selectedSpace.flatMap { editors.activeTab(in: $0)?.filePath } }

    private func open(_ path: String, keep: Bool, outsideLink: Bool) {
        guard let space = store.selectedSpace, let io = files.io(for: path, outsideLink: outsideLink) else { return }
        editors.open(path, in: space, preview: !keep, readOnlyNote: outsideLink ? EditorStore.outsideNote : nil, io: io)
        store.focusOwner = .editor
    }

    /// Puts back what this space showed last time: its tab, open folders and search.
    private func restoreMemory() async {
        let key = changesKey
        guard let space = store.selectedSpace else { return }
        let memory = SidebarMemory.load(profile: store.profile.id, from: .standard)[space]
        if let memory {
            if let saved = RightSidebarTab(rawValue: memory.tab) { tab = saved }
            search.options = SearchOptions(query: memory.search.query, caseSensitive: memory.search.caseSensitive,
                                           wholeWord: memory.search.wholeWord, include: memory.search.include, exclude: memory.search.exclude)
        } else {
            search.options = SearchOptions(query: "")
        }
        syncRoot()
        if let memory, !memory.expanded.isEmpty { await files.restoreExpanded(memory.expanded) }
        guard key == changesKey else { return }
        restoredKey = key
    }

    private func saveMemory() {
        guard restoredKey == changesKey, let space = store.selectedSpace, files.canonicalRoot != nil else { return }
        let options = search.options
        let memory = SidebarMemory(tab: tab.rawValue, expanded: files.expandedRelative,
                                   search: .init(query: options.query, caseSensitive: options.caseSensitive, wholeWord: options.wholeWord,
                                                 include: options.include, exclude: options.exclude))
        SidebarMemory.save(memory == SidebarMemory() ? nil : memory, space: space, profile: store.profile.id, to: .standard)
    }

    private var changesKey: String { "\(store.profile.id.uuidString)|\(store.selectedSpace ?? "")|\(store.currentRoot ?? "")" }

    /// The tab a Changes row opens: a conflict opens the file itself (its
    /// markers are resolved there); everything else opens a read-only diff.
    static func changeTabID(_ change: GitChange, changes: GitChanges, root: String? = nil) -> String {
        let path = filePath(change, changes: changes, root: root)
        if change.group == .conflicts { return path }
        return EditorStore.diffID(EditorStore.DiffSpec(change: change, path: path, root: root ?? changes.repositoryRoot, repository: changes.repositoryRoot))
    }

    /// A change's path under the space folder as the Files tree spells it, so
    /// opening it from either panel gives the same tab.
    static func filePath(_ change: GitChange, changes: GitChanges, root: String?) -> String {
        guard let root else { return changes.absolutePath(change.path) }
        let relative = String(change.path.dropFirst(changes.prefix.count))
        return root == "/" ? "/" + relative : (root.hasSuffix("/") ? String(root.dropLast()) : root) + "/" + relative
    }

    private func openChange(_ change: GitChange, keep: Bool) {
        guard let space = store.selectedSpace, let status = changes.changes else { return }
        let root = files.canonicalRoot
        let path = Self.filePath(change, changes: status, root: root)
        if change.group == .conflicts {
            open(path, keep: keep, outsideLink: false)
            return
        }
        let runner: ScriptRunner = store.isRemote ? .remote(store.remoteShell) : .local
        let repository = status.repositoryRoot
        let spec = EditorStore.DiffSpec(change: change, path: path, root: root ?? repository, repository: repository)
        editors.openDiff(spec, in: space, preview: !keep) {
            try await GitDiffReader.read(change, repositoryRoot: repository, runner: runner)
        }
        store.focusOwner = .editor
    }

    /// "Install for uHerdr" for an SSH device: the build matching its OS and
    /// CPU, from the app's ripgrep resources.
    private func configureInstaller(_ session: SessionStore) {
        guard session.isRemote, let folder = Bundle.main.resourceURL?.appendingPathComponent("ripgrep"),
              FileManager.default.fileExists(atPath: folder.path) else {
            search.installer = nil
            search.installTarget = nil
            return
        }
        search.installTarget = RipgrepInstaller.version
        search.installer = {
            let shell = session.remoteShell
            let platform = try await RipgrepInstaller.platform(of: shell)
            let binary = try RipgrepInstaller.binary(for: platform, in: folder)
            return try await RipgrepInstaller.install(binary, on: shell)
        }
        Task { [weak search] in
            if let platform = try? await RipgrepInstaller.platform(of: session.remoteShell) {
                search?.installTarget = "\(RipgrepInstaller.version) (\(platform.rawValue))"
            }
        }
    }

    /// Text of tabs with unsaved edits under the folder, by relative path.
    static func unsavedText(_ tabs: [EditorStore.Tab], root: String) -> [String: String] {
        let prefix = root.hasSuffix("/") ? root : root + "/"
        var result: [String: String] = [:]
        for tab in tabs where tab.isDirty && !tab.isTransient && tab.id.hasPrefix(prefix) { result[String(tab.id.dropFirst(prefix.count))] = tab.text }
        return result
    }

    private var activeResult: (path: String, line: Int)? {
        guard let space = store.selectedSpace, let tab = editors.activeTab(in: space), let reveal = tab.reveal,
              let root = files.canonicalRoot else { return nil }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard tab.id.hasPrefix(prefix) else { return nil }
        return (String(tab.id.dropFirst(prefix.count)), reveal.line)
    }

    /// A search result opens its file (preview unless kept) at the match.
    private func openHit(_ hit: SearchHit, keep: Bool) {
        guard let space = store.selectedSpace, let root = files.canonicalRoot else { return }
        let path = (root.hasSuffix("/") ? root : root + "/") + hit.path
        open(path, keep: keep, outsideLink: false)
        editors.reveal(path, in: space, line: hit.line, columns: hit.ranges.first ?? 0..<0)
    }

    private func syncRoot() {
        files.open(root: store.currentRoot, source: store.isRemote ? .remote(store.remoteShell) : .local)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: store.isRemote ? "server.rack" : "laptopcomputer").font(.system(size: 10))
                Text(store.displayName).lineLimit(1)
                Spacer()
                Menu {
                    Button("Change Folder…") { chooseRoot() }
                    Button("Copy Folder Path") { FileOutlineView.Coordinator.copy(store.currentRoot ?? "") }
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help("Folder actions")
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
            Text(abbreviated(store.currentRoot ?? ""))
                .font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                .help(store.currentRoot ?? "")
                .textSelection(.enabled)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    /// Frame 08: the device is away; what's shown is the last listing.
    private var disconnectedBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
            Text("Disconnected" + (files.listedAt.map { " · last listing from \($0.formatted(date: .omitted, time: .shortened))" } ?? ""))
                .lineLimit(1)
            Spacer()
            if store.connecting { ProgressView().controlSize(.mini) } else {
                Button { store.reconnect() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Reconnect").accessibilityLabel("Reconnect")
            }
        }
        .font(.system(size: 11, weight: .medium)).foregroundStyle(.red)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Color.red.opacity(0.12))
    }

    @ViewBuilder private var filesTab: some View {
        HStack(spacing: 6) {
            FilterChip(title: "Hidden", isOn: $files.showHidden, help: "Show files and folders whose names start with a dot")
            FilterChip(title: "Ignored", isOn: $files.showIgnored, help: "Show files Git ignores (dimmed)")
            Spacer()
            iconButton("scope", "Reveal the open file in the tree") {
                if let path = activeFilePath { Task { await files.reveal(path) } }
            }.disabled(activeFilePath == nil)
            iconButton("arrow.down.right.and.arrow.up.left", "Collapse all folders") { files.collapseAll() }
            iconButton("arrow.clockwise", "Reload the open folders") { files.refresh() }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        Divider()
        if let error = files.rootError {
            placeholder("Can't open this folder", error, systemImage: "exclamationmark.triangle") {
                Button("Choose Another Folder…") { chooseRoot() }
            }
        } else if case .failed(let message)? = files.canonicalRoot.flatMap({ files.folders[$0] }) {
            placeholder("Can't read this folder", message, systemImage: "lock")
        } else if case .loaded? = files.canonicalRoot.flatMap({ files.folders[$0] }), files.canonicalRoot.map({ files.children(of: $0).isEmpty }) == true {
            placeholder("Empty folder", files.showHidden ? "This folder has no files." : "Only hidden files are here. Turn on Hidden to see them.", systemImage: "folder")
        } else {
            FileOutlineView(model: files, onFocus: { store.focusOwner = .sidebar }, onOpen: { path, keep, outsideLink in open(path, keep: keep, outsideLink: outsideLink) })
                // Dimmed while an SSH device is away: it's the last listing.
                .opacity(store.isRemote && !store.connected ? 0.55 : 1)
        }
    }

    private var chooseFolder: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "folder").font(.system(size: 22, weight: .light)).foregroundStyle(.secondary)
            Text("Choose this space's folder").font(.system(size: 13, weight: .semibold))
            Text("Files, Changes and Search work inside one folder. “\(store.currentSpace?.label ?? "This space")” was created outside uHerdr, so pick its folder once. Changing directory in a terminal won't move it.")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("Choose…") { chooseRoot() }.buttonStyle(.borderedProminent)
            Text("You can change it later from the ⋯ menu in this header.").font(.system(size: 11)).foregroundStyle(.tertiary)
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
    }

    private func chooseRoot() {
        guard let space = store.selectedSpace else { return }
        if store.isRemote { choosingRemoteFolder = true; return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Folder"
        panel.message = "Choose the folder for “\(store.currentSpace?.label ?? "this space")”."
        if let current = store.currentRoot { panel.directoryURL = URL(fileURLWithPath: current) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        folderChanged(to: url.path, in: space)
    }

    /// A new folder for the space: remember it, and close tabs left from the old one.
    private func folderChanged(to path: String, in space: String) {
        store.setRoot(path, for: space)
        editors.closeTabs(in: space, keepingUnder: [path] + (store.isRemote ? [] : [PathBoundary.canonical(path)].compactMap { $0 }))
    }

    private func abbreviated(_ path: String) -> String {
        guard !store.isRemote else { return path }
        let home = NSHomeDirectory()
        return path == home ? "~" : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    private func iconButton(_ systemImage: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: systemImage).font(.system(size: 11)).frame(width: 22, height: 20) }
            .buttonStyle(.plain).help(help).accessibilityLabel(help)
    }

    private func placeholder(_ title: String, _ message: String, systemImage: String) -> some View {
        placeholder(title, message, systemImage: systemImage) { EmptyView() }
    }

    private func placeholder<Actions: View>(_ title: String, _ message: String, systemImage: String, @ViewBuilder actions: () -> Actions) -> some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage).font(.system(size: 22, weight: .light)).foregroundStyle(.tertiary)
            Text(title).font(.system(size: 12, weight: .semibold))
            Text(message).font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            actions()
        }
        .padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A Files toolbar switch whose state reads the same in an active or inactive window.
private struct FilterChip: View {
    let title: String
    @Binding var isOn: Bool
    let help: String

    var body: some View {
        Button { isOn.toggle() } label: {
            Label(title, systemImage: isOn ? "eye" : "eye.slash")
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 7).padding(.vertical, 3)
                .foregroundStyle(isOn ? herdrAccentColor : Color.secondary)
                .background(isOn ? herdrAccentColor.opacity(0.16) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(isOn ? herdrAccentColor.opacity(0.45) : Color.secondary.opacity(0.3)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "Shown" : "Hidden")
        .accessibilityAddTraits(.isButton)
    }
}

/// An SSH device's folder is typed: there is no file panel for a remote Mac or server.
private struct RemoteFolderSheet: View {
    @ObservedObject var store: SessionStore
    var onChoose: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var path = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Folder on \(store.profile.name)").font(.headline)
            Text("Enter the absolute path of this space's folder on the device.").foregroundStyle(.secondary)
            TextField("/home/you/project", text: $path).font(.system(.body, design: .monospaced)).frame(width: 380)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Use Folder") {
                    onChoose(path)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!path.hasPrefix("/"))
            }
        }
        .padding(20)
        .onAppear { path = store.currentRoot ?? "" }
    }
}
