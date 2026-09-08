import AppKit
import SwiftUI
import QuartzCore
import GhosttyTerminal
import HerdrCore
import Darwin
@testable import HerdrMac

/// Opt-in benchmark: real release app views, renderer, CLI streams and a disposable server.
@main
struct PanePerformanceTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.regular)
        setbuf(stdout, nil)
        Task { @MainActor in
            do { try await run(); exit(0) }
            catch { print("FAIL: \(error)"); exit(1) }
        }
        NSApp.run()
    }

    @MainActor static func run() async throws {
        let socket = CommandLine.arguments[1], executable = CommandLine.arguments[2]
        guard socket.hasPrefix("/tmp/"), socket.contains("native-client-test") else {
            throw HerdrError.message("Requires a disposable native-client-test socket")
        }
        let client = HerdrClient(socketPath: socket)
        let suite = "dev.herdr.pane-performance.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let devices = DeviceStore(defaults: defaults, profiles: [
            DeviceProfile(name: "Pane performance", kind: .local, socketPath: socket, executable: executable)
        ])
        let store = devices.activeSession
        let created = try await client.request("workspace.create", params: [
            "label": .string("Disposable performance test"), "cwd": .string("/tmp"), "focus": .bool(true)
        ])
        let workspace = try created["workspace"].decode(Workspace.self)
        await store.refresh()
        let host = NSHostingView(rootView: AnyView(WorkspaceView(store: store, devices: devices)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        defer { host.rootView = AnyView(EmptyView()); window.orderOut(nil); devices.stop() }
        var knownViews: [String: HerdrTerminalView] = [:]
        print("ENV: \(ProcessInfo.processInfo.operatingSystemVersionString); CPUs=\(ProcessInfo.processInfo.processorCount); RAM_GiB=\(ProcessInfo.processInfo.physicalMemory / 1_073_741_824); release optimization; window=1440x900")
        print("METRICS: CPU is benchmark process only, 100%=one core; RSS excludes CLI/server/shell children. Focus latency excludes GPU presentation.")

        func splitGrid(_ pane: Pane, count: Int, horizontal: Bool = true) async throws {
            guard count > 1 else { return }
            let next = try await client.request("pane.split", params: [
                "target_pane_id": .string(pane.id), "direction": .string(horizontal ? "right" : "down"),
                "focus": .bool(false)
            ])["pane"].decode(Pane.self)
            try await splitGrid(pane, count: count / 2, horizontal: !horizontal)
            try await splitGrid(next, count: count / 2, horizontal: !horizontal)
        }
        func warmAll() async throws {
            await store.refresh()
            for tab in store.tabs {
                // A cached layout may predate the fixture's new splits. Await
                // the authoritative tree before capturing native view identities.
                store.layouts[tab.id] = try await client.request("layout.export", params: [
                    "tab_id": .string(tab.id)
                ])["layout"].decode(TabLayout.self)
                store.selectTab(tab)
                try await waitFor("Layout \(tab.id)") { store.layouts[tab.id] != nil }
                let ids = store.layouts[tab.id]!.root.paneIDs
                try await waitFor("Mount \(tab.id)") {
                    terminals(host).count >= store.layouts.values.reduce(0) { $0 + $1.root.paneIDs.count }
                }
                for id in ids where knownViews[id] == nil {
                    let marker = "perf-ready-\(id)-END"
                    _ = try await client.request("pane.send_input", params: [
                        "pane_id": .string(id), "text": .string("printf '\(marker)\\n'"), "keys": .array([.string("enter")])
                    ])
                    try await waitFor("Content \(id)") {
                        if let view = terminals(host).first(where: { viewport($0).contains(marker) }) {
                            knownViews[id] = view; return true
                        }
                        return false
                    }
                }
            }
            try await Task.sleep(for: .seconds(1))
        }
        func sample(_ label: String, busy: Bool, focusOnly: Bool = false) async throws {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            try await waitFor("Benchmark foreground window") { NSApp.isActive && window.isKeyWindow }
            var stayedActive = true
            let originals = Set(terminals(host).map(ObjectIdentifier.init))
            let startCPU = cpuSeconds(), start = CACurrentMediaTime()
            var heartbeat: [Double] = []
            while CACurrentMediaTime() - start < 3 {
                let tick = CACurrentMediaTime()
                try await Task.sleep(for: .milliseconds(10))
                stayedActive = stayedActive && NSApp.isActive && window.isKeyWindow
                heartbeat.append((CACurrentMediaTime() - tick) * 1000)
            }
            let cpu = (cpuSeconds() - startCPU) / (CACurrentMediaTime() - start) * 100
            var switches: [Double] = []
            let tabs = focusOnly ? [store.currentTab!] : store.tabs
            for index in 0..<40 {
                let tab = tabs[index % tabs.count]
                // With one tab, measure pane-to-pane focus instead.
                let ids = store.layouts[tab.id]!.root.paneIDs
                let paneID = tabs.count == 1 ? ids[index % ids.count]
                    : store.layouts[tab.id]!.resolveSelectedPane(nil)!
                let tick = CACurrentMediaTime()
                if tabs.count == 1 { store.focusPane(paneID) } else { store.selectTab(tab) }
                try await waitFor("Switch focus") { window.firstResponder === knownViews[paneID] }
                host.layoutSubtreeIfNeeded()
                switches.append((CACurrentMediaTime() - tick) * 1000)
                try await Task.sleep(for: .milliseconds(75))
                stayedActive = stayedActive && NSApp.isActive && window.isKeyWindow
            }
            guard Set(terminals(host).map(ObjectIdentifier.init)) == originals,
                  knownViews.values.allSatisfy({ $0.controller != nil }) else {
                throw HerdrError.message("Switching recreated terminals")
            }
            let visible = terminals(host).filter(\.acceptsFirstResponder).count
            print(String(format: "RESULT %@ %@ switch=%@ panes=%d visible=%d tabs=%d rss_MiB=%.1f cpu_pct=%.1f focus_p50_ms=%.2f focus_p95_ms=%.2f focus_max_ms=%.2f heartbeat_p95_ms=%.2f heartbeat_max_ms=%.2f retained=yes active=%@",
                         label, busy ? "output10Hz" : "idle", tabs.count == 1 ? "pane" : "tab", originals.count, visible, store.tabs.count, residentMiB(), cpu,
                         percentile(switches, 0.5), percentile(switches, 0.95), switches.max()!, percentile(heartbeat, 0.95), heartbeat.max()!, stayedActive ? "yes" : "no"))
        }

        try await splitGrid(try created["root_pane"].decode(Pane.self), count: 4)
        let counts = (ProcessInfo.processInfo.environment["HERDR_PERF_COUNTS"] ?? "4,16,32,64")
            .split(separator: ",").compactMap { Int($0) }
        guard !counts.isEmpty, counts.allSatisfy({ $0 >= 4 && $0 <= 64 && $0 % 4 == 0 }) else {
            throw HerdrError.message("HERDR_PERF_COUNTS must contain multiples of four between 4 and 64")
        }
        for count in counts {
            await store.refresh()
            while store.panes.count < count {
                let result = try await client.request("tab.create", params: [
                    "workspace_id": .string(workspace.id), "label": .string("Load \(store.tabs.count + 1)"), "focus": .bool(false)
                ])
                try await splitGrid(try result["root_pane"].decode(Pane.self), count: 4)
                await store.refresh()
            }
            try await warmAll()
            try await sample("retained", busy: false)
            // Keep producers alive for the entire measurement; stop explicitly below.
            for pane in store.panes {
                _ = try await client.request("pane.send_input", params: [
                    "pane_id": .string(pane.id),
                    "text": .string("python3 -u -c 'import time; [(print(\"load\", i), time.sleep(.1)) for i in range(1200)]'"),
                    "keys": .array([.string("enter")])
                ])
            }
            try await waitFor("All output producers started") {
                knownViews.values.allSatisfy { viewport($0).contains("load 2") }
            }
            let beforeOutput = knownViews.mapValues(viewport)
            try await sample("retained", busy: true)
            guard knownViews.allSatisfy({ id, view in
                let text = viewport(view)
                return text.contains("load ") && text != beforeOutput[id] && !text.contains("Traceback")
            }) else { throw HerdrError.message("A pane did not keep producing output during the busy sample") }
            for pane in store.panes {
                _ = try await client.request("pane.send_input", params: [
                    "pane_id": .string(pane.id), "text": .string("\u{03}")
                ])
            }
            try await Task.sleep(for: .milliseconds(200))
            for pane in store.panes {
                _ = try await client.request("pane.send_input", params: [
                    "pane_id": .string(pane.id), "text": .string("printf 'perf-stopped-\(pane.id)-END\\n'"),
                    "keys": .array([.string("enter")])
                ])
            }
            try await waitFor("All output producers stopped") {
                knownViews.allSatisfy { id, view in viewport(view).contains("perf-stopped-\(id)-END") }
            }
            guard residentMiB() < 2500 else { throw HerdrError.message("Benchmark exceeded 2.5 GiB app RSS; stopping") }
        }
        // Expand one tab to a 4x4 grid, while preserving the other cached tabs.
        let dense = store.tabs[0]
        for id in store.layouts[dense.id]!.root.paneIDs {
            try await splitGrid(store.panes.first { $0.id == id }!, count: 4)
        }
        knownViews = [:] // The intentional layout edits change terminal view ancestry.
        try await warmAll()
        store.selectTab(dense)
        try await waitFor("Dense grid focus") { window.firstResponder === knownViews[store.selectedPane ?? ""] }
        try await sample("dense-grid", busy: false, focusOnly: true)
        _ = try await client.request("workspace.close", params: ["workspace_id": .string(workspace.id)])
        await store.refresh()
        try await waitFor("Cleanup") { terminals(host).isEmpty }
        print("PASS: all benchmark panes closed and terminal views released")
    }

    @MainActor static func waitFor(_ label: String, _ predicate: () -> Bool) async throws {
        let deadline = CACurrentMediaTime() + 15
        while !predicate() {
            guard CACurrentMediaTime() < deadline else { throw HerdrError.message("Timed out: \(label)") }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
    @MainActor static func terminals(_ root: NSView) -> [HerdrTerminalView] {
        if let terminal = root as? HerdrTerminalView { return [terminal] }
        return root.subviews.flatMap(terminals)
    }
    @MainActor static func viewport(_ view: HerdrTerminalView) -> String {
        guard case .inMemory(let session) = view.configuration.backend else { return "" }
        return session.readViewportText() ?? ""
    }
    static func percentile(_ values: [Double], _ fraction: Double) -> Double {
        values.sorted()[min(values.count - 1, Int(ceil(Double(values.count) * fraction)) - 1)]
    }
    static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }
    static func residentMiB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : -1
    }
}
