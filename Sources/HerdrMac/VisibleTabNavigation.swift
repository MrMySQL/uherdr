import HerdrCore

/// The tab strip's order: terminal tabs first, then open files and diffs.
@MainActor
enum VisibleTabNavigation {
    struct Entry: Identifiable, Equatable {
        enum ID: Hashable { case terminal(String), editor(String) }
        let id: ID
        let label: String
    }

    static func entries(session: SessionStore, editors: EditorStore) -> [Entry] {
        let terminals = session.visibleTabs.map { Entry(id: .terminal($0.id), label: $0.label) }
        let files = session.selectedSpace.map { space in
            editors.tabs(in: space).map { Entry(id: .editor($0.id), label: $0.name) }
        } ?? []
        return terminals + files
    }

    static func select(_ id: Entry.ID, session: SessionStore, editors: EditorStore) {
        switch id {
        case let .terminal(id):
            guard let tab = session.visibleTabs.first(where: { $0.id == id }) else { return }
            session.selectTab(tab)
            editors.showTerminals(in: tab.workspaceID)
        case let .editor(id):
            guard let space = session.selectedSpace,
                  editors.tabs(in: space).contains(where: { $0.id == id }) else { return }
            editors.show(id, in: space)
            session.focusOwner = .editor
        }
    }

    static func select(at index: Int, session: SessionStore, editors: EditorStore) {
        let tabs = entries(session: session, editors: editors)
        guard (0..<10).contains(index), tabs.indices.contains(index) else { return }
        select(tabs[index].id, session: session, editors: editors)
    }

    static func move(_ offset: Int, session: SessionStore, editors: EditorStore) {
        let tabs = entries(session: session, editors: editors)
        guard !tabs.isEmpty else { return }
        let active: Entry.ID? = session.selectedSpace.flatMap { editors.activeTab(in: $0) }
            .map { .editor($0.id) } ?? session.selectedTab.map { .terminal($0) }
        let index = tabs.firstIndex(where: { $0.id == active }) ?? 0
        let destination = ((index + offset) % tabs.count + tabs.count) % tabs.count
        select(tabs[destination].id, session: session, editors: editors)
    }
}
