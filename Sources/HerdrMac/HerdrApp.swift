import SwiftUI
import AppKit

@main
struct HerdrApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var devices = DeviceStore()
    private var store: SessionStore { devices.activeSession }
    var body: some Scene {
        Window("Herdr", id: "main") {
            WorkspaceView(store: store, devices: devices)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in devices.stop() }
        }
        .defaultSize(width: 1280, height: 820)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Space…") { store.sheet = .space }.keyboardShortcut("n").disabled(!store.connected || !canInteract)
                Button("New Tab…") { store.sheet = .tab }.keyboardShortcut("t").disabled(store.selectedSpace == nil || !store.connected || !canInteract)
            }
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { store.sheet = .settings }.keyboardShortcut(",").disabled(!canInteract)
            }
            CommandGroup(after: .toolbar) {
                Button("Increase Text Size") { store.fontSize = min(22, store.fontSize + 1) }
                    .keyboardShortcut("+", modifiers: .command)
                    .disabled(!canInteract || store.fontSize >= 22)
                Button("Increase Text Size") { store.fontSize = min(22, store.fontSize + 1) }
                    .keyboardShortcut("=", modifiers: .command)
                    .disabled(!canInteract || store.fontSize >= 22)
                    .hidden()
                Button("Decrease Text Size") { store.fontSize = max(10, store.fontSize - 1) }
                    .keyboardShortcut("-", modifiers: .command)
                    .disabled(!canInteract || store.fontSize <= 10)
            }
            CommandMenu("Pane") {
                Button("Split Side by Side") { store.split(.right) }.keyboardShortcut("d").disabled(!canUseCurrentPane)
                Button("Split Top and Bottom") { store.split(.down) }.keyboardShortcut("d", modifiers: [.command, .shift]).disabled(!canUseCurrentPane)
                Divider()
                Button("Zoom Pane") { if let id = store.selectedPane { store.zoom(id) } }
                    .keyboardShortcut(KeyEquivalent(AppHotkeys.togglePaneZoom.key), modifiers: AppHotkeys.togglePaneZoom.eventModifiers)
                    .disabled(!canUseCurrentPane)
                Button("Start Agent…") { if let id = store.selectedPane { store.sheet = .agent(id) } }.disabled(!canUseCurrentPane)
                Divider()
                Button("Close Pane…") {
                    if let pane = store.currentPane { store.pendingClose = ResourceTarget(kind: "pane", id: pane.id, label: pane.displayTitle) }
                }.keyboardShortcut("w", modifiers: [.command, .shift]).disabled(!canUseCurrentPane)
            }
            CommandMenu("Space") {
                Button("Rename Current Space…") {
                    if let space = store.currentSpace { store.sheet = .rename(ResourceTarget(kind: "workspace", id: space.id, label: space.label)) }
                }.keyboardShortcut(KeyEquivalent(AppHotkeys.renameCurrentWorkspace.key), modifiers: AppHotkeys.renameCurrentWorkspace.eventModifiers)
                    .disabled(!canUseCurrentSpace)
            }
            CommandMenu("Tab") {
                Button("Rename Current Tab…") {
                    if let tab = store.currentTab { store.sheet = .rename(ResourceTarget(kind: "tab", id: tab.id, label: tab.label)) }
                }.keyboardShortcut(KeyEquivalent(AppHotkeys.renameCurrentTab.key), modifiers: AppHotkeys.renameCurrentTab.eventModifiers)
                    .disabled(!canUseCurrentTab)
            }
            CommandMenu("Navigate") {
                ForEach(Array(devices.workspaceShortcuts.enumerated()), id: \.offset) { index, entry in
                    Button("\(entry.session.profile.name): \(entry.workspace.label)") {
                        devices.sidebarMode = "spaces"
                        devices.select(entry.session, workspace: entry.workspace)
                    }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                    .disabled(!entry.session.connected || !canInteract)
                }
                Divider()
                ForEach(Array(store.visibleTabs.prefix(9).enumerated()), id: \.element.id) { index, tab in
                    Button("Switch to Tab \(index + 1): \(tab.label)") { store.selectTab(tab) }
                        .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .control)
                        .disabled(!canNavigateTabs)
                }
                Divider()
                Button("Next Tab") { moveTab(1) }
                    .keyboardShortcut(.tab, modifiers: .control)
                    .disabled(!canNavigateTabs)
                Button("Previous Tab") { moveTab(-1) }
                    .keyboardShortcut(.tab, modifiers: [.control, .shift])
                    .disabled(!canNavigateTabs)
                Button("Next Tab") { moveTab(1) }.keyboardShortcut("]", modifiers: [.command, .shift])
                    .disabled(!canNavigateTabs)
                Button("Previous Tab") { moveTab(-1) }.keyboardShortcut("[", modifiers: [.command, .shift])
                    .disabled(!canNavigateTabs)
                Divider()
                Button("Next Pane") { movePane(1) }.keyboardShortcut("]", modifiers: .command).disabled(!canUseCurrentPane)
                Button("Previous Pane") { movePane(-1) }.keyboardShortcut("[", modifiers: .command).disabled(!canUseCurrentPane)
                Button("Next Pane") { movePane(1) }.keyboardShortcut("`", modifiers: [.control]).disabled(!canUseCurrentPane)
                Button("Show Agents") { devices.sidebarMode = "agents" }.keyboardShortcut("a", modifiers: [.command, .shift])
                Button("Show Spaces") { devices.sidebarMode = "spaces" }.keyboardShortcut("s", modifiers: [.command, .shift])
            }
        }
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

private extension AppHotkey {
    var eventModifiers: EventModifiers {
        var result: EventModifiers = []
        if modifiers.contains(.command) { result.insert(.command) }
        if modifiers.contains(.shift) { result.insert(.shift) }
        return result
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
