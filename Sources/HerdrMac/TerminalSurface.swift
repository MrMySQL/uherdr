import AppKit
import SwiftUI
import SwiftTerm
import HerdrCore

@MainActor
final class TerminalController: ObservableObject {
    @Published var error: String?
    @Published var ready = false
    var receive: ((Data) -> Void)?
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var errors: FileHandle?
    private var framing = JSONLineBuffer()
    private var errorText = ""
    private var generation = UUID()
    private var lastSize = (0, 0)
    private let writer = DispatchQueue(label: "dev.herdr.native.terminal-input")
    private var configuration: (String, String, String)?

    func start(executable: String, socket: String, pane: String, cols: Int, rows: Int, takeover: Bool = false) {
        stop()
        configuration = (executable, socket, pane)
        error = nil; ready = false; framing = JSONLineBuffer(); errorText = ""
        generation = UUID()
        let token = generation
        let child = Process()
        let stdinPipe = Pipe(), stdoutPipe = Pipe(), stderrPipe = Pipe()
        child.executableURL = URL(fileURLWithPath: (executable as NSString).expandingTildeInPath)
        child.arguments = ["terminal", "session", "control", pane, "--cols", String(max(2, cols)), "--rows", String(max(2, rows))] + (takeover ? ["--takeover"] : [])
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "HERDR_SESSION")
        env["HERDR_SOCKET_PATH"] = (socket as NSString).expandingTildeInPath
        child.environment = env
        child.standardInput = stdinPipe
        child.standardOutput = stdoutPipe
        child.standardError = stderrPipe
        input = stdinPipe.fileHandleForWriting
        output = stdoutPipe.fileHandleForReading
        errors = stderrPipe.fileHandleForReading
        lastSize = (max(2, cols), max(2, rows))
        output?.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == token, !data.isEmpty else { return }
                do {
                    for line in try self.framing.append(data) {
                        let frame = try JSONDecoder().decode(TerminalEnvelope.self, from: line)
                        if frame.type == "terminal.frame" {
                            self.receive?(try frame.decodedBytes())
                            self.ready = true
                        } else if frame.type == "terminal.closed" {
                            self.error = frame.reason ?? "Terminal connection closed"
                            self.ready = false
                        }
                    }
                } catch { self.error = error.localizedDescription }
            }
        }
        errors?.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == token, !data.isEmpty else { return }
                self.errorText = String((self.errorText + String(decoding: data, as: UTF8.self)).suffix(4000))
                if !self.ready { self.error = self.errorText.trimmingCharacters(in: .whitespacesAndNewlines) }
            }
        }
        child.terminationHandler = { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self, self.generation == token else { return }
                self.ready = false
                if self.error == nil { self.error = self.errorText.isEmpty ? "Terminal detached. Reconnect to continue." : self.errorText }
            }
        }
        do { try child.run(); process = child }
        catch { self.error = "Could not launch herdr: \(error.localizedDescription)" }
    }

    func retry(takeover: Bool = false) {
        guard let (exe, socket, pane) = configuration else { return }
        start(executable: exe, socket: socket, pane: pane, cols: lastSize.0, rows: lastSize.1, takeover: takeover)
    }

    func send(_ data: Data) {
        write(["type": .string("terminal.input"), "bytes": .string(data.base64EncodedString())])
    }
    func resize(cols: Int, rows: Int) {
        guard cols > 1, rows > 1, (cols, rows) != lastSize else { return }
        lastSize = (cols, rows)
        write(["type": .string("terminal.resize"), "cols": .number(Double(cols)), "rows": .number(Double(rows))])
    }
    func scroll(delta: Double) {
        guard abs(delta) >= 1 else { return }
        write(["type": .string("terminal.scroll"), "direction": .string(delta > 0 ? "up" : "down"), "lines": .number(min(100, max(1, abs(delta)))), "source": .string("wheel")])
    }
    private func write(_ object: [String: JSONValue]) {
        guard let input, process?.isRunning == true, var data = try? JSONEncoder().encode(JSONValue.object(object)) else { return }
        data.append(10)
        let token = generation
        writer.async { [weak self] in
            do { try input.write(contentsOf: data) }
            catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == token else { return }
                    self.error = "Terminal input disconnected: \(error.localizedDescription)"
                }
            }
        }
    }
    func stop() {
        generation = UUID()
        output?.readabilityHandler = nil
        errors?.readabilityHandler = nil
        // Only the CLI stream is terminated. Herdr owns and retains the shell process.
        try? input?.close()
        if process?.isRunning == true { process?.terminate() }
        try? output?.close(); try? errors?.close()
        input = nil; output = nil; errors = nil; process = nil
    }
}

struct TerminalSurface: NSViewRepresentable {
    @ObservedObject var controller: TerminalController
    let pane: Pane
    @ObservedObject var store: SessionStore
    let dark: Bool

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller, store: store, paneID: pane.id) }
    func makeNSView(context: Context) -> TerminalView {
        let view = HerdrTerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 360))
        view.font = .monospacedSystemFont(ofSize: store.fontSize, weight: .regular)
        view.nativeBackgroundColor = background
        view.nativeForegroundColor = foreground
        view.terminalDelegate = context.coordinator
        view.optionAsMetaKey = true
        view.setAccessibilityLabel("Terminal: \(pane.displayTitle)")
        context.coordinator.view = view
        view.onAttach = { [weak coordinator = context.coordinator] in coordinator?.focusIfSelected() }
        controller.receive = { [weak view, weak coordinator = context.coordinator] data in
            coordinator?.feeding = true
            view?.feed(byteArray: Array(data)[...])
            coordinator?.feeding = false
        }
        let term = view.getTerminal()
        controller.start(executable: store.executable, socket: store.socketPath, pane: pane.id, cols: term.cols, rows: term.rows)
        context.coordinator.installEvents()
        return view
    }
    private var background: NSColor { dark ? NSColor(red: 0.055, green: 0.065, blue: 0.075, alpha: 1) : NSColor(red: 0.98, green: 0.98, blue: 0.97, alpha: 1) }
    private var foreground: NSColor { dark ? NSColor(red: 0.86, green: 0.89, blue: 0.87, alpha: 1) : NSColor(red: 0.13, green: 0.16, blue: 0.15, alpha: 1) }
    func updateNSView(_ view: TerminalView, context: Context) {
        if view.font.pointSize != store.fontSize { view.font = .monospacedSystemFont(ofSize: store.fontSize, weight: .regular) }
        view.nativeBackgroundColor = background
        view.nativeForegroundColor = foreground
        let shouldFocus = store.selectedPane == pane.id
        if shouldFocus && !context.coordinator.wasSelected && store.sheet == nil && store.pendingClose == nil {
            DispatchQueue.main.async { [weak view] in
                guard let view else { return }
                view.window?.makeFirstResponder(view)
            }
        }
        context.coordinator.wasSelected = shouldFocus
    }
    static func dismantleNSView(_ view: TerminalView, coordinator: Coordinator) {
        coordinator.removeEvents()
        coordinator.controller.receive = nil
        coordinator.controller.stop()
    }

    @MainActor final class Coordinator: NSObject, @preconcurrency TerminalViewDelegate {
        let controller: TerminalController
        weak var store: SessionStore?
        let paneID: String
        weak var view: TerminalView?
        var monitor: Any?
        var feeding = false
        var wasSelected = false
        var scrollRemainder: Double = 0
        init(controller: TerminalController, store: SessionStore, paneID: String) {
            self.controller = controller; self.store = store; self.paneID = paneID
        }
        func focusIfSelected() {
            guard let view, let store, store.selectedPane == paneID, store.sheet == nil, store.pendingClose == nil else { return }
            view.window?.makeFirstResponder(view)
        }
        func installEvents() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .leftMouseDown, .keyDown]) { [weak self] event in
                guard let self, let view = self.view, event.window === view.window else { return event }
                if event.type == .keyDown {
                    guard view.window?.firstResponder === view,
                          let terminal = view as? HerdrTerminalView else { return event }
                    return terminal.handleShiftEnter(event) ? nil : event
                }
                guard view.bounds.contains(view.convert(event.locationInWindow, from: nil)) else { return event }
                if event.type == .leftMouseDown { self.store?.focusPane(self.paneID); return event }
                self.scrollRemainder += Double(event.scrollingDeltaY) / (event.hasPreciseScrollingDeltas ? 15 : 1)
                let whole = self.scrollRemainder.rounded(.towardZero)
                if abs(whole) >= 1 { self.controller.scroll(delta: whole); self.scrollRemainder -= whole }
                return nil
            }
        }
        func removeEvents() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) { controller.resize(cols: newCols, rows: newRows) }
        func send(source: TerminalView, data: ArraySlice<UInt8>) { if !feeding { controller.send(Data(data)) } }
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
        func bell(source: TerminalView) { NSSound.beep() }
        func clipboardCopy(source: TerminalView, content: Data) {
            guard let text = String(data: content, encoding: .utf8) else { return }
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
        }
        func clipboardRead(source: TerminalView) -> Data? { nil }
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            guard let url = URL(string: link), ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") else { return }
            NSWorkspace.shared.open(url)
        }
    }
}

@MainActor
final class HerdrTerminalView: TerminalView {
    var onAttach: (() -> Void)?

    func handleShiftEnter(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.shift, .control, .option, .command])
        if (event.keyCode == 36 || event.keyCode == 76), modifiers == .shift,
           !hasMarkedText(), getTerminal().keyboardEnhancementFlags.isEmpty {
            // Legacy terminal input collapses Shift-Enter to Return. Preserve the
            // modifier with CSI-u so Claude Code and Codex can insert a newline.
            selectNone()
            send(txt: "\u{1b}[13;2u")
            return true
        }
        return false
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { DispatchQueue.main.async { [weak self] in self?.onAttach?() } }
    }
}
