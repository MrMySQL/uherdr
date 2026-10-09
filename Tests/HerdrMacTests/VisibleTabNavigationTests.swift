import Foundation
import Combine
import HerdrCore

private actor NavigationClient: HerdrRequesting {
    func request(_ method: String, params: [String: JSONValue], timeout: Int) async throws -> JSONValue { .object([:]) }
}

@main struct VisibleTabNavigationTests {
    @MainActor static func main() async throws {
        let suite = "dev.herdr.navigation-tests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let profile = DeviceProfile(name: "Navigation fixture", kind: .local,
                                    socketPath: "/tmp/unused-navigation.sock", executable: "/tmp/unused-herdr")
        defaults.set(["w": ["b", "a"]], forKey: "tabOrder:\(profile.id.uuidString)")
        let session = SessionStore(profile: profile, defaults: defaults, client: NavigationClient())
        session.tabs = try JSONDecoder().decode([HerdrCore.Tab].self, from: Data("""
        [{"tab_id":"a","workspace_id":"w","label":"A","pane_count":1,"agent_status":"idle"},
         {"tab_id":"b","workspace_id":"w","label":"B","pane_count":1,"agent_status":"idle"},
         {"tab_id":"other","workspace_id":"other","label":"Other","pane_count":1,"agent_status":"idle"}]
        """.utf8))
        session.connected = true
        session.selectedSpace = "w"
        session.selectedTab = "a"
        let stores = EditorStores()
        let editors = stores.store(for: profile.id)
        editors.open("/p/f.swift", in: "w", preview: false, read: { FileContents.decode(Data("original".utf8)) })
        try await Task.sleep(for: .milliseconds(50))
        editors.edit("/p/f.swift", in: "w", text: "unsaved")
        let spec = EditorStore.DiffSpec(change: GitChange(group: .changes, path: "d.swift", letter: "M"),
                                        path: "/p/d.swift", root: "/p", repository: "/p")
        editors.openDiff(spec, in: "w", preview: false, load: { GitDiff() })
        let diff = EditorStore.diffID(spec)
        let expected: [VisibleTabNavigation.Entry.ID] = [.terminal("b"), .terminal("a"), .editor("/p/f.swift"), .editor(diff)]
        precondition(VisibleTabNavigation.entries(session: session, editors: editors).map(\.id) == expected)
        let savedFile = editors.tab("/p/f.swift", in: "w")!
        precondition(savedFile.isDirty)
        for (index, id) in expected.enumerated() {
            VisibleTabNavigation.select(at: index, session: session, editors: editors)
            check(id, session, editors)
        }
        // S4: revealing an agent must uncover its terminal even if already selected underneath.
        let agent = try JSONDecoder().decode(Agent.self, from: Data(#"{"pane_id":"pane","tab_id":"a","workspace_id":"w","agent":"claude","agent_status":"blocked"}"#.utf8))
        VisibleTabNavigation.select(.editor("/p/f.swift"), session: session, editors: editors)
        session.selectedPane = agent.paneID
        SessionStore.revealTerminals = { id, space in stores.store(for: id).showTerminals(in: space) }
        defer { SessionStore.revealTerminals = nil }
        precondition(!session.isAgentPaneVisible(agent, editorShown: true), "S4: covered pane is not visible")
        session.revealAgent(agent)
        precondition(editors.activeTab(in: "w") == nil && session.focusOwner == .terminal, "S4: reveal uncovers terminal")
        precondition(session.isAgentPaneVisible(agent, editorShown: false))
        session.selectedSpace = "other"
        precondition(!session.isAgentPaneVisible(agent, editorShown: false))
        session.selectedSpace = "w"
        VisibleTabNavigation.select(.editor(diff), session: session, editors: editors)

        // Wrap both ways, then cross the terminal/file boundary in each direction.
        for (offset, id) in [(1, expected[0]), (-1, expected[3]), (-1, expected[2]), (-1, expected[1]),
                             (1, expected[2]), (1, expected[3])] {
            VisibleTabNavigation.move(offset, session: session, editors: editors)
            check(id, session, editors)
        }
        // Escape to the same underlying terminal, not only a different one.
        VisibleTabNavigation.select(.terminal(session.selectedTab!), session: session, editors: editors)
        precondition(editors.activeTab(in: "w") == nil)
        precondition(editors.tab("/p/f.swift", in: "w") == savedFile, "Navigation preserves unsaved text and tab state")
        for index in [-1, 4, 9, 10] {
            VisibleTabNavigation.select(at: index, session: session, editors: editors)
            precondition(editors.activeTab(in: "w") == nil && session.selectedTab == "a", "Out-of-range digits do nothing")
        }
        VisibleTabNavigation.select(.terminal("other"), session: session, editors: editors)
        VisibleTabNavigation.select(.editor("missing"), session: session, editors: editors)
        precondition(session.selectedSpace == "w" && editors.activeTab(in: "w") == nil && session.focusOwner == .terminal)
        for i in 0..<7 {
            editors.open("/p/\(i).swift", in: "w", preview: false, read: { FileContents.decode(Data()) })
        }
        VisibleTabNavigation.select(at: 9, session: session, editors: editors)
        check(.editor("/p/5.swift"), session, editors)
        VisibleTabNavigation.select(at: 10, session: session, editors: editors)
        check(.editor("/p/5.swift"), session, editors)
        // The menu must observe additions/removals even if another editor stays shown.
        precondition(stores.tabIDs[profile.id]?["w"] == editors.tabs(in: "w").map(\.id))
        editors.close("/p/6.swift", in: "w")
        precondition(stores.tabIDs[profile.id]?["w"] == editors.tabs(in: "w").map(\.id))
        precondition(stores.store(for: UUID()).tabs(in: "w").isEmpty)
        session.selectedSpace = "other"
        precondition(VisibleTabNavigation.entries(session: session, editors: editors).map(\.id) == [.terminal("other")])
        session.selectedSpace = "empty"
        VisibleTabNavigation.move(1, session: session, editors: editors)
        VisibleTabNavigation.select(at: 0, session: session, editors: editors)
        precondition(session.selectedSpace == "empty")
        session.selectedSpace = "files-only"
        editors.open("/p/only.swift", in: "files-only", preview: true, read: { FileContents.decode(Data()) })
        VisibleTabNavigation.move(-1, session: session, editors: editors)
        check(.editor("/p/only.swift"), session, editors)
        // Last editor closed: terminal focus returns; closing a background space cannot steal focus.
        stores.onShowTerminals = { id, space in
            if id == profile.id && session.selectedSpace == space && session.focusOwner == .editor { session.focusOwner = .terminal }
        }
        session.focusOwner = .editor
        editors.close("/p/only.swift", in: "files-only")
        precondition(session.focusOwner == .terminal, "Last editor closure returns focus to terminal")

        // Native per-press event monitors must be removed when their view is destroyed.
        let terminalSource = try String(contentsOfFile: "Sources/HerdrMac/TerminalSurface.swift", encoding: .utf8)
        let terminalView = terminalSource.components(separatedBy: "final class HerdrTerminalView")[1]
        precondition(terminalView.components(separatedBy: "deinit {").count - 1 == 1)
        let destructor = terminalView.components(separatedBy: "deinit {")[1].components(separatedBy: "override func mouseDown")[0]
        precondition(destructor.contains("NSEvent.removeMonitor(mouseUpWatcher)"))
        let workspaceSource = try String(contentsOfFile: "Sources/HerdrMac/WorkspaceView.swift", encoding: .utf8)
        let resizeBody = workspaceSource.components(separatedBy: "private var sidebarResizeHandle")[1].components(separatedBy: "private var sessionActionTitle")[0]
        precondition(resizeBody.contains("sidebarResizeStartWidth = start"))
        precondition(resizeBody.contains("start - value.translation.width"))
        precondition(resizeBody.contains(".onEnded { _ in sidebarResizeStartWidth = nil }"))
        // Guard the menu wiring: model tests alone cannot catch a menu still using terminal-only actions.
        let app = try String(contentsOfFile: "Sources/HerdrMac/HerdrApp.swift", encoding: .utf8)
        precondition(app.contains("SessionStore.revealTerminals = { [editors] profile, space in editors.store(for: profile).showTerminals(in: space) }"))
        let notifier = try String(contentsOfFile: "Sources/HerdrMac/AttentionNotifier.swift", encoding: .utf8)
        precondition(notifier.contains("session.isAgentPaneVisible(agent, editorShown: editors?.store(for: session.profile.id).activeTab(in: agent.workspaceID) != nil)"))
        precondition(app.components(separatedBy: "editors.all.forEach { $0.flushDrafts() }").count - 1 == 2, "Quit and termination both flush pending recovery")
        precondition(app.contains("navigationTabs.prefix(10).enumerated()"))
        precondition(app.components(separatedBy: "VisibleTabNavigation.select(at: index, session: store, editors: currentEditors)").count - 1 == 1)
        precondition(app.components(separatedBy: "VisibleTabNavigation.move(offset, session: store, editors: currentEditors)").count - 1 == 1)
        precondition(app.components(separatedBy: "{ moveTab(").count - 1 == 4, "Both primary and alternate cycling commands use the shared path")
        // Profile edits/replacements reload roots from that profile, not the previous snapshot.
        session.setRoot("/old", for: "old-space")
        var nextProfile = profile
        nextProfile.id = UUID()
        var nextRoots = WorkspaceRoots()
        nextRoots.remember("/new", for: "new-space")
        nextRoots.save(profile: nextProfile.id, to: defaults)
        session.updateProfile(nextProfile)
        precondition(session.workspaceRoots == nextRoots, "Profile replacement reloads remembered roots")
        session.disconnect()
        let sessionSource = try String(contentsOfFile: "Sources/HerdrMac/SessionStore.swift", encoding: .utf8)
        let profileBody = sessionSource.components(separatedBy: "func updateProfile")[1].components(separatedBy: "func refresh")[0]
        precondition(profileBody.contains("rootsRevision = 0"))
        print("PASS: full-strip navigation, files/diffs, wraparound, first ten digits, invalid destinations, dirty preservation, menu updates and wiring, device/space isolation")
    }

    @MainActor static func check(_ id: VisibleTabNavigation.Entry.ID, _ session: SessionStore, _ editors: EditorStore) {
        switch id {
        case let .terminal(id):
            precondition(session.selectedTab == id && editors.activeTab(in: "w") == nil && session.focusOwner == .terminal)
        case let .editor(id):
            precondition(editors.activeTab(in: session.selectedSpace!)?.id == id && session.focusOwner == .editor)
        }
    }
}
