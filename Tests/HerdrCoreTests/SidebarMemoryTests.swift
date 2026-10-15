import Foundation
import HerdrCore

enum SidebarMemoryTests {
    static func run() throws {
        let name = "uherdr-sidebar-memory-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let mac = UUID(), box = UUID()
        XCTAssertEqual(SidebarMemory.load(profile: mac, from: defaults), [:])
        let w1 = SidebarMemory(tab: "changes", expanded: ["Sources", "Sources/HerdrMac"], search: .init(query: "selectedSpace", caseSensitive: true, include: "*.swift"))
        SidebarMemory.save(w1, space: "w1", profile: mac, to: defaults)
        SidebarMemory.save(SidebarMemory(tab: "search"), space: "w2", profile: mac, to: defaults)
        SidebarMemory.save(SidebarMemory(tab: "files"), space: "w1", profile: box, to: defaults)
        XCTAssertEqual(SidebarMemory.load(profile: mac, from: defaults)["w1"], w1)
        XCTAssertEqual(SidebarMemory.load(profile: mac, from: defaults).count, 2)
        XCTAssertEqual(SidebarMemory.load(profile: box, from: defaults)["w1"]?.tab, "files") // per device
        XCTAssertTrue(SidebarMemory.prune(keeping: ["w1"], profile: mac, in: defaults))
        XCTAssertTrue(!SidebarMemory.prune(keeping: ["w1"], profile: mac, in: defaults))
        XCTAssertEqual(Array(SidebarMemory.load(profile: mac, from: defaults).keys), ["w1"])
        SidebarMemory.save(nil, space: "w1", profile: mac, to: defaults)
        XCTAssertTrue(defaults.data(forKey: SidebarMemory.key(profile: mac)) == nil)
        print("PASS: sidebar memory: tab, open folders and search per space and device, pruned with the spaces, forgotten")
    }
}
