import SwiftUI
import AppKit
import HerdrCore

@main
struct HerdrApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var devices = DeviceStore()
    @StateObject private var editors = EditorStores(drafts: DraftStore(directory: HerdrApp.draftsDirectory), defaults: .standard)
    @State private var attention = AttentionNotifier()
    @ObservedObject private var shortcuts = ShortcutSettings.shared
    @ObservedObject private var palette = PaletteState.shared
    private var store: SessionStore { devices.activeSession }
    var body: some Scene {
        Window("uHerdr", id: "main") {
            WorkspaceView(store: store, devices: devices, editors: editors.store(for: store.profile.id))
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in devices.stop(); SSHMasters.shared.stopAll() }
                .task {
                    attention.attach(devices)
                    editors.spaceInfo = { [devices] profile, space in
                        guard let session = devices.sessions.first(where: { $0.profile.id == profile }),
                              let root = session.workspaceRoots.root(for: space) else { return nil }
                        return (session.workspaces.first { $0.id == space }?.label ?? "", root)
                    }
                    devices.onRemove = { [editors] id in editors.forget(profile: id) }
                    appDelegate.editors = editors
                    SessionStore.remoteDisconnected = { SSHMasters.shared.stop($0) }
                }
        }
        .defaultSize(width: 1280, height: 820)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Space…") { store.sheet = .space }.keyboardShortcut(shortcut(.newSpace)).disabled(!store.connected || !canInteract)
                Button("New Tab…") { store.sheet = .tab }.keyboardShortcut(shortcut(.newTab)).disabled(store.selectedSpace == nil || !store.connected || !canInteract)
            }
            // ⌘W closes the current tab (after confirming), not the window.
            CommandGroup(replacing: .saveItem) {
                Button("Close Tab…") {
                    let editorStore = editors.store(for: store.profile.id)
                    if let space = store.selectedSpace, let editor = editorStore.activeTab(in: space) {
                        // An editor tab asks only when it has unsaved edits.
                        editorStore.requestClose(editor.id, in: space)
                    } else if let tab = store.currentTab {
                        store.pendingClose = ResourceTarget(kind: "tab", id: tab.id, label: tab.label)
                    }
                }.keyboardShortcut(shortcut(.closeTab)).disabled(!canUseCurrentTab && !showsEditor)
            }
            CommandGroup(after: .newItem) {
                Divider()
                Button("Quick Open…") { NotificationCenter.default.post(name: .uherdrQuickOpen, object: nil) }
                    .keyboardShortcut(shortcut(.quickOpen)).disabled(!canInteract || store.currentRoot == nil)
                Button("Search in Space…") { NotificationCenter.default.post(name: .uherdrSearchInSpace, object: nil) }
                    .keyboardShortcut(shortcut(.searchInSpace)).disabled(!canInteract || store.currentRoot == nil)
            }
            CommandGroup(after: .saveItem) {
                Button("Save File") {
                    let editorStore = editors.store(for: store.profile.id)
                    if let space = store.selectedSpace, let editor = editorStore.activeTab(in: space) {
                        Task { await editorStore.save(editor.id, in: space) }
                    }
                }.keyboardShortcut(shortcut(.saveFile)).disabled(!canSaveEditor)
                Button("Toggle Markdown Preview") {
                    let editorStore = editors.store(for: store.profile.id)
                    if let space = store.selectedSpace, let editor = editorStore.activeTab(in: space) {
                        editorStore.setPreview(editor.id, in: space, !editor.showsPreview)
                    }
                }.keyboardShortcut(shortcut(.markdownPreview))
                    .disabled(!canInteract || store.selectedSpace.map { editors.menuState[store.profile.id]?.markdown.contains($0) == true } != true)
            }
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { store.sheet = .settings }.keyboardShortcut(shortcut(.settings)).disabled(!canInteract)
                Button("Keyboard Shortcuts…") { store.sheet = .shortcuts }.keyboardShortcut(shortcut(.keyboardShortcuts)).disabled(!canInteract)
            }
            CommandGroup(after: .help) {
                Button("Keyboard Shortcuts") { store.sheet = .shortcuts }.disabled(!canInteract)
            }
            CommandGroup(after: .toolbar) {
                Button("Increase Text Size") { store.fontSize = min(22, store.fontSize + 1) }
                    .keyboardShortcut(shortcut(.largerText))
                    .disabled(!canInteract || store.fontSize >= 22)
                Button("Increase Text Size") { store.fontSize = min(22, store.fontSize + 1) }
                    .keyboardShortcut(shortcut(.largerTextAlternate))
                    .disabled(!canInteract || store.fontSize >= 22)
                Button("Decrease Text Size") { store.fontSize = max(10, store.fontSize - 1) }
                    .keyboardShortcut(shortcut(.smallerText))
                    .disabled(!canInteract || store.fontSize <= 10)
                Divider()
                Button("Show or Hide Right Sidebar") { NotificationCenter.default.post(name: .uherdrSidebar, object: "toggle") }
                    .keyboardShortcut(shortcut(.toggleRightSidebar)).disabled(!canInteract)
                Button("Files") { NotificationCenter.default.post(name: .uherdrSidebar, object: "files") }
                    .keyboardShortcut(shortcut(.showFiles)).disabled(!canInteract)
                Button("Changes") { NotificationCenter.default.post(name: .uherdrSidebar, object: "changes") }
                    .keyboardShortcut(shortcut(.showChanges)).disabled(!canInteract)
            }
            CommandMenu("Pane") {
                if showsEditor {
                    Button("Find in File…") {
                        store.focusOwner = .editor
                        FocusReportingTextView.showFindBar(in: NSApp.keyWindow ?? NSApp.mainWindow)
                    }.keyboardShortcut(shortcut(.findInPane)).disabled(!canInteract)
                    Button("Find and Replace…") {
                        store.focusOwner = .editor
                        FocusReportingTextView.showFindBar(in: NSApp.keyWindow ?? NSApp.mainWindow, replace: true)
                    }.keyboardShortcut(shortcut(.findAndReplace)).disabled(!canSaveOrEditText)
                    Button("Go to Line…") { NotificationCenter.default.post(name: .uherdrGoToLine, object: nil) }
                        .keyboardShortcut(shortcut(.goToLine)).disabled(!canInteract)
                } else {
                    Button("Find in Pane…") { store.searchPane() }
                        .keyboardShortcut(shortcut(.findInPane)).disabled(!canUseCurrentPane)
                }
                Divider()
                Button("Split Side by Side") { store.split(.right) }.keyboardShortcut(shortcut(.splitSideBySide)).disabled(!canUseCurrentPane)
                Button("Split Top and Bottom") { store.split(.down) }.keyboardShortcut(shortcut(.splitTopAndBottom)).disabled(!canUseCurrentPane)
                Divider()
                Button("Zoom Pane") { if let id = store.selectedPane { store.zoom(id) } }
                    .keyboardShortcut(shortcut(.zoomPane)).disabled(palette.quickOpenShown)
                    .disabled(!canUseCurrentPane)
                Button("Start Agent…") { if let id = store.selectedPane { store.sheet = .agent(id) } }.disabled(!canUseCurrentPane)
                Divider()
                Button("Close Pane…") {
                    if let pane = store.currentPane { store.pendingClose = ResourceTarget(kind: "pane", id: pane.id, label: pane.displayTitle) }
                }.keyboardShortcut(shortcut(.closePane)).disabled(!canUseCurrentPane)
            }
            CommandMenu("Space") {
                Button("Rename Current Space…") {
                    if let space = store.currentSpace { store.sheet = .rename(ResourceTarget(kind: "workspace", id: space.id, label: space.label)) }
                }.keyboardShortcut(shortcut(.renameSpace))
                    .disabled(!canUseCurrentSpace)
            }
            CommandMenu("Tab") {
                Button("Rename Current Tab…") {
                    if let tab = store.currentTab { store.sheet = .rename(ResourceTarget(kind: "tab", id: tab.id, label: tab.label)) }
                }.keyboardShortcut(shortcut(.renameTab))
                    .disabled(!canUseCurrentTab)
            }
            CommandMenu("Navigate") {
                ForEach(Array(devices.workspaceShortcuts.enumerated()), id: \.offset) { index, entry in
                    Button("\(entry.session.displayName): \(entry.workspace.label)") {
                        devices.sidebarMode = "spaces"
                        devices.select(entry.session, workspace: entry.workspace)
                    }
                    .keyboardShortcut(rangeShortcut(.selectSpace, digit: Character(String(index + 1))))
                    .disabled(!entry.session.connected || !canInteract)
                }
                Divider()
                ForEach(Array(store.visibleTabs.prefix(10).enumerated()), id: \.element.id) { index, tab in
                    if let key = AppHotkeys.tabSelectionKey(at: index) {
                        Button("Switch to Tab \(index + 1): \(tab.label)") { store.selectTab(tab) }
                            .keyboardShortcut(rangeShortcut(.selectTab, digit: key))
                            .disabled(!canNavigateTabs)
                    }
                }
                Divider()
                Button("Next Tab") { moveTab(1) }
                    .keyboardShortcut(shortcut(.nextTab))
                    .disabled(!canNavigateTabs)
                Button("Previous Tab") { moveTab(-1) }
                    .keyboardShortcut(shortcut(.previousTab))
                    .disabled(!canNavigateTabs)
                Button("Next Tab") { moveTab(1) }.keyboardShortcut(shortcut(.nextTabAlternate))
                    .disabled(!canNavigateTabs)
                Button("Previous Tab") { moveTab(-1) }.keyboardShortcut(shortcut(.previousTabAlternate))
                    .disabled(!canNavigateTabs)
                Divider()
                Button("Next Pane") { movePane(1) }.keyboardShortcut(shortcut(.nextPane)).disabled(!canUseCurrentPane)
                Button("Previous Pane") { movePane(-1) }.keyboardShortcut(shortcut(.previousPane)).disabled(!canUseCurrentPane)
                Button("Next Pane") { movePane(1) }.keyboardShortcut(shortcut(.nextPaneAlternate)).disabled(!canUseCurrentPane)
                Button("Show Agents") { devices.sidebarMode = "agents" }.keyboardShortcut(shortcut(.showAgents))
                Button("Show Spaces") { devices.sidebarMode = "spaces" }.keyboardShortcut(shortcut(.showSpaces))
            }
        }
    }
    private func shortcut(_ action: ShortcutAction) -> KeyboardShortcut? { shortcuts.bindings.chord(for: action)?.keyboardShortcut }
    private func rangeShortcut(_ action: ShortcutAction, digit: Character) -> KeyboardShortcut? {
        shortcuts.bindings.chord(for: action)?.keyboardShortcut(digit: digit)
    }
    private var canInteract: Bool {
        store.sheet == nil && store.pendingClose == nil && store.operationError == nil && devices.editor == nil && devices.pendingRemoval == nil
    }
    private var canUseCurrentPane: Bool {
        store.connected && store.selectedPane != nil && canInteract
    }
    /// ⌘S works when the shown editor has edits and its device is reachable.
    private var canSaveEditor: Bool {
        guard canInteract, let space = store.selectedSpace else { return false }
        return editors.menuState[store.profile.id]?.savable.contains(space) == true && (store.connected || !store.isRemote)
    }
    /// Find and Replace needs a shown text file that can be edited.
    private var canSaveOrEditText: Bool {
        guard canInteract, let space = store.selectedSpace,
              let tab = editors.store(for: store.profile.id).activeTab(in: space) else { return false }
        return tab.canEdit && !tab.showsPreview
    }
    /// The shipped app keeps drafts in the shared folder; any other build (UI
    /// checks, `swift run`) keeps its own, so test edits never mix with real ones.
    static var draftsDirectory: URL {
        let id = Bundle.main.bundleIdentifier
        return id == "dev.herdr.native" ? DraftStore.defaultDirectory
            : DraftStore.defaultDirectory.deletingLastPathComponent().appendingPathComponent("Drafts-\(id ?? "unbundled")", isDirectory: true)
    }
    private var showsEditor: Bool {
        canInteract && store.selectedSpace.map { editors.menuState[store.profile.id]?.shown.contains($0) == true } == true
    }
    private var canUseCurrentTab: Bool {
        store.connected && store.currentTab != nil && canInteract
    }
    private var canUseCurrentSpace: Bool {
        store.connected && store.currentSpace != nil && canInteract
    }
    private var canNavigateTabs: Bool {
        store.connected && !store.visibleTabs.isEmpty && canInteract
    }
    private func moveTab(_ offset: Int) {
        let tabs = store.visibleTabs
        guard !tabs.isEmpty else { return }
        let index = tabs.firstIndex { $0.id == store.selectedTab } ?? 0
        store.selectTab(tabs[(index + offset + tabs.count) % tabs.count])
    }
    private func movePane(_ offset: Int) {
        let panes = store.visiblePanes
        guard !panes.isEmpty else { return }
        let index = panes.firstIndex { $0.id == store.selectedPane } ?? 0
        store.focusPane(panes[(index + offset + panes.count) % panes.count].id)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var editors: EditorStores?

    /// Quitting with unsaved editor text asks first: Save All, Don't Save, or Cancel.
    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let editors else { return .terminateNow }
        let stores = editors.all.filter { !$0.dirtyTabs.isEmpty }
        let count = stores.reduce(0) { $0 + $1.dirtyTabs.count }
        guard count > 0 else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = count == 1 ? "Save changes to 1 file before quitting?" : "Save changes to \(count) files before quitting?"
        alert.informativeText = "If you don't save, your edits are lost."
        alert.addButton(withTitle: "Save All")
        alert.addButton(withTitle: "Don't Save").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            Task { @MainActor in
                var saved = true
                for store in stores where !(await store.saveAll()) { saved = false }
                sender.reply(toApplicationShouldTerminate: saved)
            }
            return .terminateLater
        case .alertSecondButtonReturn:
            for store in stores { store.discardUnsaved() }
            return .terminateNow
        default:
            return .terminateCancel
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        signal(SIGPIPE, SIG_IGN)
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { sender.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil) }
        return true
    }
}
