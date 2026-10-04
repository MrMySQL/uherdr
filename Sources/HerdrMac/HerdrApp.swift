import SwiftUI
import AppKit
import HerdrCore

@main
struct HerdrApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var devices = DeviceStore()
    @State private var attention = AttentionNotifier()
    @ObservedObject private var shortcuts = ShortcutSettings.shared
    private var store: SessionStore { devices.activeSession }
    var body: some Scene {
        Window("uHerdr", id: "main") {
            WorkspaceView(store: store, devices: devices)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in devices.stop() }
                .task { attention.attach(devices) }
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
                    if let tab = store.currentTab { store.pendingClose = ResourceTarget(kind: "tab", id: tab.id, label: tab.label) }
                }.keyboardShortcut(shortcut(.closeTab)).disabled(!canUseCurrentTab)
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
            }
            CommandMenu("Pane") {
                Button("Find in Pane…") { store.searchPane() }
                    .keyboardShortcut(shortcut(.findInPane)).disabled(!canUseCurrentPane)
                Divider()
                Button("Split Side by Side") { store.split(.right) }.keyboardShortcut(shortcut(.splitSideBySide)).disabled(!canUseCurrentPane)
                Button("Split Top and Bottom") { store.split(.down) }.keyboardShortcut(shortcut(.splitTopAndBottom)).disabled(!canUseCurrentPane)
                Divider()
                Button("Zoom Pane") { if let id = store.selectedPane { store.zoom(id) } }
                    .keyboardShortcut(shortcut(.zoomPane))
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
