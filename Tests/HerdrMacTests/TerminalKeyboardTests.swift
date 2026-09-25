import AppKit
import GhosttyTerminal
import HerdrCore
@testable import HerdrMac

@main
struct TerminalKeyboardTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        setbuf(stdout, nil)
        if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--agent-drops" {
            var finished = false
            var failure: Error?
            let test = Task { @MainActor in
                defer { finished = true }
                do {
                    try await AgentFileDropTests.run(socket: CommandLine.arguments[2], executable: CommandLine.arguments[3])
                } catch { failure = error }
            }
            let deadline = Date().addingTimeInterval(900)
            while !finished, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
            if !finished {
                test.cancel()
                let cleanupDeadline = Date().addingTimeInterval(15)
                while !finished, Date() < cleanupDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
                print("FAIL: agent file drops exceeded the 15-minute deadline")
                exit(1)
            }
            if let failure { print("FAIL: agent file drops: \(failure)"); exit(1) }
            return
        }
        if CommandLine.arguments.contains("--bundled-resources") {
            for url in [GhosttyRuntimeResources.directoryURL, GhosttyRuntimeResources.terminfoDirectoryURL] {
                precondition(url?.path.hasPrefix(Bundle.main.bundleURL.path + "/Contents/Resources/") == true,
                             "Resources must resolve inside the packaged app, not the build directory")
            }
            print("PASS: packaged Ghostty resources resolve inside the app")
            return
        }
        checkPastePackets()
        let draftArgs = (textReference: "/tmp/drop/it's café.txt", imageReference: "/tmp/drop/sample image.png", pathPrefix: "/tmp/drop")
        func containsFiles(_ draft: String) -> Bool {
            AgentFileDropTests.draftContainsDroppedFiles(draft, textReference: draftArgs.textReference,
                imageReference: draftArgs.imageReference, pathPrefix: draftArgs.pathPrefix)
        }
        precondition(!containsFiles("codex -C /tmp/drop"), "Startup cwd must not satisfy attachment readiness")
        precondition(!containsFiles("'/tmp/drop/it's café.txt'"), "Both attachments must reach the draft")
        precondition(containsFiles("'/tmp/drop/it'\\\n''s cafe\u{301}.txt' '/tmp/drop/sample\n image.png'"),
                     "Draft matching must handle quoted apostrophes, wrapping and Unicode composition")
        precondition(containsFiles("'/tmp/drop/it's café.txt' [Image #1]"))
        print("PASS: agent drop readiness requires both files and handles terminal formatting")
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
        // Ghostty's contrast correction replaces failing foregrounds with black
        // or white; it does not preserve their hue. These independently computed
        // WCAG ratios cover actual Claude RGB output on our light background,
        // plus near-invisible text that still needs correction in either theme.
        let contrastLine = engine.renderedConfig.split(separator: "\n").last {
            $0.hasPrefix("minimum-contrast = ")
        }!
        let minimumContrast = Double(contrastLine.split(separator: "=")[1]
            .trimmingCharacters(in: .whitespaces))!
        for (label, ratio, shouldCorrect) in [
            ("Claude green #4eba65 on #fafaf7", 2.3528, false),
            ("Claude lavender #b1b9f9 on #fafaf7", 1.7967, false),
            ("Claude gray #999999 on #fafaf7", 2.7245, false),
            ("white on the light terminal background", 1.0457, true),
            ("default dark text on Claude's #373737 input", 1.2513, true),
            ("#101010 on the dark terminal background", 1.0042, true)
        ] {
            guard (ratio < minimumContrast) == shouldCorrect else {
                print("FAIL: terminal contrast policy changes \(label) incorrectly (threshold \(minimumContrast))")
                exit(1)
            }
        }
        print("PASS: terminal contrast preserves agent colors and corrects nearly invisible text")
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

        // Herdr blits absolute screen cells with host autowrap disabled.
        // An in-flight frame can still use the previous, wider grid during
        // resize. It must not wrap into the next row or scroll the viewport.
        let columns = Int(capture.viewport!.columns)
        let rows = Int(capture.viewport!.rows)
        bridge.receive(Data(("\u{1b}[2J\u{1b}[Htop-anchor"
            + "\u{1b}[2;1H" + String(repeating: "x", count: columns + 5)
            + "\u{1b}[\(rows);1H" + String(repeating: "y", count: columns + 5)
            + "\u{1b}[H").utf8))
        bridge.session.waitForPendingOutput()
        let frameRows = bridge.session.readViewportText()!.components(separatedBy: "\n")
        precondition(frameRows[0].trimmingCharacters(in: .whitespaces) == "top-anchor",
                     "An overwide server frame must not scroll away the top row")
        precondition(frameRows[2].trimmingCharacters(in: .whitespaces).isEmpty,
                     "An overwide server frame must not leave wrapped fragments on the next row")
        print("PASS: overwide server frames neither wrap nor scroll during resize")
        bridge.receive(Data("\u{1b}[2J\u{1b}[HGhostty café 世界\r\n".utf8))
        bridge.session.waitForPendingOutput()

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
            ("f", .command, 3), ("g", .command, 5), ("g", [.command, .shift], 5),
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
        checkClipboardFiles(view: view, capture: capture, waitUntil: waitUntil)

        // A paste larger than native input buffers must preserve every byte,
        // including its opening/closing bracket and the final two lines.
        let longPaste = (1...400).map { "line \($0): café 世界 " + String(repeating: "x", count: 80) }.joined(separator: "\n")
            + "\nPENULTIMATE-LINE\nFINAL-LINE"
        let longExpected = Array(("\u{1b}[200~" + longPaste + "\u{1b}[201~").utf8)
        capture.clear()
        precondition(view.paste(text: longPaste))
        waitUntil { capture.bytes.count >= longExpected.count }
        precondition(capture.bytes == longExpected,
                     "Long paste lost bytes: expected \(longExpected.count), received \(capture.bytes.count)")
        precondition(capture.packets == [Data(longExpected)], "Herdr requires one complete paste packet; got callback sizes \(capture.packets.map(\.count))")
        print("PASS: long multiline Unicode paste preserves all bytes and both final lines")

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

        // A remote drop must wait for upload completion and paste its returned
        // path through Ghostty, preserving bracketed paste and never submitting.
        capture.clear()
        var finishUpload: CheckedContinuation<PreparedFileDrop, Error>?
        var discardedDrops = 0
        func prepared(_ paths: [String]) -> PreparedFileDrop {
            PreparedFileDrop(paths: paths, discard: { discardedDrops += 1 })
        }
        var uploadError: String?
        view.resolveFileDrop = { urls in
            precondition(urls == droppedFiles)
            return try await withCheckedThrowingContinuation { finishUpload = $0 }
        }
        view.onFileDropError = { uploadError = $0.localizedDescription }
        precondition(view.performDragOperation(drop))
        waitUntil { finishUpload != nil }
        precondition(capture.bytes.isEmpty, "Local paths must never be pasted while uploading")
        precondition(!view.performDragOperation(drop), "Concurrent drops must not reorder uploads")
        finishUpload!.resume(returning: prepared(["/tmp/remote/project notes.txt"]))
        finishUpload = nil
        waitUntil { !capture.bytes.isEmpty }
        precondition(String(decoding: capture.bytes, as: UTF8.self) == "\u{1b}[200~'/tmp/remote/project notes.txt' \u{1b}[201~")
        precondition(uploadError == nil)
        precondition(discardedDrops == 0, "Accepted uploads must remain available to the agent")

        capture.clear()
        precondition(view.performDragOperation(drop))
        waitUntil { finishUpload != nil }
        finishUpload!.resume(throwing: NSError(domain: "upload", code: 1))
        finishUpload = nil
        waitUntil { uploadError != nil }
        precondition(capture.bytes.isEmpty, "Failed uploads must not paste a local or partial path")

        uploadError = nil
        precondition(view.performDragOperation(drop))
        waitUntil { finishUpload != nil }
        view.canAcceptFileDrop = { false }
        var finishDiscard: CheckedContinuation<Void, Never>?
        finishUpload!.resume(returning: PreparedFileDrop(paths: ["/tmp/remote/ready.txt"], discard: {
            await withCheckedContinuation { finishDiscard = $0 }
            discardedDrops += 1
        }))
        finishUpload = nil
        waitUntil { finishDiscard != nil }
        view.canAcceptFileDrop = { true }
        precondition(!view.performDragOperation(drop), "Cleanup must retain ownership until the previous drop has finished")
        finishDiscard!.resume()
        waitUntil { uploadError != nil }
        precondition(uploadError != nil && capture.bytes.isEmpty, "A completed upload must report when a dialog prevents pasting")
        precondition(discardedDrops == 1, "A refused paste must discard its completed upload")
        view.canAcceptFileDrop = { true }

        precondition(view.performDragOperation(drop))
        waitUntil { finishUpload != nil }
        view.setSurfaceVisible(false)
        view.setSurfaceVisible(true)
        finishUpload!.resume(returning: prepared(["/tmp/remote/stale.txt"]))
        finishUpload = nil
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        precondition(capture.bytes.isEmpty, "Hiding and showing a pane must invalidate an in-flight drop")
        precondition(discardedDrops == 2, "A stale completed upload must be discarded")
        view.resolveFileDrop = nil
        view.onFileDropError = nil
        view.acquireProgrammaticFocus()
        print("PASS: remote drops wait for upload, reject duplicates, report failures and discard stale completion")

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
        // Keep the real coordinator and Ghostty click path; intercept only the
        // OS calls so this test cannot launch Finder or a browser.
        let fileRoot = FileManager.default.temporaryDirectory.appendingPathComponent("herdr-links-\(UUID())")
        try! FileManager.default.createDirectory(at: fileRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fileRoot) }
        let file = fileRoot.appendingPathComponent("it's café #1.txt")
        try! Data("link fixture".utf8).write(to: file)
        let workspace = LinkWorkspace()
        let localStore = SessionStore(profile: DeviceProfile(name: "Local links", kind: .local,
            socketPath: "/tmp/unused-links.sock", executable: "/usr/bin/false"))
        let linkCoordinator = TerminalSurface.Coordinator(controller: HerdrMac.TerminalController(),
            store: localStore, paneID: "link-test", workspace: workspace)
        view.delegate = linkCoordinator
        let fileLink = "\u{1b}]8;;\(file.absoluteString)\u{1b}\\Linked file\u{1b}]8;;\u{1b}\\"
        for mouseCaptured in [false, true] {
            bridge.receive(Data((mouseCaptured ? "\u{1b}[?1000h\u{1b}[?1006h" : "\u{1b}[?1000l\u{1b}[?1006l").utf8))
            for modifiers: NSEvent.ModifierFlags in [[], .command] {
                workspace.revealed = []
                linkClick(fileLink, modifiers: modifiers)
                precondition(workspace.revealed.map(\.path) == [file.path],
                             "File hyperlinks must reveal the decoded file in Finder (capture: \(mouseCaptured))")
                precondition(workspace.opened.isEmpty, "File hyperlinks must not launch their associated app")
            }
            workspace.revealed = []
            linkClick(fileLink, drag: true)
            precondition(workspace.revealed.isEmpty, "Dragging a file link must select text without opening Finder")
        }
        for host in ["localhost", ProcessInfo.processInfo.hostName] {
            var components = URLComponents(url: file, resolvingAgainstBaseURL: false)!
            components.host = host
            components.fragment = "L12"
            workspace.revealed = []
            linkCoordinator.terminalDidRequestOpenURL(components.string!, kind: .text)
            precondition(workspace.revealed.map(\.path) == [file.path], "Local host file URLs must reveal their file")
            precondition(workspace.revealed[0].fragment == nil, "Line fragments must not reach Finder")
        }
        workspace.revealed = []
        var remoteURL = URLComponents(url: file, resolvingAgainstBaseURL: false)!
        remoteURL.host = "another-machine.invalid"
        for ignored in [remoteURL.string!, fileRoot.appendingPathComponent("missing.txt").absoluteString,
                        "file:relative.txt", "javascript:alert(1)", "ssh://example.com"] {
            linkCoordinator.terminalDidRequestOpenURL(ignored, kind: .text)
        }
        precondition(workspace.revealed.isEmpty && workspace.opened.isEmpty,
                     "Missing files, remote hosts and unsupported schemes must not open anything")
        let remoteStore = SessionStore(profile: DeviceProfile(name: "Remote links", kind: .ssh,
            host: "remote.invalid", executable: "/usr/bin/false"))
        linkCoordinator.store = remoteStore
        linkCoordinator.terminalDidRequestOpenURL(file.absoluteString, kind: .text)
        precondition(workspace.revealed.isEmpty, "Remote pane paths must not reveal unrelated local files")
        for external in [url, "http://example.com", "mailto:test@example.com"] {
            linkCoordinator.terminalDidRequestOpenURL(external, kind: .text)
        }
        precondition(workspace.opened.map(\.absoluteString) == [url, "http://example.com", "mailto:test@example.com"],
                     "Web and email links must retain their existing handlers")
        view.delegate = lifecycle
        bridge.receive(Data("\u{1b}[?1000l\u{1b}[?1006l".utf8))
        bridge.session.waitForPendingOutput()
        print("PASS: file links reveal local files, preserve selection and reject remote paths")
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
            let deadline = Date().addingTimeInterval(ProcessInfo.processInfo.environment["HERDR_TEST_PASTE_AGENTS"] == "1" ? 180 : 45)
            while !finished, Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            }
            precondition(finished, "Live Ghostty integration timed out")
        }
    }

    @MainActor private static func checkPastePackets() {
        let capture = StreamCapture()
        let rejection = StreamCapture()
        let buffer = TerminalPasteBuffer(write: { capture.append($0) }, reject: { rejection.append(Data([1])) })
        let start = TerminalPasteBuffer.start, end = TerminalPasteBuffer.end
        buffer.append(Data([0x1b]))
        precondition(capture.packets == [Data([0x1b])], "Escape must dispatch immediately")
        capture.clear()
        let text = Data("café 世界\nlast line".utf8)
        buffer.append(Data([0xff, 0x00]) + start)
        for byte in text { buffer.append(Data([byte])) }
        for byte in end.dropLast() { buffer.append(Data([byte])) }
        precondition(capture.packets == [Data([0xff, 0x00])], "An unfinished paste must not reach Herdr")
        buffer.append(Data(end.suffix(1)) + Data([13]) + start + Data("next".utf8) + end)
        precondition(capture.packets == [Data([0xff, 0x00]), start + text + end, Data([13]), start + Data("next".utf8) + end])
        capture.clear()
        buffer.append(start + Data(repeating: 120, count: TerminalPasteBuffer.limit - 12) + end)
        precondition(capture.packets.count == 1 && capture.packets[0].count == TerminalPasteBuffer.limit)
        capture.clear()
        buffer.append(start + Data(repeating: 120, count: TerminalPasteBuffer.limit - 11) + end)
        buffer.append(Data([13]))
        precondition(capture.bytes.isEmpty && rejection.packets.count == 1, "Oversized paste and trailing Enter must not be sent")
        precondition(buffer.isBlocked)
        buffer.reset()
        precondition(!buffer.isBlocked, "A queued rejection must be ignored after reset")
        buffer.append(start + Data("incomplete".utf8))
        buffer.reset()
        buffer.append(Data("new session".utf8))
        precondition(capture.packets == [Data("new session".utf8)], "Reconnect must discard unfinished paste")
        for version in ["0.8.2", "0.8.99", "0.9.0-rc.1", "", "unknown"] {
            precondition(!GhosttyStreamBridge.supportsSemanticPastes(serverVersion: version))
        }
        for version in ["0.9.0", "0.10.0", "1.0.0"] {
            precondition(GhosttyStreamBridge.supportsSemanticPastes(serverVersion: version))
        }
        print("PASS: paste packets preserve binary keys, fragmented payloads, ordering, size limits, resets and server version gating")
    }
}

@MainActor
private func checkClipboardFiles(view: HerdrTerminalView, capture: StreamCapture,
                                 waitUntil: (() -> Bool) -> Void) {
    let board = NSPasteboard.general
    let saved = (board.pasteboardItems ?? []).map { item in
        item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
    }
    defer {
        board.clearContents()
        board.writeObjects(saved.map { entries in
            let item = NSPasteboardItem()
            for (type, data) in entries { item.setData(data, forType: type) }
            return item
        })
        view.resolveFileDrop = nil
        view.onFileDropError = nil
    }
    view.canAcceptFileDrop = { true }
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let png = bitmap.representation(using: .png, properties: [:])!
    board.clearContents()
    board.setData(png, forType: .png)
    capture.clear()
    precondition(view.performBindingAction("paste_from_clipboard"))
    waitUntil { !capture.bytes.isEmpty }
    let payload = String(decoding: capture.bytes, as: UTF8.self)
    precondition(payload.hasPrefix("\u{1b}[200~'"), "A screenshot must be staged and pasted as an attachment file")
    let path = String(payload.dropFirst(7).dropLast(8))
    precondition((try? Data(contentsOf: URL(fileURLWithPath: path))) == png,
                 "The pasted screenshot must retain its encoded bytes: \(payload.debugDescription)")
    try? FileManager.default.removeItem(at: URL(fileURLWithPath: path).deletingLastPathComponent())
    print("PASS: clipboard screenshots become readable attachment files")

    // Each path must be its own paste: Codex's image parser accepts only
    // one path per event. Finder's display-name text must not win over URLs.
    board.clearContents()
    board.writeObjects([URL(fileURLWithPath: "/tmp/first image.png"),
                        URL(fileURLWithPath: "/tmp/second.mov")] as [NSURL])
    let commandV = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
        timestamp: 1, windowNumber: view.window!.windowNumber, context: nil,
        characters: "v", charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9)!
    capture.clear()
    precondition(view.performKeyEquivalent(with: commandV))
    waitUntil { capture.packets.count == 2 }
    precondition(capture.packets.map { String(decoding: $0, as: UTF8.self) } == [
        "\u{1b}[200~'/tmp/first image.png' \u{1b}[201~",
        "\u{1b}[200~'/tmp/second.mov' \u{1b}[201~"
    ], "Command-V must deliver images and videos as separate file pastes")

    // The Edit menu follows the same path and uploads before sending input.
    var finishUpload: CheckedContinuation<PreparedFileDrop, Error>?
    view.resolveFileDrop = { urls in
        precondition(urls.map(\.path) == ["/tmp/first image.png", "/tmp/second.mov"])
        return try await withCheckedThrowingContinuation { finishUpload = $0 }
    }
    capture.clear()
    precondition(NSApp.sendAction(NSSelectorFromString("paste:"), to: view, from: nil))
    waitUntil { finishUpload != nil }
    precondition(capture.bytes.isEmpty, "Clipboard paths must wait for the SSH upload")
    precondition(view.performBindingAction("paste_from_clipboard"))
    precondition(capture.bytes.isEmpty, "A busy clipboard paste must not fall back to local paths")
    finishUpload!.resume(returning: PreparedFileDrop(paths: ["/tmp/remote/image.png", "/tmp/remote/video.mov"]))
    finishUpload = nil
    waitUntil { capture.packets.count == 2 }
    precondition(capture.packets.map { String(decoding: $0, as: UTF8.self) } == [
        "\u{1b}[200~'/tmp/remote/image.png' \u{1b}[201~",
        "\u{1b}[200~'/tmp/remote/video.mov' \u{1b}[201~"
    ])
    view.resolveFileDrop = nil
    print("PASS: Command-V and Edit Paste deliver separate files and wait for remote uploads")

    board.clearContents()
    board.setData(bitmap.tiffRepresentation!, forType: .tiff)
    let tiffFiles = try! TerminalClipboardFiles.read(board)
    precondition(tiffFiles.urls.count == 1 && tiffFiles.urls[0].pathExtension == "png")
    precondition(NSBitmapImageRep(data: try! Data(contentsOf: tiffFiles.urls[0]))?.pixelsWide == 2)
    tiffFiles.discard()
    board.clearContents()
    board.setData(Data("video fixture".utf8), forType: NSPasteboard.PasteboardType("public.mpeg-4"))
    let videoFiles = try! TerminalClipboardFiles.read(board)
    precondition(videoFiles.urls.count == 1 && videoFiles.urls[0].pathExtension == "mp4")
    precondition((try! Data(contentsOf: videoFiles.urls[0])) == Data("video fixture".utf8))
    videoFiles.discard()

    board.clearContents()
    board.setData(png, forType: .png)
    var stagedURL: URL?
    var pasteFailed = false
    view.onFileDropError = { _ in pasteFailed = true }
    view.resolveFileDrop = { urls in
        stagedURL = urls[0]
        throw HerdrError.message("Test upload failure")
    }
    capture.clear()
    precondition(view.performBindingAction("paste_from_clipboard"))
    waitUntil { pasteFailed }
    precondition(pasteFailed && capture.bytes.isEmpty)
    precondition(stagedURL != nil && !FileManager.default.fileExists(atPath: stagedURL!.path),
                 "A failed upload must remove staged clipboard bytes")
    view.resolveFileDrop = nil
    view.onFileDropError = nil

    board.clearContents()
    board.setString("plain text", forType: .string)
    capture.clear()
    precondition(view.performBindingAction("paste_from_clipboard"))
    waitUntil { !capture.bytes.isEmpty }
    precondition(String(decoding: capture.bytes, as: UTF8.self) == "\u{1b}[200~plain text\u{1b}[201~")
    print("PASS: TIFF conversion, raw video staging, failed upload cleanup and ordinary text paste")
}

@MainActor
private final class ShortcutTarget: NSObject {
    var invocations = 0
    @objc func invoke(_ sender: NSMenuItem) { invocations += 1 }
}

private final class LinkWorkspace: NSWorkspace {
    var revealed: [URL] = []
    var opened: [URL] = []
    override func activateFileViewerSelecting(_ fileURLs: [URL]) { revealed += fileURLs }
    override func open(_ url: URL) -> Bool { opened.append(url); return true }
}

private final class StreamCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var data: [UInt8] = []
    private var writes: [Data] = []
    private var size: InMemoryTerminalViewport?
    var bytes: [UInt8] { lock.withLock { data } }
    var packets: [Data] { lock.withLock { writes } }
    var viewport: InMemoryTerminalViewport? { lock.withLock { size } }
    func append(_ value: Data) { lock.withLock { data.append(contentsOf: value); writes.append(value) } }
    func resize(_ value: InMemoryTerminalViewport) { lock.withLock { size = value } }
    func clear() { lock.withLock { data = []; writes = [] } }
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
final class FileDragInfo: NSObject, NSDraggingInfo {
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
