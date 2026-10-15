import Foundation
import HerdrCore

@main struct EditorStoreTests {
    @MainActor static func main() async throws {
        let store = EditorStore()
        let text = { (s: String) -> @Sendable () async throws -> FileContents in { FileContents.decode(Data(s.utf8)) } }

        // A single click opens a preview tab and shows it instead of the terminals.
        store.open("/p/a.swift", in: "w1", preview: true, read: text("a"))
        precondition(store.tabs(in: "w1").map(\.id) == ["/p/a.swift"])
        precondition(store.tabs(in: "w1")[0].isPreview)
        precondition(store.activeTab(in: "w1")?.id == "/p/a.swift")
        try await settle()
        precondition(store.activeTab(in: "w1")?.load == .loaded(FileContents.decode(Data("a".utf8))))

        // The next single click replaces the preview; a double-click keeps a tab.
        store.open("/p/b.swift", in: "w1", preview: true, read: text("b"))
        precondition(store.tabs(in: "w1").map(\.id) == ["/p/b.swift"], "A preview replaces the previous preview")
        store.open("/p/b.swift", in: "w1", preview: false, read: text("b"))
        precondition(store.tabs(in: "w1").map(\.isPreview) == [false], "Double-clicking an open preview keeps it")
        store.open("/p/c.md", in: "w1", preview: true, read: text("c"))
        store.open("/p/d.md", in: "w1", preview: false, read: text("d"))
        precondition(store.tabs(in: "w1").map(\.id) == ["/p/b.swift", "/p/c.md", "/p/d.md"])
        store.open("/p/c.md", in: "w1", preview: true, read: text("c"))
        precondition(store.tabs(in: "w1").count == 3 && store.activeTab(in: "w1")?.id == "/p/c.md", "An open file is shown, not reopened")

        // Spaces are separate; a terminal tab shows terminals again.
        store.open("/q/x.ts", in: "w2", preview: true, read: text("x"))
        precondition(store.tabs(in: "w2").map(\.id) == ["/q/x.ts"] && store.tabs(in: "w1").count == 3)
        store.showTerminals(in: "w1")
        precondition(store.activeTab(in: "w1") == nil && store.tabs(in: "w1").count == 3, "Tabs stay open behind the terminals")
        store.show("/p/d.md", in: "w1")
        precondition(store.activeTab(in: "w1")?.id == "/p/d.md")

        // Closing the shown editor shows its neighbour; closing the last shows the terminals.
        store.close("/p/d.md", in: "w1")
        precondition(store.activeTab(in: "w1")?.id == "/p/c.md")
        store.close("/p/b.swift", in: "w1")
        store.close("/p/c.md", in: "w1")
        precondition(store.tabs(in: "w1").isEmpty && store.activeTab(in: "w1") == nil)

        // A failed read shows its reason; a closed preview's late read is dropped.
        struct Gone: LocalizedError { var errorDescription: String? { "gone" } }
        store.open("/p/missing", in: "w1", preview: false, read: { throw Gone() })
        try await settle()
        precondition(store.activeTab(in: "w1")?.load == .failed("gone"))
        store.open("/p/slow", in: "w1", preview: true, read: {
            try await Task.sleep(for: .milliseconds(200))
            return FileContents.decode(Data("late".utf8))
        })
        store.close("/p/slow", in: "w1")
        try await Task.sleep(for: .milliseconds(300))
        precondition(!store.tabs(in: "w1").contains { $0.id == "/p/slow" }, "A late read must not bring a closed tab back")

        // Spaces herdr no longer lists lose their tabs.
        store.prune(keeping: ["w1"])
        precondition(store.tabs(in: "w2").isEmpty && store.activeTab(in: "w2") == nil)
        let stores = EditorStores()
        let device = UUID()
        precondition(stores.store(for: device) === stores.store(for: device) && stores.store(for: device) !== stores.store(for: UUID()))
        print("PASS: editor tabs: preview reuse, keep, per-space lists, terminals shown again, close order, failed reads, late reads of closed tabs, pruning, per device")
    }

    static func settle() async throws { try await Task.sleep(for: .milliseconds(50)) }
}
