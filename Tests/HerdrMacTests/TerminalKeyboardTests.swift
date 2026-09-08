import AppKit
import GhosttyTerminal
@testable import HerdrMac

@main
struct TerminalKeyboardTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        setbuf(stdout, nil)
        if CommandLine.arguments.contains("--bundled-resources") {
            for url in [GhosttyRuntimeResources.directoryURL, GhosttyRuntimeResources.terminfoDirectoryURL] {
                precondition(url?.path.hasPrefix(Bundle.main.bundleURL.path + "/Contents/Resources/") == true,
                             "Resources must resolve inside the packaged app, not the build directory")
            }
            print("PASS: packaged Ghostty resources resolve inside the app")
            return
        }
        func waitUntil(_ predicate: () -> Bool) {
            let deadline = Date().addingTimeInterval(3)
            while !predicate(), Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            }
        }
        let capture = StreamCapture()
        let bridge = GhosttyStreamBridge(input: { capture.append($0) }, resize: { capture.resize($0) })
        let engine = GhosttyTerminal.TerminalController(configuration: HerdrTerminalView.baseConfiguration)
        let view = HerdrTerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 360))
        let lifecycle = SurfaceCapture()
        view.delegate = lifecycle
        view.configuration = TerminalSurfaceOptions(backend: .inMemory(bridge.session))
        view.controller = engine
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        defer {
            view.controller = nil
            window.orderOut(nil)
        }
        precondition(lifecycle.surface != nil, "Ghostty surface must attach")
        precondition(engine.lastConfigurationIssue == nil, engine.lastConfigurationIssue ?? "")
        bridge.receive(Data("Ghostty café 世界\r\n".utf8))
        bridge.session.waitForPendingOutput()
        precondition(bridge.session.readViewportText()?.contains("Ghostty café 世界") == true)
        print("PASS: real Ghostty surface renders UTF-8 output")
        precondition(capture.viewport.map { $0.columns > 1 && $0.rows > 1 } == true)
        let originalColumns = capture.viewport!.columns
        window.setContentSize(NSSize(width: 900, height: 480))
        view.fitToSize()
        waitUntil { capture.viewport!.columns > originalColumns }
        precondition(capture.viewport!.columns > originalColumns)
        print("PASS: resizing reports the actual terminal grid")

        func check(_ label: String, keyCode: UInt16 = 36, modifiers: NSEvent.ModifierFlags,
                   repeatPress: Bool = false, type: NSEvent.EventType = .keyDown, expected: String) {
            capture.clear()
            let characters = keyCode == 76 ? "\u{3}" : "\r"
            let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers,
                                        timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: window.windowNumber, context: nil,
                                        characters: characters, charactersIgnoringModifiers: characters,
                                        isARepeat: repeatPress, keyCode: keyCode)!
            NSApp.sendEvent(event)
            if !expected.isEmpty { waitUntil { capture.bytes == Array(expected.utf8) } }
            precondition(capture.bytes == Array(expected.utf8),
                         "\(label): expected \(Array(expected.utf8)), got \(capture.bytes)")
            print("PASS: \(label)")
        }
        check("Shift-Return stays distinct from submit", modifiers: .shift, expected: "\u{1b}[13;2u")
        check("Shift-keypad-Enter stays distinct from submit", keyCode: 76,
              modifiers: [.shift, .numericPad], expected: "\u{1b}[13;2u")
        check("Caps Lock does not disable Shift-Return", modifiers: [.shift, .capsLock], expected: "\u{1b}[13;2u")
        check("held Shift-Return repeats newlines", modifiers: .shift, repeatPress: true, expected: "\u{1b}[13;2u")
        check("plain Return still submits", modifiers: [], expected: "\r")
        check("plain keypad Enter still submits", keyCode: 76, modifiers: .numericPad, expected: "\r")
        check("Option-Return retains its encoding", modifiers: .option, expected: "\u{1b}\r")
        check("legacy Shift-Return release sends nothing", modifiers: .shift, type: .keyUp, expected: "")

        capture.clear()
        bridge.receive(Data("\u{1b}[6n\u{1b}[c".utf8))
        bridge.session.waitForPendingOutput()
        precondition(capture.bytes.isEmpty, "Server frames must not echo terminal query replies into the shell")
        check("keyboard input still works after query suppression", modifiers: [], expected: "\r")

        bridge.receive(Data("\u{1b}[?2004h".utf8))
        bridge.session.waitForPendingOutput()
        capture.clear()
        precondition(view.paste(text: "paste café"))
        waitUntil { capture.bytes == Array("\u{1b}[200~paste café\u{1b}[201~".utf8) }
        precondition(capture.bytes == Array("\u{1b}[200~paste café\u{1b}[201~".utf8))
        print("PASS: explicit paste honors bracketed paste")

        let dropBoard = NSPasteboard.withUniqueName()
        defer { dropBoard.releaseGlobally() }
        let droppedFiles = [URL(fileURLWithPath: "/tmp/project notes.txt"),
                            URL(fileURLWithPath: "/tmp/it's $draft; café.png")]
        precondition(dropBoard.writeObjects(droppedFiles as [NSURL]))
        let drop = FileDragInfo(pasteboard: dropBoard, window: window)
        view.canAcceptFileDrop = { true }
        precondition(view.registeredDraggedTypes.contains(.fileURL), "Terminal must register for file drops")
        capture.clear()
        precondition(view.draggingEntered(drop) == .copy, "Files must be accepted without sending input on hover")
        precondition(capture.bytes.isEmpty)
        precondition(view.prepareForDragOperation(drop))
        precondition(view.performDragOperation(drop))
        let expectedDrop = "\u{1b}[200~'/tmp/project notes.txt' '/tmp/it'\\''s $draft; cafe\u{301}.png' \u{1b}[201~"
        waitUntil { capture.bytes == Array(expectedDrop.utf8) }
        precondition(capture.bytes == Array(expectedDrop.utf8), "Drop must paste quoted file paths without submitting: \(String(decoding: capture.bytes, as: UTF8.self).debugDescription)")
        print("PASS: multiple file drops preserve quoting, Unicode, and bracketed paste")

        view.canAcceptFileDrop = { false }
        capture.clear()
        precondition(view.draggingUpdated(drop).isEmpty)
        precondition(!view.prepareForDragOperation(drop))
        precondition(!view.performDragOperation(drop))
        precondition(capture.bytes.isEmpty, "Unavailable panes must reject drops")
        view.canAcceptFileDrop = { true }
        drop.draggingSourceOperationMask = .move
        precondition(view.draggingEntered(drop).isEmpty, "Drops must never move source files")
        precondition(!view.performDragOperation(drop))
        drop.draggingSourceOperationMask = .copy

        dropBoard.clearContents()
        dropBoard.setString("https://example.com", forType: .string)
        capture.clear()
        precondition(view.draggingEntered(drop).isEmpty)
        precondition(!view.performDragOperation(drop))
        precondition(capture.bytes.isEmpty, "Unsupported drops must not send input")

        dropBoard.clearContents()
        dropBoard.writeObjects([URL(fileURLWithPath: "/tmp/bad\nname.txt") as NSURL])
        precondition(view.draggingEntered(drop).isEmpty, "Control characters in paths must not reach terminal input")
        precondition(!view.performDragOperation(drop))
        print("PASS: text and control-character file drops are rejected")

        bridge.receive(Data("\u{1b}[>1u".utf8))
        bridge.session.waitForPendingOutput()
        check("negotiated Shift-Return", modifiers: .shift, expected: "\u{1b}[13;2u")
        bridge.receive(Data("\u{1b}[<u".utf8))
        bridge.session.waitForPendingOutput()

        let oldSurface = lifecycle.surface
        engine.setTerminalConfiguration(TerminalConfiguration().fontSize(18))
        view.fitToSize()
        precondition(lifecycle.surface === oldSurface, "Font settings must not recreate a live terminal")
        precondition(bridge.session.readViewportText()?.contains("Ghostty café 世界") == true)
        print("PASS: font changes preserve rendered content and surface")

        let other = HerdrTerminalView(frame: view.frame)
        let otherCapture = StreamCapture()
        let otherBridge = GhosttyStreamBridge(input: { otherCapture.append($0) }, resize: { _ in })
        other.configuration = TerminalSurfaceOptions(backend: .inMemory(otherBridge.session))
        other.controller = engine
        view.addSubview(other)
        window.makeFirstResponder(view)
        check("only focused pane receives Shift-Return", modifiers: .shift, expected: "\u{1b}[13;2u")
        precondition(otherCapture.bytes.isEmpty)
        dropBoard.clearContents()
        dropBoard.writeObjects([URL(fileURLWithPath: "/tmp/picture.png") as NSURL])
        capture.clear()
        other.canAcceptFileDrop = { true }
        precondition(other.draggingEntered(drop) == .copy)
        precondition(window.firstResponder === view, "Hovering must not change keyboard focus")
        precondition(other.performDragOperation(drop))
        let otherExpected = Array("'/tmp/picture.png' ".utf8)
        waitUntil { otherCapture.bytes == otherExpected }
        precondition(otherCapture.bytes == otherExpected, "Drop must reach its target even without bracketed paste")
        precondition(capture.bytes.isEmpty, "Previously focused pane must receive no drop input")
        precondition(window.firstResponder === other, "Dropping must focus the target pane")
        print("PASS: drops target and focus the receiving pane without submitting")
        other.controller = nil
        precondition(!other.performDragOperation(drop), "Detached surfaces must reject drops")
        other.removeFromSuperview()
        lifecycle.surface = nil
        view.controller = nil
        precondition(bridge.session.readViewportText() == nil)
        print("PASS: detaching releases the Ghostty surface")
        if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--live" {
            var finished = false
            Task { @MainActor in
                do {
                    try await GhosttyLiveTests.run(socket: CommandLine.arguments[2], executable: CommandLine.arguments[3])
                    finished = true
                } catch {
                    print("FAIL: live Ghostty integration: \(error)")
                    exit(1)
                }
            }
            let deadline = Date().addingTimeInterval(45)
            while !finished, Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            }
            precondition(finished, "Live Ghostty integration timed out")
        }
    }
}

private final class StreamCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var data: [UInt8] = []
    private var size: InMemoryTerminalViewport?
    var bytes: [UInt8] { lock.withLock { data } }
    var viewport: InMemoryTerminalViewport? { lock.withLock { size } }
    func append(_ value: Data) { lock.withLock { data.append(contentsOf: value) } }
    func resize(_ value: InMemoryTerminalViewport) { lock.withLock { size = value } }
    func clear() { lock.withLock { data = [] } }
}

@MainActor
private final class SurfaceCapture: TerminalSurfaceLifecycleDelegate {
    var surface: GhosttyTerminal.TerminalSurface?
    func terminalDidAttachSurface(_ surface: GhosttyTerminal.TerminalSurface) { self.surface = surface }
    func terminalDidDetachSurface() { surface = nil }
}

// AppKit supplies this object during a drag; the pasteboard and terminal are real.
@MainActor
private final class FileDragInfo: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    let draggingDestinationWindow: NSWindow?
    var draggingSourceOperationMask: NSDragOperation = .copy
    var draggingLocation: NSPoint = .zero
    var draggedImageLocation: NSPoint = .zero
    nonisolated var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 0
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }

    init(pasteboard: NSPasteboard, window: NSWindow) {
        draggingPasteboard = pasteboard
        draggingDestinationWindow = window
    }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    nonisolated override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func resetSpringLoading() {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [],
                                for view: NSView?, classes classArray: [AnyClass],
                                searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}
