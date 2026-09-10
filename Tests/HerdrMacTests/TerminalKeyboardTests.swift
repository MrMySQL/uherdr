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

        // App shortcuts must reach the menu before Ghostty's own bindings.
        let previousMenu = NSApp.mainMenu
        let shortcutMenu = NSMenu()
        shortcutMenu.autoenablesItems = false
        let shortcutTarget = ShortcutTarget()
        NSApp.mainMenu = shortcutMenu
        let shortcuts: [(String, NSEvent.ModifierFlags, UInt16)] = [
            ("1", .control, 18), ("2", .control, 19), ("3", .control, 20),
            ("4", .control, 21), ("5", .control, 23), ("6", .control, 22),
            ("7", .control, 26), ("8", .control, 28), ("9", .control, 25),
            ("=", .command, 24), ("+", [.command, .shift], 24), ("-", .command, 27),
            ("[", .command, 33), ("]", .command, 30),
            ("[", [.command, .shift], 33), ("]", [.command, .shift], 30),
            ("`", .control, 50),
        ]
        for (key, modifiers, keyCode) in shortcuts {
            shortcutMenu.removeAllItems()
            let item = NSMenuItem(title: "App shortcut", action: #selector(ShortcutTarget.invoke(_:)), keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.target = shortcutTarget
            shortcutMenu.addItem(item)
            shortcutTarget.invocations = 0
            capture.clear()
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                        timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: window.windowNumber, context: nil,
                                        characters: key, charactersIgnoringModifiers: key,
                                        isARepeat: false, keyCode: keyCode)!
            NSApp.sendEvent(event)
            precondition(shortcutTarget.invocations == 1, "App shortcut \(key) must invoke the menu exactly once")
            precondition(capture.bytes.isEmpty, "App shortcut \(key) must not send terminal input")
        }
        NSApp.mainMenu = previousMenu
        print("PASS: tab, pane, and text size shortcuts reach app menus from the terminal")

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
        // Exercise real mouse events and Ghostty matching, intercepting only
        // the external URL delegate so the test does not launch a browser.
        func linkClick(_ output: String, modifiers: NSEvent.ModifierFlags = [],
                       drag: Bool = false, clickCount: Int = 1, column: CGFloat = 2.5,
                       dragBack: Bool = true, redraw: Bool = true, row: CGFloat = 0.5) {
            if redraw { bridge.receive(Data(("\u{1b}[2J\u{1b}[H" + output).utf8)) }
            bridge.session.waitForPendingOutput()
            lifecycle.urls = []
            let grid = capture.viewport!
            let scale = window.backingScaleFactor
            // Font-only resize callbacks can omit cell dimensions. This
            // fixture has zero padding, so derive them from its pixel grid.
            let cellWidth = grid.cellWidthPixels > 0 ? grid.cellWidthPixels : grid.widthPixels / UInt32(grid.columns)
            let cellHeight = grid.cellHeightPixels > 0 ? grid.cellHeightPixels : grid.heightPixels / UInt32(grid.rows)
            precondition(cellWidth > 0 && cellHeight > 0)
            let point = NSPoint(x: CGFloat(cellWidth) * column / scale,
                                y: view.bounds.height - CGFloat(cellHeight) * row / scale)
            func event(_ type: NSEvent.EventType, at point: NSPoint) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil),
                                   modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: window.windowNumber, context: nil,
                                   eventNumber: 0, clickCount: clickCount, pressure: 0)!
            }
            view.mouseMoved(with: event(.mouseMoved, at: NSPoint(x: -1, y: -1)))
            view.mouseMoved(with: event(.mouseMoved, at: point))
            view.mouseDown(with: event(.leftMouseDown, at: point))
            if drag {
                view.mouseDragged(with: event(.leftMouseDragged, at: NSPoint(x: point.x + 60, y: point.y)))
                if dragBack { view.mouseDragged(with: event(.leftMouseDragged, at: point)) }
            }
            view.mouseUp(with: event(.leftMouseUp, at: drag && !dragBack
                                    ? NSPoint(x: point.x + 60, y: point.y) : point))
        }
        let url = "https://example.com/agent?task=123&view=diff"
        linkClick(url)
        precondition(lifecycle.urls == [url], "Plain click must open a detected URL")
        linkClick(url, modifiers: .command)
        precondition(lifecycle.urls == [url], "Command-click must reach the URL opener exactly once")
        linkClick("\u{1b}]8;;\(url)\u{1b}\\Agent link\u{1b}]8;;\u{1b}\\")
        precondition(lifecycle.urls == [url], "Plain click must open an OSC 8 destination, not its label")
        linkClick("ordinary terminal text")
        precondition(lifecycle.urls.isEmpty, "Plain text must not open a URL")
        linkClick(url, drag: true)
        precondition(lifecycle.urls.isEmpty, "Dragging over a link and back must not open it")
        linkClick(url, modifiers: .shift)
        precondition(lifecycle.urls.isEmpty, "Shift-click must retain selection behavior")
        linkClick(url, clickCount: 2)
        precondition(lifecycle.urls.isEmpty, "Double-click must retain word selection")
        capture.clear()
        linkClick("\u{1b}[?1000h\u{1b}[?1006h" + url, modifiers: .command)
        precondition(lifecycle.urls == [url], "Command-click must open links while an application captures the mouse")
        linkClick(url)
        precondition(lifecycle.urls == [url], "Plain click must open links while an application captures the mouse")
        linkClick("\u{1b}]8;;\(url)\u{1b}\\Agent link\u{1b}]8;;\u{1b}\\")
        precondition(lifecycle.urls == [url], "Captured OSC 8 links must open their destination")
        linkClick(url, drag: true)
        precondition(lifecycle.urls.isEmpty, "Dragging a captured link and returning must not open it")
        // A subsequent key acts as a barrier for Ghostty's asynchronous input
        // writer, so a delayed stray press/release cannot escape this check.
        precondition(view.sendKey(.enter))
        waitUntil { capture.bytes.last == 13 }
        precondition(capture.bytes == [13],
                     "Link clicks and drags must not send partial mouse gestures to the application: \(capture.bytes)")
        linkClick("Select this text    " + url, modifiers: .shift, drag: true, column: 0.5, dragBack: false)
        RunLoop.current.run(until: Date().addingTimeInterval(NSEvent.doubleClickInterval + 0.1))
        linkClick("", column: 24.5, redraw: false)
        precondition(lifecycle.urls == [url], "An existing text selection must not prevent a later captured link click")
        linkClick("Heading\r\n\r\n    " + url, column: 8.5, row: 2.5)
        precondition(lifecycle.urls == [url], "Captured links must open away from the first row and column")
        capture.clear()
        linkClick("Expand tool output", column: 0.5)
        precondition(lifecycle.urls.isEmpty, "Applications capturing the mouse must retain their clicks")
        let expectedClick = Array("\u{1b}[<0;1;1M\u{1b}[<0;1;1m".utf8)
        waitUntil { capture.bytes == expectedClick }
        precondition(capture.bytes == expectedClick,
                     "Mouse-enabled apps must receive an unmodified press and release at the clicked cell: \(capture.bytes)")
        for mode in [1002, 1003] {
            linkClick("\u{1b}[?1000l\u{1b}[?\(mode)h" + url)
            precondition(lifecycle.urls == [url], "Link clicks must work with mouse motion mode \(mode)")
            linkClick(url, drag: true)
            precondition(lifecycle.urls.isEmpty, "Dragging must not open a link with mouse motion mode \(mode)")
            bridge.receive(Data("\u{1b}[?\(mode)l".utf8))
            bridge.session.waitForPendingOutput()
        }
        bridge.receive(Data("\u{1b}[?1000l\u{1b}[?1006l".utf8))
        bridge.session.waitForPendingOutput()
        capture.clear()
        linkClick("ordinary terminal text")
        precondition(capture.bytes.isEmpty, "Disabling mouse capture must restore local selection without sending mouse input")
        print("PASS: terminal URL clicks preserve destinations, selection, and mouse capture")
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

@MainActor
private final class ShortcutTarget: NSObject {
    var invocations = 0
    @objc func invoke(_ sender: NSMenuItem) { invocations += 1 }
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
private final class SurfaceCapture: TerminalSurfaceLifecycleDelegate, TerminalSurfaceOpenURLDelegate {
    var surface: GhosttyTerminal.TerminalSurface?
    var urls: [String] = []
    func terminalDidRequestOpenURL(_ url: String, kind: TerminalOpenURLKind) { urls.append(url) }
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
