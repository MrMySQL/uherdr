import AppKit
import Foundation
import GhosttyTerminal
import HerdrCore
@testable import HerdrMac

extension TerminalPerformanceTests {
    @MainActor static func repaintRequests() async throws {
        let root = try repaintFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = HerdrMac.TerminalController()
        defer { controller.stop() }
        controller.start(executable: root.appendingPathComponent("herdr").path, socket: "/tmp/unused-render.sock", pane: "fixture", cols: 80, rows: 24)
        try await wait("repaint fixture ready") { controller.ready }
        let generation = controller.generation
        controller.resize(cols: 90, rows: 30)
        controller.resize(cols: 110, rows: 40)
        try await Task.sleep(for: .milliseconds(400))
        let commands = try repaintCommands(root)
        guard commands.count == 3,
              commands.map({ $0["cols"] }) == [.number(90), .number(110), .number(110)],
              commands.last?["rows"] == .number(40),
              controller.generation == generation else {
            throw HerdrError.message("Settled resize must request one full repaint at the latest size without reconnecting; got \(commands)")
        }
        print("PASS: resize bursts coalesce into one final full repaint on the same connection")
        controller.setVisible(false)
        controller.resize(cols: 120, rows: 40)
        try await Task.sleep(for: .milliseconds(300))
        guard try repaintCommands(root).count == 4 else {
            throw HerdrError.message("Hidden terminals must not schedule repaint work")
        }
        controller.setVisible(true)
        try await Task.sleep(for: .milliseconds(300))
        let revealed = try repaintCommands(root)
        guard revealed.count == 5, revealed.last?["cols"] == .number(120) else {
            throw HerdrError.message("Revealing a retained terminal must request a fresh full frame")
        }
        controller.setVisible(true)
        try await Task.sleep(for: .milliseconds(250))
        guard try repaintCommands(root).count == 5 else {
            throw HerdrError.message("Repeated visible updates must not trigger additional repaints")
        }
        controller.resize(cols: 130, rows: 45)
        controller.setVisible(false)
        try await Task.sleep(for: .milliseconds(300))
        guard try repaintCommands(root).count == 6, controller.generation == generation else {
            throw HerdrError.message("Hiding must cancel pending recovery without reconnecting")
        }
        controller.setVisible(true)
        controller.stop()
        try await Task.sleep(for: .milliseconds(250))
        guard try repaintCommands(root).count == 6 else {
            throw HerdrError.message("Stopping must cancel pending recovery")
        }
        print("PASS: reveal repaints once; hiding and teardown cancel pending recovery")
    }

    @MainActor static func resizeReplayRecovery() async throws {
        let root = try repaintFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = HerdrMac.TerminalController()
        let engine = GhosttyTerminal.TerminalController(configuration: HerdrTerminalView.baseConfiguration)
        var started = false
        let source = DelayedResizeSource { viewport in
            DispatchQueue.main.async {
                if !started {
                    started = true
                    controller.start(executable: root.appendingPathComponent("herdr").path, socket: "/tmp/unused-render.sock", pane: "fixture", cols: Int(viewport.columns), rows: Int(viewport.rows))
                } else {
                    controller.resize(cols: Int(viewport.columns), rows: Int(viewport.rows))
                }
            }
        }
        let session = InMemoryTerminalSession(write: { _ in }, resize: { source.resize($0) }, suppressesPixelOnlyResizes: true, suppressesTerminalResponses: true)
        controller.receive = { session.receive(Data("\u{1b}[?7l".utf8) + $0) }
        let view = HerdrTerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        view.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
        view.controller = engine
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = view
        window.orderBack(nil)
        defer { controller.stop(); view.controller = nil; window.orderOut(nil) }
        try await wait("native replay fixture ready") { controller.ready }
        try await Task.sleep(for: .milliseconds(300))
        window.setContentSize(NSSize(width: 1500, height: 900))
        view.fitToSize()
        try await Task.sleep(for: .milliseconds(500))
        session.waitForPendingOutput()
        let rows = Int(source.viewport!.rows)
        let actual = (session.readViewportText() ?? "").components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let expected = (1...rows).map { String(format: "row-%03d", $0) }
        guard actual == expected else {
            throw HerdrError.message("New-size replay raced native resize and was not repaired: expected \(rows) rows, tail \(actual.suffix(8))")
        }
        print("PASS: a frame parsed before native resize is repaired without scrolling or reconnecting")
    }

    static func repaintFixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("herdr-repaint-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let script = root.appendingPathComponent("herdr")
        try """
        #!/usr/bin/env python3
        import base64, json, pathlib, sys
        cols = int(sys.argv[sys.argv.index('--cols') + 1])
        rows = int(sys.argv[sys.argv.index('--rows') + 1])
        seq = 0
        def paint():
            global seq
            seq += 1
            text = '\\x1b[?2026h\\x1b[2J'
            for row in range(1, rows + 1):
                text += '\\x1b[%d;1H' % row + ('row-%03d' % row).ljust(cols)
            text += '\\x1b[1;1H\\x1b[?2026l'
            print(json.dumps(dict(type='terminal.frame', width=cols, height=rows, full=True, seq=seq, bytes=base64.b64encode(text.encode()).decode())), flush=True)
        paint()
        with (pathlib.Path(__file__).parent / 'commands.jsonl').open('a') as log:
            for line in sys.stdin:
                log.write(line)
                log.flush()
                command = json.loads(line)
                if command['type'] == 'terminal.resize':
                    cols, rows = command['cols'], command['rows']
                    paint()
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        return root
    }

    static func repaintCommands(_ root: URL) throws -> [JSONValue] {
        let text = try String(contentsOf: root.appendingPathComponent("commands.jsonl"), encoding: .utf8)
        return try text.split(separator: "\n").map { try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
    }
}

private final class DelayedResizeSource: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: InMemoryTerminalViewport?
    private let handler: @Sendable (InMemoryTerminalViewport) -> Void
    init(handler: @escaping @Sendable (InMemoryTerminalViewport) -> Void) { self.handler = handler }
    var viewport: InMemoryTerminalViewport? { lock.lock(); defer { lock.unlock() }; return latest }
    func resize(_ viewport: InMemoryTerminalViewport) {
        lock.lock(); latest = viewport; lock.unlock()
        handler(viewport)
        // Pinned Ghostty calls this before resizing its terminal cells. Hold
        // that IO operation so the real CLI/replay path wins the parser lock.
        Thread.sleep(forTimeInterval: 0.08)
    }
}
