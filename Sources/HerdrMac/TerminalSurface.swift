import AppKit
import SwiftUI
import GhosttyTerminal
import GhosttyKit
import HerdrCore

@MainActor
final class TerminalController: ObservableObject {
    @Published var error: String?
    @Published var pasteError: String?
    @Published var ready = false
    @Published var uploadingFiles = false
    private(set) var clipboardReady = false
    var receive: ((Data) -> Void)?
    var resetInput: (() -> Void)?
    var cancelFileDrop: (() -> Void)?
    private var nativeConnection: NativeTerminalConnection?
    private var focused = false
    private var mouseCaptured = false
    private var clipboardActive = false
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var errors: FileHandle?
    private var framing = JSONLineBuffer()
    private var errorText = ""
    private(set) var generation = UUID()
    private var lastSize = (0, 0)
    private var visible = true
    private var repaintTask: Task<Void, Never>?
    private let writer = DispatchQueue(label: "dev.herdr.native.terminal-input")
    private var configuration: (String, String, String, Int?)?

    func start(executable: String, socket: String, pane: String, cols: Int, rows: Int, takeover: Bool = false, serverProtocol: Int? = nil) {
        stop()
        configuration = (executable, socket, pane, serverProtocol)
        error = nil
        if ready { ready = false }
        framing = JSONLineBuffer(); errorText = ""
        generation = UUID()
        let token = generation
        lastSize = (max(2, cols), max(2, rows))
        if serverProtocol == 22 {
            let connection = NativeTerminalConnection(socketPath: (socket as NSString).expandingTildeInPath,
                pane: pane, cols: lastSize.0, rows: lastSize.1, takeover: takeover) { [weak self] event in
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == token else { return }
                    switch event {
                    case .frame(let data):
                        self.receive?(data)
                        if !self.ready {
                            self.ready = true
                            self.scheduleRepaint()
                        }
                    case .mouseCapture(let enabled):
                        self.updateMouseCapture(enabled)
                    case .clipboardReady(let ready):
                        self.clipboardReady = ready
                    case .clipboard(let data):
                        guard self.focused, self.visible, self.clipboardActive, self.error == nil,
                              let text = String(data: data, encoding: .utf8) else { return }
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    case .error(let message):
                        self.error = message
                        self.ready = false
                        self.updateMouseCapture(false)
                        self.nativeConnection?.stop()
                    }
                }
            }
            nativeConnection = connection
            connection.start()
            syncClipboardFocus()
            return
        }
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
                            if !self.ready {
                                self.ready = true
                                self.scheduleRepaint()
                            }
                        } else if frame.type == "terminal.closed" {
                            self.error = frame.reason ?? "Terminal connection closed"
                            if self.ready { self.ready = false }
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
                if self.ready { self.ready = false }
                if self.error == nil { self.error = self.errorText.isEmpty ? "Terminal detached. Reconnect to continue." : self.errorText }
            }
        }
        do { try child.run(); process = child }
        catch { self.error = "Could not launch herdr: \(error.localizedDescription)" }
    }

    func retry(takeover: Bool = false) {
        guard let (exe, socket, pane, serverProtocol) = configuration else { return }
        start(executable: exe, socket: socket, pane: pane, cols: lastSize.0, rows: lastSize.1, takeover: takeover, serverProtocol: serverProtocol)
    }

    func send(_ data: Data) {
        guard error == nil, pasteError == nil else { return }
        if let nativeConnection { nativeConnection.send(data); return }
        write(["type": .string("terminal.input"), "bytes": .string(data.base64EncodedString())])
    }
    func resize(cols: Int, rows: Int) {
        guard cols > 1, rows > 1, (cols, rows) != lastSize else { return }
        lastSize = (cols, rows)
        writeResize()
        scheduleRepaint()
    }
    func setVisible(_ visible: Bool) {
        guard self.visible != visible else { return }
        self.visible = visible
        syncClipboardFocus()
        scheduleRepaint()
    }
    func setFocused(_ focused: Bool) {
        self.focused = focused
        syncClipboardFocus()
    }
    private func syncClipboardFocus() {
        // Activate only when an application needs mouse input. Keep the endpoint
        // for this focus epoch so a final OSC 52 can arrive after mouse mode ends;
        // those messages travel on independent sockets and may arrive out of order.
        clipboardActive = focused && visible && (mouseCaptured || clipboardActive)
        nativeConnection?.setFocused(clipboardActive)
    }
    private func updateMouseCapture(_ enabled: Bool) {
        guard mouseCaptured != enabled else { return }
        mouseCaptured = enabled
        syncClipboardFocus()
        // Ask Ghostty for cell-coordinate reports. Herdr re-encodes structured
        // mouse events using the application's real tracking/encoding modes.
        let reset = "\u{1b}[?9;1000;1002;1003;1005;1006;1015;1016l"
        receive?(Data((reset + (enabled ? "\u{1b}[?1003h\u{1b}[?1006h" : "")).utf8))
    }
    private func writeResize() {
        if let nativeConnection { nativeConnection.resize(cols: lastSize.0, rows: lastSize.1); return }
        write(["type": .string("terminal.resize"), "cols": .number(Double(lastSize.0)), "rows": .number(Double(lastSize.1))])
    }
    private func scheduleRepaint() {
        repaintTask?.cancel()
        repaintTask = nil
        guard visible else { return }
        let token = generation
        // Ghostty reports host-managed resize before resizing its own cells.
        // A fast server frame can be parsed against the old grid, leaving its
        // diff baseline out of sync. After geometry settles, ask for a full
        // frame on the existing stream. Herdr repaints identical-size resize
        // requests without resizing the PTY or sending another SIGWINCH.
        repaintTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self, self.generation == token,
                  self.visible, self.ready, self.error == nil else { return }
            self.repaintTask = nil
            self.writeResize()
        }
    }
    func scroll(delta: Double) {
        guard abs(delta) >= 1 else { return }
        if let nativeConnection { nativeConnection.scroll(delta: delta); return }
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
        repaintTask?.cancel()
        repaintTask = nil
        resetInput?()
        pasteError = nil
        generation = UUID()
        nativeConnection?.stop()
        nativeConnection = nil
        clipboardReady = false
        clipboardActive = false
        updateMouseCapture(false)
        cancelFileDrop?()
        output?.readabilityHandler = nil
        errors?.readabilityHandler = nil
        // Only the CLI stream is terminated. Herdr owns and retains the shell process.
        try? input?.close()
        if process?.isRunning == true { process?.terminate() }
        try? output?.close(); try? errors?.close()
        input = nil; output = nil; errors = nil; process = nil
    }

    func resumeInputAfterRejectedPaste() {
        resetInput?()
        pasteError = nil
    }
}

struct TerminalSurface: NSViewRepresentable {
    @ObservedObject var controller: TerminalController
    let pane: Pane
    let store: SessionStore
    let dark: Bool
    let fontSize: Double
    let selected: Bool
    var visible = true
    var searching = false
    var dismissSearch: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator(controller: controller, store: store, paneID: pane.id)
        coordinator.visible = visible
        coordinator.searching = searching
        coordinator.dismissSearch = dismissSearch
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
        controller.setVisible(visible)
        view.onAttach = { [weak coordinator] in coordinator?.focusIfSelected() }
        view.onFocusChanged = { [weak coordinator] in coordinator?.syncInputFocus() }
        view.onRetainedTabVisibility = { [weak coordinator] visible, zoomedPaneID in
            guard let coordinator, !coordinator.stopped else { return }
            let paneVisible = visible && (zoomedPaneID == nil || zoomedPaneID == coordinator.paneID)
            coordinator.visible = paneVisible
            coordinator.view?.setSurfaceVisible(paneVisible)
            coordinator.controller.setVisible(paneVisible)
            if !paneVisible, coordinator.searching {
                // SwiftUI may coalesce the hidden snapshot on a fast tab
                // round-trip. Dismiss outside the current view update anyway.
                DispatchQueue.main.async { [weak coordinator] in coordinator?.dismissSearch?() }
            }
            // A rapid tab round-trip can coalesce away SwiftUI's hidden
            // snapshot. Keep native visibility and selection bookkeeping in sync.
            coordinator.wasSelected = paneVisible && coordinator.store?.selectedPane == coordinator.paneID
            if paneVisible { coordinator.focusIfSelected() }
        }
        view.canAcceptFileDrop = { [weak coordinator] in
            guard let coordinator, let store = coordinator.store else { return false }
            return !coordinator.stopped && coordinator.surfaceAttached && coordinator.visible && coordinator.view?.isHiddenOrHasHiddenAncestor == false && coordinator.controller.ready
                && coordinator.controller.error == nil && coordinator.controller.pasteError == nil && !coordinator.controller.uploadingFiles
                && !coordinator.searching && store.sheet == nil && store.pendingClose == nil
        }
        view.resolveFileDrop = { [weak coordinator] urls in
            guard let coordinator, let store = coordinator.store else { throw CancellationError() }
            let connection = store.connectionGeneration
            let terminal = coordinator.controller.generation
            coordinator.controller.uploadingFiles = store.isRemote
            defer { coordinator.controller.uploadingFiles = false }
            var files: PreparedFileDrop?
            do {
                let prepared = try await store.prepareDroppedFiles(urls)
                files = prepared
                try Task.checkCancellation()
                guard !coordinator.stopped, store.connectionGeneration == connection,
                      coordinator.controller.generation == terminal else { throw CancellationError() }
                return prepared
            } catch {
                await files?.discard()
                guard coordinator.controller.generation == terminal else { throw CancellationError() }
                throw error
            }
        }
        view.onFileDropError = { [weak coordinator] error in
            coordinator?.store?.operationError = "Could not paste files: \(error.localizedDescription)"
        }
        controller.cancelFileDrop = { [weak view] in view?.cancelFileDrop() }
        view.setAccessibilityLabel("Terminal: \(pane.displayTitle)")
        controller.receive = { [weak coordinator] data in
            guard let coordinator else { return }
            coordinator.bridge.receive(data, semanticPastes: GhosttyStreamBridge.supportsSemanticPastes(
                serverVersion: coordinator.store?.version ?? ""
            ))
        }
        controller.resetInput = { [weak bridge = coordinator.bridge] in bridge?.resetInput() }
        coordinator.updateAppearance(fontSize: fontSize, dark: dark)
        coordinator.installEvents()
        return view
    }

    func updateNSView(_ view: HerdrTerminalView, context: Context) {
        let coordinator = context.coordinator
        coordinator.visible = visible
        let wasSearching = coordinator.searching
        coordinator.searching = searching
        coordinator.dismissSearch = dismissSearch
        view.setAccessibilityLabel("Terminal: \(pane.displayTitle)")
        view.setSurfaceVisible(visible)
        controller.setVisible(visible)
        coordinator.updateAppearance(fontSize: fontSize, dark: dark)
        let shouldFocus = visible && selected
        if shouldFocus && !searching && (!coordinator.wasSelected || wasSearching) {
            DispatchQueue.main.async { [weak coordinator] in coordinator?.focusIfSelected() }
        }
        coordinator.wasSelected = shouldFocus
        coordinator.syncInputFocus()
    }

    static func dismantleNSView(_ view: HerdrTerminalView, coordinator: Coordinator) {
        coordinator.removeEvents()
        coordinator.controller.receive = nil
        coordinator.controller.stop()
        coordinator.controller.resetInput = nil
        coordinator.controller.cancelFileDrop = nil
        coordinator.stopped = true
        view.cancelFileDrop()
        view.onAttach = nil
        view.onFocusChanged = nil
        view.onRetainedTabVisibility = nil
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
            theme: EmbeddedTerminalPalette.theme
        )
        lazy var bridge: GhosttyStreamBridge = GhosttyStreamBridge(
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
            },
            pasteRejected: { [weak self] in
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.stopped, self.bridge.hasRejectedPaste else { return }
                    self.controller.pasteError = "The paste exceeds the 1 MiB input limit. Use a smaller selection."
                }
            }
        )
        var monitor: Any?
        var wasSelected = false
        var started = false
        var stopped = false
        var surfaceAttached = false
        var visible = true
        var searching = false
        var dismissSearch: (() -> Void)?
        var scrollRemainder: Double = 0
        private var fontSize: Double?
        private var dark: Bool?

        init(controller: TerminalController, store: SessionStore, paneID: String) {
            self.controller = controller
            self.store = store
            self.paneID = paneID
        }

        // UI palette edits stay in the native hosting tree. Only the existing
        // font and light/dark settings may reconfigure this retained renderer.
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
                                 pane: paneID, cols: cols, rows: rows, serverProtocol: store.protocolVersion)
            } else {
                controller.resize(cols: cols, rows: rows)
            }
        }

        func focusIfSelected() {
            guard !stopped, visible, !searching, let view, !view.isHiddenOrHasHiddenAncestor, let store, store.selectedPane == paneID,
                  store.sheet == nil, store.pendingClose == nil else { return }
            view.acquireProgrammaticFocus()
        }

        private var focusObservers: [NSObjectProtocol] = []

        func syncInputFocus() {
            guard !stopped, let view else { controller.setFocused(false); return }
            controller.setFocused(visible && !searching && !view.isHiddenOrHasHiddenAncestor
                && view.window?.isKeyWindow == true && view.window?.firstResponder === view)
        }

        func installEvents() {
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
                focusObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                    MainActor.assumeIsolated {
                        guard let self, let window = notification.object as? NSWindow,
                              window === self.view?.window else { return }
                        self.syncInputFocus()
                    }
                })
            }
            // Herdr owns the scrollback represented by its ANSI frames. Keep
            // wheel scrolling on the server, while Ghostty handles keys/mouse.
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .leftMouseDown]) { [weak self] event in
                guard let self, !self.stopped, self.visible, !self.searching, let view = self.view, !view.isHiddenOrHasHiddenAncestor,
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
            focusObservers.forEach { NotificationCenter.default.removeObserver($0) }
            focusObservers.removeAll()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        func terminalDidAttachSurface(_ surface: GhosttyTerminal.TerminalSurface) {
            surfaceAttached = true
            DispatchQueue.main.async { [weak self] in self?.focusIfSelected() }
        }
        func terminalDidDetachSurface() {
            surfaceAttached = false
            view?.cancelFileDrop()
        }
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
    var onFocusChanged: (() -> Void)?
    var onRetainedTabVisibility: ((Bool, String?) -> Void)?
    var canAcceptFileDrop: () -> Bool = { false }
    var resolveFileDrop: (([URL]) async throws -> PreparedFileDrop)?
    var onFileDropError: ((Error) -> Void)?
    private var fileDropTask: Task<Void, Never>?
    private var fileDropGeneration = UUID()
    private var surfaceVisible = true
    private var plainLinkClick = false
    private var capturedLinkClick: (url: String, event: NSEvent)?
    private var capturedLinkDragged = false

    override func mouseDown(with event: NSEvent) {
        capturedLinkClick = nil
        capturedLinkDragged = false
        if isMouseCaptured, event.clickCount == 1,
           event.modifierFlags.isDisjoint(with: [.shift, .control, .option]) {
            // Shift bypasses application capture; Command enables Ghostty's
            // URL/OSC 8 matcher. Probe before sending a press so a link cannot
            // leave the application with half of a mouse click.
            updateLinkPointer(event, modifiers: [.shift, .super_])
            if let url = hoveredLink {
                plainLinkClick = false
                capturedLinkClick = (url, event)
                window?.makeFirstResponder(self)
                return
            }
            updateLinkPointer(event, modifiers: TerminalInputModifiers(from: event.modifierFlags))
        }
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
        if let click = capturedLinkClick {
            if !capturedLinkDragged {
                // Start selection only once this becomes a drag. A synthetic
                // Shift press on a click would extend an existing selection
                // and make Ghostty misclassify the click as a drag.
                updateLinkPointer(click.event, modifiers: .shift)
                sendMouseButton(state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_LEFT,
                                modifiers: .shift)
            }
            capturedLinkDragged = true
            let point = convert(event.locationInWindow, from: nil)
            sendMousePos(x: point.x, y: bounds.height - point.y, modifiers: .shift)
            return
        }
        plainLinkClick = false
        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        if let click = capturedLinkClick {
            capturedLinkClick = nil
            if capturedLinkDragged {
                let point = convert(event.locationInWindow, from: nil)
                sendMousePos(x: point.x, y: bounds.height - point.y, modifiers: .shift)
                sendMouseButton(state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_LEFT,
                                modifiers: .shift)
            } else if event.modifierFlags.isDisjoint(with: [.shift, .control, .option]) {
                updateLinkPointer(event, modifiers: [.shift, .super_])
                if hoveredLink == click.url {
                    (delegate as? any TerminalSurfaceOpenURLDelegate)?
                        .terminalDidRequestOpenURL(click.url, kind: .text)
                }
            }
            updateLinkPointer(event, modifiers: TerminalInputModifiers(from: event.modifierFlags))
            return
        }
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

    private func updateLinkPointer(_ event: NSEvent, modifiers: TerminalInputModifiers) {
        let point = convert(event.locationInWindow, from: nil)
        sendMousePos(x: -1, y: -1, modifiers: modifiers)
        sendMousePos(x: point.x, y: bounds.height - point.y, modifiers: modifiers)
    }

    override var acceptsFirstResponder: Bool { surfaceVisible }

    override func becomeFirstResponder() -> Bool {
        guard surfaceVisible else { return false }
        let accepted = super.becomeFirstResponder()
        DispatchQueue.main.async { [weak self] in self?.onFocusChanged?() }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        DispatchQueue.main.async { [weak self] in self?.onFocusChanged?() }
        return accepted
    }

    override func setSurfaceVisible(_ visible: Bool) {
        if !visible { cancelFileDrop() }
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
        clipboardPasteHandler = { [weak self] in self?.pasteClipboardFiles() ?? false }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        fileDropURLs(sender) == nil ? [] : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingEntered(sender)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        fileDropURLs(sender) != nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = fileDropURLs(sender) else { return false }
        return insertFiles(urls)
    }

    private func pasteClipboardFiles() -> Bool {
        let board = NSPasteboard.general
        guard TerminalClipboardFiles.hasFiles(board) else { return false }
        // Consume rejected file pastes, so Ghostty cannot fall back to a
        // local path on a remote host or paste into a hidden/busy pane.
        guard canInsertFiles else { NSSound.beep(); return true }
        do {
            let files = try TerminalClipboardFiles.read(board)
            if !insertFiles(files.urls, individually: true, staging: files.directory) {
                files.discard()
            }
        } catch { onFileDropError?(error) }
        return true
    }

    private var canInsertFiles: Bool {
        fileDropTask == nil && surfaceVisible && canAcceptFileDrop() && controller != nil
            && window != nil && !isHiddenOrHasHiddenAncestor
    }

    private func insertFiles(_ urls: [URL], individually: Bool = false, staging: URL? = nil) -> Bool {
        guard !urls.isEmpty, urls.allSatisfy({
            $0.isFileURL && !$0.path.isEmpty && $0.path.rangeOfCharacter(from: .controlCharacters) == nil
        }) else { return false }
        guard let resolveFileDrop else {
            guard insertFilePaths(urls.map(\.path), individually: individually) else { return false }
            acquireProgrammaticFocus()
            return true
        }
        acquireProgrammaticFocus()
        fileDropGeneration = UUID()
        let token = fileDropGeneration
        fileDropTask = Task { [weak self] in
            defer {
                if let self, self.fileDropGeneration == token { self.fileDropTask = nil }
            }
            var files: PreparedFileDrop?
            do {
                let prepared = try await resolveFileDrop(urls)
                files = prepared
                try Task.checkCancellation()
                guard let self, self.fileDropGeneration == token else { throw CancellationError() }
                guard self.canAcceptFileDrop(), self.surfaceVisible, self.window != nil,
                      !self.isHiddenOrHasHiddenAncestor, self.controller != nil else {
                    throw HerdrError.message("The pane is no longer ready to paste. Close any dialog or search, then drop the files again.")
                }
                guard !prepared.paths.isEmpty, prepared.paths.allSatisfy({ !$0.isEmpty && $0.rangeOfCharacter(from: .controlCharacters) == nil }),
                      self.insertFilePaths(prepared.paths, individually: individually) else {
                    throw HerdrError.message("The terminal could not accept the uploaded paths.")
                }
                // Remote copies own their bytes now; local drafts still need
                // the staged files until the harness consumes the attachment.
                if prepared.paths != urls.map(\.path), let staging {
                    try? FileManager.default.removeItem(at: staging)
                }
            } catch {
                await files?.discard()
                if let staging { try? FileManager.default.removeItem(at: staging) }
                guard let self, self.fileDropGeneration == token else { return }
                if !(error is CancellationError), !Task.isCancelled { self.onFileDropError?(error) }
            }
        }
        return true
    }

    private func insertFilePaths(_ paths: [String], individually: Bool) -> Bool {
        // A harness recognizes one image path per paste event. Combining
        // paths turns the whole batch into ordinary prompt text.
        let batches = individually ? paths.map { [$0] } : [paths]
        return batches.allSatisfy { paste(text: Self.fileDropText($0)) }
    }

    func cancelFileDrop() {
        fileDropGeneration = UUID()
        fileDropTask?.cancel()
        fileDropTask = nil
    }

    private func fileDropURLs(_ sender: NSDraggingInfo) -> [URL]? {
        guard canInsertFiles,
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
        return urls
    }

    private static func fileDropText(_ paths: [String]) -> String {
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
            .custom("mouse-shift-capture", "never")
            .custom("clipboard-read", "deny")
            .custom("clipboard-write", "allow")
            // The embedded wrapper discards selection-clipboard writes.
            .custom("copy-on-select", "clipboard")
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
