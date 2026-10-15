import SwiftUI
import HerdrCore

let herdrAccentColor = Color(red: 0.34, green: 0.73, blue: 0.58)

struct WorkspaceView: View {
    @ObservedObject private var shortcuts = ShortcutSettings.shared
    @ObservedObject var store: SessionStore
    @ObservedObject var devices: DeviceStore
    @ObservedObject var editors: EditorStore
    @StateObject private var shortcutHints = ShortcutHintMonitor()
    @State private var sidebarVisibility: NavigationSplitViewVisibility = .all
    @State private var newSessionName = ""
    @StateObject private var files = FileTreeModel()
    @StateObject private var changes = ChangesModel()
    @StateObject private var search = SearchModel()
    @StateObject private var quickOpen = QuickOpenModel()
    @State private var showingQuickOpen = false
    @State private var showingGoToLine = false
    @State private var searchFocus = 0
    @AppStorage("rightSidebar.tab") private var sidebarTab: RightSidebarTab = .files
    @AppStorage("rightSidebar.visible") private var rightSidebarVisible = true
    @AppStorage("rightSidebar.width") private var rightSidebarWidth = 300.0
    @State private var windowWidth = 1280.0
    @State private var sidebarResizeStartWidth: Double?
    @State private var drawerOpen = false
    /// Below this window width the right sidebar becomes a drawer over the content.
    static let drawerThreshold = 1000.0
    var body: some View {
        windowContent
        .overlay(alignment: .top) {
            if showingQuickOpen {
                ZStack(alignment: .top) {
                    Color.black.opacity(0.001).onTapGesture { showingQuickOpen = false }
                    QuickOpenView(model: quickOpen, place: "\(store.displayName) · \(store.currentRoot ?? "")",
                                  onOpen: openQuickOpenResult, onClose: { showingQuickOpen = false })
                        .padding(.top, 48)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .uherdrQuickOpen)) { _ in presentQuickOpen() }
        .onChange(of: showingQuickOpen) { _, shown in PaletteState.shared.quickOpenShown = shown }
        .overlay(alignment: .top) {
            if showingGoToLine, let editor = activeEditor, case let .text(text)? = editor.baseline?.kind {
                ZStack(alignment: .top) {
                    Color.black.opacity(0.001).onTapGesture { showingGoToLine = false }
                    GoToLineView(lineCount: (editor.text ?? text).reduce(1) { $1 == "\n" ? $0 + 1 : $0 },
                                 onGo: { line, column in
                                     showingGoToLine = false
                                     editors.setPreview(editor.id, in: store.selectedSpace ?? "", false)
                                     editors.reveal(editor.id, in: store.selectedSpace ?? "", line: line, columns: (column - 1)..<(column - 1), focus: true)
                                     store.focusOwner = .editor
                                 },
                                 onClose: { showingGoToLine = false })
                        .padding(.top, 48)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .uherdrGoToLine)) { _ in showingGoToLine = activeEditor != nil }
        .onReceive(NotificationCenter.default.publisher(for: .uherdrSidebar)) { note in
            switch note.object as? String {
            case "toggle": toggleRightSidebar()
            case "files", "changes":
                sidebarTab = note.object as? String == "files" ? .files : .changes
                if isNarrow { drawerOpen = true } else { rightSidebarVisible = true }
            default: break
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .uherdrSearchInSpace)) { _ in
            sidebarTab = .search
            if isNarrow { drawerOpen = true } else { rightSidebarVisible = true }
            searchFocus += 1
        }
    }

    private var windowContent: some View {
        // Split from the alerts and lifecycle below: one chain of all of them
        // is more than the type checker finishes in reasonable time.
        splitView
        .sheet(item: $store.sheet) { sheet in
            if case .shortcuts = sheet { KeyboardShortcutsSheet() } else { EditorSheet(sheet: sheet, store: store) }
        }
        .sheet(item: $devices.editor) { target in DeviceEditorSheet(target: target, devices: devices) }
        .alert("Remove device?", isPresented: Binding(get: { devices.pendingRemoval != nil }, set: { if !$0 { devices.pendingRemoval = nil } })) {
            Button("Cancel", role: .cancel) { devices.pendingRemoval = nil }
            Button("Remove", role: .destructive) {
                if let id = devices.pendingRemoval { devices.remove(id) }
                devices.pendingRemoval = nil
            }
        } message: { Text("This removes the saved connection. Workspaces and running processes on the device are kept.") }
        .alert(sessionActionTitle, isPresented: Binding(get: { devices.pendingSessionAction != nil }, set: { if !$0 { devices.pendingSessionAction = nil } }), presenting: devices.pendingSessionAction) { action in
            Button("Cancel", role: .cancel) { devices.pendingSessionAction = nil }
            switch action {
            case .stop:
                Button("Stop Session") { runSessionAction(action) }.keyboardShortcut(.defaultAction)
            case .remove:
                Button("Remove Session", role: .destructive) { runSessionAction(action) }
            case .restart:
                Button("Restart Session") { runSessionAction(action) }.keyboardShortcut(.defaultAction)
            }
        } message: { action in
            switch action {
            case .stop: Text("Its shells and agents end. You can start it again from herdr.")
            case .remove: Text("This stops the session if it’s running and deletes it from herdr, including its saved snapshots. This can’t be undone.")
            case .restart: Text("Its shells and agents end, and the session reopens from its saved state.")
            }
        }
        .modifier(HerdrPromptAlert(devices: devices))
        .alert(machineRemovalTitle, isPresented: Binding(get: { devices.pendingMachineRemoval != nil }, set: { if !$0 { devices.pendingMachineRemoval = nil } })) {
            Button("Cancel", role: .cancel) { devices.pendingMachineRemoval = nil }
            Button("Remove Machine", role: .destructive) {
                if let id = devices.pendingMachineRemoval { devices.removeMachine(id) }
                devices.pendingMachineRemoval = nil
            }
        } message: { Text("This removes the saved SSH connection from uHerdr. The herdr sessions on \(devices.pendingMachineRemoval.flatMap { devices.machine($0)?.name } ?? "that machine") keep running.") }
        .alert("New session", isPresented: $devices.newSessionPrompt) {
            TextField("Name", text: $newSessionName)
            Button("Cancel", role: .cancel) { newSessionName = "" }
            Button("Create") {
                let name = newSessionName.trimmingCharacters(in: .whitespaces)
                newSessionName = ""
                Task { await devices.createHerdrSession(named: name) }
            }.keyboardShortcut(.defaultAction)
        } message: { Text("Starts a new herdr session on this Mac. Use letters, numbers, “.”, “_” and “-”.") }
        .alert("Couldn’t complete the action", isPresented: Binding(get: { store.operationError != nil }, set: { if !$0 { store.operationError = nil } })) {
            Button("OK") { store.operationError = nil }
        } message: { Text(store.operationError ?? "") }
        .alert("Save changes to “\(pendingEditorCloseName)” before closing?", isPresented: Binding(get: { editors.pendingClose != nil }, set: { if !$0 { editors.pendingClose = nil } })) {
            Button("Save") {
                guard let pending = editors.pendingClose else { return }
                Task { await editors.saveAndClose(pending) }
            }.keyboardShortcut(.defaultAction)
            Button("Don't Save", role: .destructive) {
                if let pending = editors.pendingClose { editors.close(pending.id, in: pending.space) }
                editors.pendingClose = nil
            }
            Button("Cancel", role: .cancel) { editors.pendingClose = nil }
        } message: {
            Text("If you don't save, your edits in this tab will be lost.")
        }
        .alert("Close \(store.pendingClose?.singular ?? "resource")?", isPresented: Binding(get: { store.pendingClose != nil }, set: { if !$0 { store.pendingClose = nil } })) {
            // Return confirms (a destructive button is never the default on its own); Esc cancels.
            // Declared first so an earlier Cancel can't take Return.
            Button("Close \(store.pendingClose?.singular ?? "resource")", role: .destructive) {
                if let target = store.pendingClose { store.close(target) }
                store.pendingClose = nil
            }.keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) { store.pendingClose = nil }
        } message: {
            Text("Closing “\(store.pendingClose?.label ?? "")” terminates its terminals and running agents. You can quit uHerdr instead to keep them running.")
        }
        .background(WindowAccessor())
        .onChange(of: store.workspaces) { _, spaces in
            // Only a live snapshot says a space is gone; an emptied list while
            // the device is being edited doesn't.
            if store.connected {
                editors.prune(keeping: Set(spaces.map(\.id)))
                SidebarMemory.prune(keeping: Set(spaces.map(\.id)), profile: store.profile.id, in: .standard)
            }
            reopenEditorTabs()
        }
        .onChange(of: store.workspaceRoots) { _, _ in reopenEditorTabs() }
        .onAppear { reopenEditorTabs() }
        .task(id: store.profile.id) {
            // Open files are checked every second here, every 5 s over SSH
            // (one ssh call for all of them), and only while connected.
            let session = store
            await editors.watchDisk(every: session.isRemote ? .seconds(5) : .seconds(1)) { paths in
                guard session.isRemote else { return await Task.detached { FileStamps.local(paths) }.value }
                guard session.connected else { throw CancellationError() }
                return try await FileStamps.remote(paths, shell: session.remoteShell)
            }
        }
        .background(GeometryReader { proxy in
            Color.clear
                .onAppear { windowWidth = proxy.size.width }
                .onChange(of: proxy.size.width) { _, width in windowWidth = width }
        })
        .task { devices.start() }
        .onAppear { shortcutHints.start() }
        .onDisappear { shortcutHints.stop() }
    }

    private var splitView: some View {
        NavigationSplitView(columnVisibility: $sidebarVisibility) {
            DeviceSidebarView(devices: devices, showShortcutHints: shortcutHints.isHeld)
                // The column width alone is ignored on a first launch (no saved
                // width), which opened the sidebar at 144 pt; the content's own
                // minimum keeps it usable.
                .frame(minWidth: 220)
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 360)
                .toolbar(removing: .sidebarToggle)
        } detail: {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        if store.connected {
                            if store.currentSpace != nil {
                                tabStrip
                                Divider()
                                terminalDeck
                                    .id(store.connectionGeneration)
                                    .padding(8)
                            } else {
                                emptySpaces
                            }
                        } else if let space = store.selectedSpace, !editors.tabs(in: space).isEmpty {
                            // Open files stay readable and editable while the
                            // device is down; Save waits for the connection.
                            offlineEditorStrip(space)
                            Divider()
                            if let editor = activeEditor {
                                editorHost(editor).padding(8)
                            } else {
                                connectionView
                            }
                        } else {
                            connectionView
                        }
                    }
                    if showsDockedSidebar {
                        sidebarResizeHandle
                        RightSidebarView(store: store, files: files, editors: editors, changes: changes, search: search, searchFocus: searchFocus)
                            .frame(width: rightSidebarWidth)
                    }
                }
                .overlay(alignment: .trailing) {
                    if showsDrawer {
                        RightSidebarView(store: store, files: files, editors: editors, changes: changes, search: search, searchFocus: searchFocus)
                            .frame(width: min(rightSidebarWidth, 320))
                            .overlay(alignment: .leading) { Divider() }
                            .shadow(color: .black.opacity(0.35), radius: 16, x: -6)
                            .onExitCommand { drawerOpen = false }
                            .transition(.move(edge: .trailing))
                    }
                }
                Divider()
                statusBar
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .navigationTitle("\(store.displayName) — \(store.currentSpace?.label ?? "uHerdr")")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    HStack(spacing: 2) {
                        if store.busy { ProgressView().controlSize(.mini) }
                        compactToolbarButton("Start agent", systemImage: "sparkles") {
                            store.sheet = .agent(store.selectedPane ?? "")
                        }
                        .help("Start a coding agent in the selected pane")
                        compactToolbarButton("Split side by side", systemImage: "rectangle.split.2x1") {
                            store.split(.right)
                        }
                        .help("Split side by side (⌘D)")
                        compactToolbarButton("Split top and bottom", systemImage: "rectangle.split.1x2") {
                            store.split(.down)
                        }
                        .help("Split top and bottom (⇧⌘D)")
                    }
                    .disabled(store.selectedPane == nil || !store.connected || store.busy)
                }
                ToolbarItem(placement: .primaryAction) {
                    compactToolbarButton("Toggle right sidebar", systemImage: "sidebar.right") { toggleRightSidebar() }
                        .foregroundStyle(rightSidebarShown ? herdrAccentColor : Color.secondary)
                        .help(rightSidebarShown ? "Hide Files, Changes and Search" : "Show Files, Changes and Search")
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                compactToolbarButton("Toggle sidebar", systemImage: "sidebar.left") {
                    withAnimation {
                        sidebarVisibility = sidebarVisibility == .detailOnly ? .all : .detailOnly
                    }
                }
                .help("Show or hide sidebar")
            }
        }
        .tint(herdrAccentColor)
        .accentColor(herdrAccentColor)
        .frame(minWidth: 840, minHeight: 520)
        .preferredColorScheme(store.colorScheme)
    }

    private func requestClose(_ id: String, in space: String) { editors.requestClose(id, in: space) }

    private func presentQuickOpen() {
        guard let root = store.currentRoot, let space = store.selectedSpace else { return }
        let base = files.canonicalRoot ?? root
        let prefix = base.hasSuffix("/") ? base : base + "/"
        let tabs = editors.tabs(in: space).filter { !$0.isTransient && $0.id.hasPrefix(prefix) }
        quickOpen.open = Set(tabs.map { String($0.id.dropFirst(prefix.count)) })
        quickOpen.unsaved = Set(tabs.filter(\.isDirty).map { String($0.id.dropFirst(prefix.count)) })
        quickOpen.load(root: root, runner: store.isRemote ? .remote(store.remoteShell) : .local,
                       ripgrep: store.isRemote ? nil : ContentSearch.localRipgrep(), key: "\(store.profile.id)|\(root)")
        showingQuickOpen = true
    }

    private func openQuickOpenResult(_ relative: String, keep: Bool) {
        showingQuickOpen = false
        guard let space = store.selectedSpace, let base = files.canonicalRoot ?? store.currentRoot else { return }
        let path = (base.hasSuffix("/") ? base : base + "/") + relative
        guard let io = files.io(for: path) ?? store.currentRoot.flatMap({ FileTreeModel.io(for: path, outsideLink: false, root: $0,
                source: store.isRemote ? .remote(store.remoteShell) : .local) }) else { return }
        editors.open(path, in: space, preview: !keep, io: io)
        store.focusOwner = .editor
    }

    /// Reopens last run's editor tabs once herdr lists their space and its folder is known.
    private func reopenEditorTabs() {
        let source: FileTreeModel.Source = store.isRemote ? .remote(store.remoteShell) : .local
        for space in store.workspaces.map(\.id) where editors.waitingToReopen[space] != nil {
            guard let root = store.workspaceRoots.root(for: space) else { continue }
            editors.reopen(in: space) { FileTreeModel.io(for: $0.path, outsideLink: $0.outsideLink, root: root, source: source) }
        }
    }

    private var pendingEditorCloseName: String {
        editors.pendingClose.flatMap { editors.tab($0.id, in: $0.space)?.name } ?? "this file"
    }

    /// The terminal tab drawn as selected: none while an editor tab is shown.
    private var shownTerminalTab: String? { activeEditor == nil ? store.selectedTab : nil }

    private var isNarrow: Bool { windowWidth < Self.drawerThreshold }
    private var showsDockedSidebar: Bool { rightSidebarVisible && !isNarrow }
    private var showsDrawer: Bool { isNarrow && drawerOpen }
    private var rightSidebarShown: Bool { showsDockedSidebar || showsDrawer }

    private func toggleRightSidebar() {
        withAnimation(.easeOut(duration: 0.15)) {
            if isNarrow { drawerOpen.toggle() } else { rightSidebarVisible.toggle() }
        }
    }

    /// Drag to resize the docked sidebar (240–480 pt).
    private var sidebarResizeHandle: some View {
        Divider()
            .overlay {
                Color.clear.frame(width: 6).contentShape(Rectangle())
                    .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
                    .gesture(DragGesture(minimumDistance: 1).onChanged { value in
                        let start = sidebarResizeStartWidth ?? rightSidebarWidth
                        sidebarResizeStartWidth = start
                        rightSidebarWidth = min(480, max(240, start - value.translation.width))
                    }.onEnded { _ in sidebarResizeStartWidth = nil })
            }
    }

    private var sessionActionTitle: String {
        guard let action = devices.pendingSessionAction,
              let session = devices.sessions.first(where: { $0.profile.id == action.deviceID }) else { return "" }
        let name = session.profile.sessionName
        switch action {
        case .stop: return "Stop “\(name)”?"
        case .remove: return "Remove “\(name)”?"
        case .restart: return "Restart “\(name)”?"
        }
    }

    private var machineRemovalTitle: String {
        "Remove “\(devices.pendingMachineRemoval.flatMap { devices.machine($0)?.name } ?? "machine")”?"
    }

    private func runSessionAction(_ action: SessionAction) {
        devices.pendingSessionAction = nil
        guard let session = devices.sessions.first(where: { $0.profile.id == action.deviceID }) else { return }
        Task {
            switch action {
            case .stop: await devices.stopHerdrSession(session)
            case .remove: await devices.removeHerdrSession(session)
            case .restart: await devices.restartHerdrSession(session)
            }
        }
    }

    private var activeEditor: EditorStore.Tab? { store.selectedSpace.flatMap { editors.activeTab(in: $0) } }

    private var terminalDeck: some View {
        ZStack {
            TerminalTabDeck(store: store, showsTerminals: activeEditor == nil)
            if let editor = activeEditor {
                editorHost(editor)
            } else if store.currentLayout == nil {
                ProgressView("Loading terminals…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func editorHost(_ editor: EditorStore.Tab) -> some View {
        if let spec = editor.diff {
            DiffHostView(tab: editor, spec: spec, fontSize: store.fontSize, onOpenFile: { openFromDiff(spec) })
                .id(editor.id)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            fileEditorHost(editor)
        }
    }

    /// Open file in a diff tab: the file itself, or a deleted file's last
    /// version, read-only.
    private func openFromDiff(_ spec: EditorStore.DiffSpec) {
        guard let space = store.selectedSpace else { return }
        let remote = store.isRemote ? store.remoteShell : nil
        if spec.change.isDeleted {
            let runner: ScriptRunner = remote.map { .remote($0) } ?? .local
            let change = spec.change, repository = spec.repository
            editors.open(EditorStore.basePrefix + spec.path, in: space, preview: false, readOnlyNote: "Deleted · last committed version", transient: true,
                         io: EditorFileIO(read: { FileContents.decode(try await GitDiffReader.baseVersion(change, repositoryRoot: repository, runner: runner)) },
                                          write: { _, _, _ in throw FileSaveError.readOnly }))
        } else if let root = store.currentRoot,
                  let io = FileTreeModel.io(for: spec.path, outsideLink: false, root: root, source: remote.map { .remote($0) } ?? .local) {
            editors.open(spec.path, in: space, preview: false, io: io)
        }
        store.focusOwner = .editor
    }

    private func fileEditorHost(_ editor: EditorStore.Tab) -> some View {
        // The tree's spelling of the folder (resolved on this Mac), which tab paths use.
        let root = files.canonicalRoot ?? store.currentRoot
        let source: FileTreeModel.Source = store.isRemote ? .remote(store.remoteShell) : .local
        return EditorHostView(tab: editor, space: store.selectedSpace ?? "", editors: editors, root: root,
                       fontSize: store.fontSize, canSave: store.connected || !store.isRemote,
                       deviceName: store.displayName, onReconnect: { store.reconnect() },
                       isRemote: store.isRemote,
                       readAsset: root.map { root in
                           { path in
                               guard let read = FileTreeModel.io(for: path, outsideLink: false, root: root, source: source)?.readData else {
                                   throw FileListingError.outsideSpace(path)
                               }
                               return try await read()
                           }
                       },
                       onOpenFile: { path, fragment in openLinkedFile(path, fragment: fragment) },
                       onFocus: { store.focusOwner = .editor })
            .id(editor.id)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// A link in a Markdown preview to a file of the space: it opens in a
    /// preview tab, and a Markdown file opens in Preview at its heading.
    private func openLinkedFile(_ path: String, fragment: String?) {
        guard let space = store.selectedSpace, let root = files.canonicalRoot ?? store.currentRoot,
              let io = files.io(for: path) ?? FileTreeModel.io(for: path, outsideLink: false, root: root,
                                                               source: store.isRemote ? .remote(store.remoteShell) : .local) else { return }
        editors.open(path, in: space, preview: true, io: io)
        if FileKind.of((path as NSString).lastPathComponent) == .markdown { editors.setPreview(path, in: space, true, fragment: fragment) }
    }

    /// The tab strip while the device is down: the editor tabs, and a
    /// "Terminals" entry that shows the connection state.
    private func offlineEditorStrip(_ space: String) -> some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    Button { editors.showTerminals(in: space) } label: {
                        HStack(spacing: 6) {
                            Circle().fill(Color.orange).frame(width: 6, height: 6)
                            Text("Terminals").lineLimit(1)
                        }
                        .font(.system(size: 11, weight: activeEditor == nil ? .semibold : .regular))
                        .padding(.horizontal, 10).frame(height: 26)
                        .contentShape(Rectangle())
                        .background(activeEditor == nil ? Color.primary.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(.plain)
                    .help("Terminals come back when the device reconnects")
                    editorTabs(space)
                }.padding(.horizontal, 6).padding(.vertical, 3)
            }
            Text(store.connecting ? "Connecting…" : "Disconnected")
                .font(.system(size: 11)).foregroundStyle(.tertiary).padding(.horizontal, 14)
        }.frame(height: 32)
    }

    private func editorTabs(_ space: String) -> some View {
        ForEach(editors.tabs(in: space)) { tab in
            let selected = activeEditor?.id == tab.id
            HStack(spacing: 6) {
                Button { VisibleTabNavigation.select(.editor(tab.id), session: store, editors: editors) } label: {
                    HStack(spacing: 6) {
                        if let image = FileIcon.image(named: FileIconName.name(for: tab.name, isDirectory: false)) {
                            Image(nsImage: image).resizable().frame(width: 12, height: 12)
                        }
                        Text(tab.name).lineLimit(1).italic(tab.isPreview)
                        if let kind = tab.kindLabel { Text(kind).foregroundStyle(.secondary) }
                        if let index = VisibleTabNavigation.entries(session: store, editors: editors).firstIndex(where: { $0.id == .editor(tab.id) }),
                           let key = AppHotkeys.tabSelectionKey(at: index), let chord = shortcuts.bindings.chord(for: .selectTab) {
                            Text(KeyChord.modifierGlyphs(chord.modifiers) + String(key)).font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(Color.accentColor).opacity(shortcutHints.isHeld ? 1 : 0)
                                .accessibilityHidden(!shortcutHints.isHeld)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // A double-click keeps a preview tab open.
                .simultaneousGesture(TapGesture(count: 2).onEnded { editors.keep(tab.id, in: space) })
                .accessibilityLabel([tab.name, tab.kindLabel?.lowercased(), tab.isPreview ? "preview" : nil].compactMap { $0 }.joined(separator: ", "))
                .accessibilityAddTraits(selected ? .isSelected : [])
                Button { requestClose(tab.id, in: space) } label: {
                    // An edited tab shows a dot where its close button is.
                    if tab.isDirty {
                        Circle().fill(Color.primary.opacity(0.7)).frame(width: 7, height: 7).frame(width: 14, height: 14)
                    } else {
                        Image(systemName: "xmark").font(.system(size: 8, weight: .semibold)).frame(width: 14, height: 14)
                    }
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help(tab.isDirty ? "\(tab.name) has unsaved edits. Close…" : "Close \(tab.name)")
                .accessibilityLabel(tab.isDirty ? "Close \(tab.name), unsaved edits" : "Close \(tab.name)")
            }
            .font(.system(size: 11, weight: selected ? .semibold : .regular))
            .padding(.horizontal, 10).frame(height: 26)
            .background(selected ? Color.primary.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
            .overlay(alignment: .bottom) { if selected { Capsule().fill(herdrAccentColor).frame(height: 2).padding(.horizontal, 12) } }
            .help(tab.filePath)
            .contextMenu {
                if tab.isPreview { Button("Keep Open") { editors.keep(tab.id, in: space) } }
                Button("Copy Path") { FileOutlineView.Coordinator.copy(tab.filePath) }
                Button("Close") { requestClose(tab.id, in: space) }
            }
        }
    }

    private func compactToolbarButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    private var tabStrip: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(store.visibleTabs.enumerated()), id: \.element.id) { index, tab in
                        Button { VisibleTabNavigation.select(.terminal(tab.id), session: store, editors: editors) } label: {
                            HStack(spacing: 6) {
                                let agents = store.panes.filter { $0.tabID == tab.id }.compactMap(\.agent)
                                if agents.isEmpty {
                                    Image(systemName: "terminal").font(.system(size: 10))
                                } else {
                                    AgentIconStack(agents: agents, background: Color(nsColor: .windowBackgroundColor))
                                }
                                Text(tab.label).lineLimit(1)
                                if let key = AppHotkeys.tabSelectionKey(at: index), let chord = shortcuts.bindings.chord(for: .selectTab) {
                                    Text(KeyChord.modifierGlyphs(chord.modifiers) + String(key)).font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(Color.accentColor).opacity(shortcutHints.isHeld ? 1 : 0)
                                        .accessibilityHidden(!shortcutHints.isHeld)
                                }
                                if tab.agentStatus != .unknown && tab.agentStatus != .idle { StatusDot(status: tab.agentStatus) }
                                Text("\(tab.paneCount)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                            }
                            .font(.system(size: 11, weight: shownTerminalTab == tab.id ? .semibold : .regular))
                            .padding(.horizontal, 10).frame(height: 26)
                            .contentShape(Rectangle())
                            .background(shownTerminalTab == tab.id ? Color.primary.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                            .overlay(alignment: .bottom) { if shownTerminalTab == tab.id { Capsule().fill(herdrAccentColor).frame(height: 2).padding(.horizontal, 12) } }
                        }
                        .buttonStyle(.plain)
                        .modifier(TabStripDragTarget(tabID: tab.id, store: store))
                        .contextMenu {
                            Button("Rename tab…") { store.sheet = .rename(ResourceTarget(kind: "tab", id: tab.id, label: tab.label)) }
                            Button("Close tab…", role: .destructive) { store.pendingClose = ResourceTarget(kind: "tab", id: tab.id, label: tab.label) }
                        }
                    }
                    if let space = store.selectedSpace { editorTabs(space) }
                    Button { store.sheet = .tab } label: { Image(systemName: "plus").font(.system(size: 11)).frame(width: 26, height: 26) }
                        .buttonStyle(.plain).help("New tab (⌘T)").disabled(store.busy)
                }.padding(.horizontal, 6).padding(.vertical, 3)
            }
            Text("\(store.visiblePanes.count) \(store.visiblePanes.count == 1 ? "pane" : "panes")")
                .font(.system(size: 11)).foregroundStyle(.tertiary).padding(.horizontal, 14)
        }.frame(height: 32)
        .modifier(PaneDragLifecycle())
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            Circle().fill(store.connected ? herdrAccentColor : Color.orange).frame(width: 6, height: 6)
            Text(store.displayName)
            Text(store.connected ? "Connected to herdr \(store.version)" : store.connecting ? "Connecting…" : "Disconnected")
            herdrUpdateBadge
            Spacer()
            if store.connected {
                Text("\(store.agents.count) agents")
                Text("·")
                Text("\(store.workspaces.count) spaces")
            }
            Button { store.sheet = .settings } label: { Image(systemName: "slider.horizontal.3") }
                .buttonStyle(.plain).help("Connection and appearance settings")
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14).padding(.vertical, 7)
    }

    /// A new herdr release to install, or a server still running the old one.
    @ViewBuilder private var herdrUpdateBadge: some View {
        let restartVersion = devices.herdrRestartVersion(for: store)
        if devices.isUpdatingHerdr(store) || (restartVersion != nil && devices.isActing(store)) {
            ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 12, height: 12)
                .help(devices.isUpdatingHerdr(store) ? "Updating herdr…" : "Working…")
        } else if let version = devices.availableHerdrUpdate(for: store) {
            Button { devices.herdrPrompt = .update(store.profile.id, version: version) } label: {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(herdrAccentColor)
            }
            .buttonStyle(.plain).help("herdr \(version) is available\(store.isRemote ? " on \(store.profile.name)" : ""). Click to update.")
            .accessibilityLabel(store.isRemote ? "Update herdr on \(store.profile.name) to \(version)" : "Update herdr to \(version)")
        } else if let version = restartVersion {
            Button { devices.herdrPrompt = .restart(store.profile.id, version: version, afterUpdate: false) } label: {
                Image(systemName: "arrow.clockwise.circle.fill").foregroundStyle(Color.orange)
            }
            .buttonStyle(.plain).help("Restart the server to use herdr \(version).")
            .accessibilityLabel("Restart server to use herdr \(version)")
        }
    }

    private var emptySpaces: some View {
        VStack(spacing: 18) {
            Image(systemName: "square.stack.3d.up").font(.system(size: 42, weight: .ultraLight)).foregroundStyle(herdrAccentColor)
            Text("Room for your next idea").font(.system(size: 24, weight: .medium))
            Text("Create a space for a project, then add terminals and agents.").foregroundStyle(.secondary)
            Button("Create a space…") { store.sheet = .space }.buttonStyle(.borderedProminent)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var connectionView: some View {
        VStack(spacing: 18) {
            Image(systemName: "square.split.2x2").font(.system(size: 50, weight: .ultraLight)).foregroundStyle(herdrAccentColor)
            Text(store.displayName).font(.system(size: 26, weight: .medium))
            Text(store.isRemote ? "Connect over SSH to see this device’s workspaces." : "Connect to herdr on this Mac to see your workspaces.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let error = store.connectionError {
                Text(error).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    .textSelection(.enabled).multilineTextAlignment(.center).frame(maxWidth: 460)
                    .padding(12).background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
            }
            HStack {
                Button("Edit device…") { devices.editor = DeviceEditorTarget(profile: store.profile, sessionOnly: true) }
                Button(store.connecting ? "Connecting…" : "Connect") { store.reconnect() }.disabled(store.connecting)
                if !store.isRemote {
                    Button("Start server") { Task { await devices.startServer(for: store) } }.buttonStyle(.borderedProminent)
                }
            }
            Text("Your sessions keep running when you close this app.").font(.caption).foregroundStyle(.tertiary)
        }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}


/// The herdr update and restart questions; split out so the workspace body type-checks quickly.
struct HerdrPromptAlert: ViewModifier {
    @ObservedObject var devices: DeviceStore

    func body(content: Content) -> some View {
        content
            .alert(title, isPresented: Binding(get: { devices.herdrPrompt != nil }, set: { if !$0 { devices.herdrPrompt = nil } }), presenting: devices.herdrPrompt) { prompt in
                switch prompt {
                case .update:
                    Button("Not Now", role: .cancel) { devices.herdrPrompt = nil }
                    Button("Update") { runHerdrPrompt(prompt) }.keyboardShortcut(.defaultAction)
                case .restart(_, _, let afterUpdate):
                    Button(afterUpdate ? "Later" : "Cancel", role: .cancel) { devices.herdrPrompt = nil }
                    Button("Restart Server") { runHerdrPrompt(prompt) }.keyboardShortcut(.defaultAction)
                case .fullRestart:
                    Button("Cancel", role: .cancel) { devices.herdrPrompt = nil }
                    Button("Restart Anyway", role: .destructive) { runHerdrPrompt(prompt) }
                }
            } message: { prompt in
                switch prompt {
                case .update(_, let version):
                    Text("Installs herdr \(version) with “herdr update”. Running servers keep their current version until they restart.")
                case .restart(_, let version, let afterUpdate):
                    Text("\(afterUpdate ? "herdr \(version) is installed. " : "")The server restarts on herdr \(version) and hands over this session’s shells and agents, so they keep running.")
                case .fullRestart(_, let version, let reason):
                    Text("\(reason)\n\nA full restart ends this session’s shells and agents, and it reopens from its saved state on herdr \(version).")
                }
            }
    }

    private var title: String {
        guard let prompt = devices.herdrPrompt,
              let session = devices.sessions.first(where: { $0.profile.id == prompt.deviceID }) else { return "" }
        switch prompt {
        case .update(_, let version): return session.isRemote ? "Update herdr on “\(session.profile.name)” to \(version)?" : "Update herdr to \(version)?"
        case .restart(_, _, true): return "Restart “\(session.profile.sessionName)” now?"
        case .restart: return "Restart “\(session.profile.sessionName)”?"
        case .fullRestart: return "Restart “\(session.profile.sessionName)” without handoff?"
        }
    }

    private func runHerdrPrompt(_ prompt: HerdrPrompt) {
        devices.herdrPrompt = nil
        guard let session = devices.sessions.first(where: { $0.profile.id == prompt.deviceID }) else { return }
        Task {
            switch prompt {
            case .update: await devices.updateHerdr(for: session)
            case .restart: await devices.upgradeHerdrServer(session)
            case .fullRestart: await devices.restartHerdrSession(session)
            }
        }
    }
}

struct StatusDot: View {
    let status: AgentStatus
    var body: some View { Circle().fill(status.color).frame(width: 6, height: 6).accessibilityLabel(status.label) }
}
struct StatusBadge: View {
    let status: AgentStatus
    var body: some View {
        HStack(spacing: 5) { StatusDot(status: status); Text(status.label) }
            .font(.system(size: 10, weight: .medium)).foregroundStyle(status.color)
    }
}
extension AgentStatus {
    var color: Color {
        switch self { case .working: return .cyan; case .blocked: return .orange; case .done: return herdrAccentColor; case .idle: return .secondary; case .unknown: return .secondary }
    }
}

struct WindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.setFrameAutosaveName("HerdrMainWindow")
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
