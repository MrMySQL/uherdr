import AppKit
import SwiftUI
import GhosttyTerminal
import GhosttyKit
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
        env.removeValue(forKey: "HERDR_CLIENT_SOCKET_PATH")
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
    var visible = true

    func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator(controller: controller, store: store, paneID: pane.id)
        coordinator.visible = visible
        return coordinator
    }

    func makeNSView(context: Context) -> HerdrTerminalView {
        let coordinator = context.coordinator
        let view = HerdrTerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 360))
        coordinator.view = view
        view.delegate = coordinator
        // Set the host backend before assigning a controller: the default backend
        // launches a shell, whereas Herdr must retain ownership of every pane.
        view.configuration = TerminalSurfaceOptions(backend: .inMemory(coordinator.bridge.session))
        view.controller = coordinator.engine
        view.setSurfaceVisible(visible)
        view.onAttach = { [weak coordinator] in coordinator?.focusIfSelected() }
        view.canAcceptFileDrop = { [weak coordinator] in
            guard let coordinator, let store = coordinator.store else { return false }
            return !coordinator.stopped && coordinator.visible && coordinator.controller.ready
                && coordinator.controller.error == nil && store.sheet == nil && store.pendingClose == nil
        }
        view.setAccessibilityLabel("Terminal: \(pane.displayTitle)")
        controller.receive = { [weak bridge = coordinator.bridge] in bridge?.receive($0) }
        coordinator.updateAppearance(fontSize: store.fontSize, dark: dark)
        coordinator.installEvents()
        return view
    }

    func updateNSView(_ view: HerdrTerminalView, context: Context) {
        let coordinator = context.coordinator
        coordinator.visible = visible
        view.setSurfaceVisible(visible)
        coordinator.updateAppearance(fontSize: store.fontSize, dark: dark)
        let shouldFocus = visible && store.selectedPane == pane.id
        if shouldFocus && !coordinator.wasSelected {
            DispatchQueue.main.async { [weak coordinator] in coordinator?.focusIfSelected() }
        }
        coordinator.wasSelected = shouldFocus
    }

    static func dismantleNSView(_ view: HerdrTerminalView, coordinator: Coordinator) {
        coordinator.removeEvents()
        coordinator.controller.receive = nil
        coordinator.controller.stop()
        coordinator.stopped = true
        view.onAttach = nil
        view.canAcceptFileDrop = { false }
        view.delegate = nil
        view.setSurfaceVisible(false)
        view.controller = nil
    }

    @MainActor final class Coordinator: NSObject, TerminalSurfaceLifecycleDelegate,
        TerminalSurfaceFocusDelegate, TerminalSurfaceBellDelegate,
        TerminalSurfaceOpenURLDelegate, TerminalSurfaceClipboardConfirmationDelegate {
        let controller: TerminalController
        weak var store: SessionStore?
        let paneID: String
        weak var view: HerdrTerminalView?
        let engine = GhosttyTerminal.TerminalController(
            configuration: HerdrTerminalView.baseConfiguration,
            theme: TerminalTheme(
                light: TerminalConfiguration.alabaster.background("#fafaf7").foreground("#212926"),
                dark: TerminalConfiguration().background("#0e1113").foreground("#dbe3de")
            )
        )
        lazy var bridge = GhosttyStreamBridge(
            input: { [weak self] data in
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.stopped else { return }
                    self.controller.send(data)
                }
            },
            resize: { [weak self] viewport in
                DispatchQueue.main.async { [weak self] in
                    self?.resize(cols: Int(viewport.columns), rows: Int(viewport.rows))
                }
            }
        )
        var monitor: Any?
        var wasSelected = false
        var started = false
        var stopped = false
        var visible = true
        var scrollRemainder: Double = 0
        private var fontSize: Double?
        private var dark: Bool?

        init(controller: TerminalController, store: SessionStore, paneID: String) {
            self.controller = controller
            self.store = store
            self.paneID = paneID
        }

        func updateAppearance(fontSize: Double, dark: Bool) {
            if self.fontSize != fontSize {
                engine.setTerminalConfiguration(TerminalConfiguration().fontSize(Float(fontSize)))
                self.fontSize = fontSize
            }
            if self.dark != dark {
                view?.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                engine.setColorScheme(dark ? .dark : .light)
                self.dark = dark
            }
        }

        private func resize(cols: Int, rows: Int) {
            guard !stopped, cols > 1, rows > 1, let store else { return }
            if !started {
                started = true
                controller.start(executable: store.executable, socket: store.effectiveSocketPath,
                                 pane: paneID, cols: cols, rows: rows)
            } else {
                controller.resize(cols: cols, rows: rows)
            }
        }

        func focusIfSelected() {
            guard !stopped, visible, let view, let store, store.selectedPane == paneID,
                  store.sheet == nil, store.pendingClose == nil else { return }
            view.acquireProgrammaticFocus()
        }

        func installEvents() {
            // Herdr owns the scrollback represented by its ANSI frames. Keep
            // wheel scrolling on the server, while Ghostty handles keys/mouse.
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .leftMouseDown]) { [weak self] event in
                guard let self, !self.stopped, self.visible, let view = self.view,
                      event.window === view.window,
                      view.bounds.contains(view.convert(event.locationInWindow, from: nil)) else { return event }
                if event.type == .leftMouseDown {
                    self.store?.focusPane(self.paneID)
                    return event
                }
                self.scrollRemainder += Double(event.scrollingDeltaY) / (event.hasPreciseScrollingDeltas ? 15 : 1)
                let whole = self.scrollRemainder.rounded(.towardZero)
                if abs(whole) >= 1 {
                    self.controller.scroll(delta: whole)
                    self.scrollRemainder -= whole
                }
                return nil
            }
        }

        func removeEvents() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        func terminalDidAttachSurface(_ surface: GhosttyTerminal.TerminalSurface) {
            DispatchQueue.main.async { [weak self] in self?.focusIfSelected() }
        }
        func terminalDidDetachSurface() {}
        func terminalDidChangeFocus(_ focused: Bool) {
            if focused && visible { store?.focusPane(paneID) }
        }
        func terminalDidRingBell() { NSSound.beep() }
        func terminalDidRequestOpenURL(_ text: String, kind: TerminalOpenURLKind) {
            guard let url = URL(string: text),
                  ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") else { return }
            NSWorkspace.shared.open(url)
        }
        func terminalDidRequestClipboardConfirmation(_ request: TerminalClipboardConfirmationRequest) {
            // Preserve explicit user paste/copy while denying programmatic reads.
            request.respond(allow: request.kind != .osc52Read)
        }
    }
}

@MainActor
final class HerdrTerminalView: AppTerminalView {
    var onAttach: (() -> Void)?
    var canAcceptFileDrop: () -> Bool = { false }
    private var surfaceVisible = true
    private var plainLinkClick = false

    override func mouseDown(with event: NSEvent) {
        plainLinkClick = event.clickCount == 1 && !isMouseCaptured
            && event.modifierFlags.isDisjoint(with: [.shift, .control, .option, .command])
        if plainLinkClick {
            let point = convert(event.locationInWindow, from: nil)
            let modifiers = TerminalInputModifiers(from: event.modifierFlags).union(.super_)
            // The embedded API ignores stationary mouse updates, even when
            // modifiers changed. Reset hover before pressing any button.
            sendMousePos(x: -1, y: -1, modifiers: modifiers)
            sendMousePos(x: point.x, y: bounds.height - point.y, modifiers: modifiers)
        }
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        plainLinkClick = false
        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        defer { plainLinkClick = false }
        guard plainLinkClick, !isMouseCaptured,
              event.modifierFlags.isDisjoint(with: [.shift, .control, .option, .command]) else {
            super.mouseUp(with: event)
            return
        }

        // Ghostty's URL and OSC 8 matchers require Command. Apply it only
        // to plain clicks so matching uses the engine's real
        // terminal cells and the existing default-browser URL delegate.
        let point = convert(event.locationInWindow, from: nil)
        let x = point.x, y = bounds.height - point.y
        let modifiers = TerminalInputModifiers(from: event.modifierFlags)
        sendMousePos(x: x, y: y, modifiers: modifiers.union(.super_))
        sendMouseButton(state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_LEFT,
                        modifiers: modifiers.union(.super_))
        // Restore hover and modifiers after release, when this cannot
        // create a selection drag or report movement to a mouse consumer.
        sendMousePos(x: -1, y: -1, modifiers: modifiers)
        sendMousePos(x: x, y: y, modifiers: modifiers)
    }

    override var acceptsFirstResponder: Bool { surfaceVisible }

    override func becomeFirstResponder() -> Bool {
        guard surfaceVisible else { return false }
        return super.becomeFirstResponder()
    }

    override func setSurfaceVisible(_ visible: Bool) {
        surfaceVisible = visible
        super.setSurfaceVisible(visible)
        // A destination tab may still be loading. Do not leave keyboard input
        // routed to the retained, invisible terminal in the meantime.
        if !visible, let window, window.firstResponder === self {
            window.makeFirstResponder(nil)
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        fileDropText(sender) == nil ? [] : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingEntered(sender)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        fileDropText(sender) != nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let text = fileDropText(sender), paste(text: text) else { return false }
        acquireProgrammaticFocus()
        return true
    }

    private func fileDropText(_ sender: NSDraggingInfo) -> String? {
        guard canAcceptFileDrop(), controller != nil, window != nil, !isHiddenOrHasHiddenAncestor,
              sender.draggingSourceOperationMask.contains(.copy),
              let urls = sender.draggingPasteboard.readObjects(
                forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]
              ) as? [URL], !urls.isEmpty else { return nil }
        let paths = urls.map(\.path)
        // Reject control characters even when bracketed paste is disabled by
        // the receiving program. A drop must never inject a submit or escape.
        guard urls.allSatisfy(\.isFileURL), paths.allSatisfy({
            !$0.isEmpty && $0.rangeOfCharacter(from: .controlCharacters) == nil
        }) else { return nil }
        // POSIX single quoting keeps shell metacharacters literal; close and
        // reopen the quote around apostrophes. Leave room for the next word.
        return paths.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            .joined(separator: " ") + " "
    }

    static var baseConfiguration: TerminalConfiguration {
        TerminalConfiguration.default
            .fontFamily("Menlo")
            // TUI input fields can supply dark backgrounds even in light mode.
            // Keep text readable against each cell's actual background.
            .minimumContrast(4.5)
            .windowPaddingX(0).windowPaddingY(0)
            .custom("macos-option-as-alt", "true")
            .custom("clipboard-read", "deny")
            .custom("clipboard-write", "allow")
            .custom("keybind", "clear")
            .custom("keybind", "super+c=copy_to_clipboard")
            .custom("keybind", "super+v=paste_from_clipboard")
            .custom("keybind", "super+a=select_all")
            .custom("keybind", "shift+enter=text:\\x1b[13;2u")
            .custom("keybind", "shift+numpad_enter=text:\\x1b[13;2u")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { DispatchQueue.main.async { [weak self] in self?.onAttach?() } }
    }
}
