import SwiftUI
import AppKit

@main
struct HerdrApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var store = SessionStore()
    var body: some Scene {
        Window("Herdr", id: "main") {
            WorkspaceView(store: store)
        }
        .defaultSize(width: 1280, height: 820)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Space…") { store.sheet = .space }.keyboardShortcut("n").disabled(!store.connected)
                Button("New Tab…") { store.sheet = .tab }.keyboardShortcut("t").disabled(store.selectedSpace == nil || !store.connected)
            }
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { store.sheet = .settings }.keyboardShortcut(",")
            }
            CommandMenu("Pane") {
                Button("Split Side by Side") { store.split(.right) }.keyboardShortcut("d").disabled(store.selectedPane == nil || !store.connected)
                Button("Split Top and Bottom") { store.split(.down) }.keyboardShortcut("d", modifiers: [.command, .shift]).disabled(store.selectedPane == nil || !store.connected)
                Divider()
                Button("Zoom Pane") { if let id = store.selectedPane { store.zoom(id) } }.keyboardShortcut("z", modifiers: [.command, .shift]).disabled(store.selectedPane == nil)
                Button("Start Agent…") { if let id = store.selectedPane { store.sheet = .agent(id) } }.disabled(store.selectedPane == nil)
                Divider()
                Button("Close Pane…") {
                    if let pane = store.currentPane { store.pendingClose = ResourceTarget(kind: "pane", id: pane.id, label: pane.displayTitle) }
                }.keyboardShortcut("w", modifiers: [.command, .shift]).disabled(store.selectedPane == nil)
            }
            CommandMenu("Navigate") {
                ForEach(Array(store.workspaces.prefix(9).enumerated()), id: \.element.id) { index, space in
                    Button("Switch to \(space.label)") {
                        store.sidebarMode = "spaces"
                        store.selectSpace(space)
                    }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                    .disabled(!store.connected || store.sheet != nil || store.pendingClose != nil)
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
                Button("Next Pane") { movePane() }.keyboardShortcut("`", modifiers: [.control])
                Button("Show Agents") { store.sidebarMode = "agents" }.keyboardShortcut("a", modifiers: [.command, .shift])
                Button("Show Spaces") { store.sidebarMode = "spaces" }.keyboardShortcut("s", modifiers: [.command, .shift])
            }
        }
    }
    private var canNavigateTabs: Bool {
        store.connected && !store.visibleTabs.isEmpty && store.sheet == nil && store.pendingClose == nil && store.operationError == nil
    }
    private func moveTab(_ offset: Int) {
        let tabs = store.visibleTabs
        guard !tabs.isEmpty else { return }
        let index = tabs.firstIndex { $0.id == store.selectedTab } ?? 0
        store.selectTab(tabs[(index + offset + tabs.count) % tabs.count])
    }
    private func movePane() {
        let panes = store.visiblePanes
        guard !panes.isEmpty else { return }
        let index = panes.firstIndex { $0.id == store.selectedPane } ?? 0
        store.focusPane(panes[(index + 1) % panes.count].id)
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
