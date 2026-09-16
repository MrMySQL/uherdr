import AppKit
import SwiftUI
import GhosttyTerminal
import HerdrCore
@testable import HerdrMac

/// Opt-in tests using installed, authenticated agent CLIs and an isolated SSH
/// server. They send only generated test files to the agents.
enum AgentFileDropTests {
    private static func normalizedDraft(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping
            .components(separatedBy: .whitespacesAndNewlines).joined()
            .replacingOccurrences(of: "'\\''", with: "'")
    }

    static func draftContainsDroppedFiles(_ draft: String, textReference: String,
                                          imageReference: String, pathPrefix: String) -> Bool {
        let draft = normalizedDraft(draft)
        let hasText = draft.contains(normalizedDraft(textReference))
        let hasImage = draft.contains(normalizedDraft(imageReference)) ||
            draft.contains("[Image#1]") || draft.contains("[Image1]")
        return draft.contains(normalizedDraft(pathPrefix)) && hasText && hasImage
    }

    @MainActor static func run(socket: String, executable: String) async throws {
        let env = ProcessInfo.processInfo.environment
        guard socket.hasPrefix("/tmp/"), socket.contains("native-client-test"),
              let ssh = env["HERDR_DROP_TEST_SSH"], let key = env["HERDR_DROP_TEST_KEY"],
              let port = env["HERDR_DROP_TEST_PORT"] else {
            throw HerdrError.message("Requires a disposable test socket and HERDR_DROP_TEST_SSH, KEY and PORT")
        }
        let client = HerdrClient(socketPath: socket)
        func require(_ condition: Bool, _ message: String) throws {
            guard condition else { throw HerdrError.message(message) }
        }
        let fixtureParent = URL(fileURLWithPath: env["HERDR_DROP_TEST_ROOT"] ?? "/tmp", isDirectory: true)
        for remote in [false, true] {
            for agent in ["codex", "claude"] {
                let root = fixtureParent.appendingPathComponent("herdr-agent-drop-test-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
                defer { try? FileManager.default.removeItem(at: root) }
                let token = UUID().uuidString.lowercased()
                let textURL = root.appendingPathComponent("it's $notes; café.txt")
                try Data(token.utf8).write(to: textURL)
                let imageURL = root.appendingPathComponent("sample image.png")
                guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64,
                    bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                    let pixels = bitmap.bitmapData else {
                    throw HerdrError.message("Could not allocate the test image")
                }
                for y in 0..<64 { for x in 0..<64 {
                    let offset = y * bitmap.bytesPerRow + x * 3
                    pixels[offset] = 255
                    pixels[offset + 1] = 0
                    pixels[offset + 2] = 0
                } }
                guard let imageData = bitmap.representation(using: .png, properties: [:]) else {
                    throw HerdrError.message("Could not encode the test image")
                }
                try imageData.write(to: imageURL)
                let created = try await client.request("workspace.create", params: [
                    "label": .string("Drop test \(agent) \(remote ? "SSH" : "local")"),
                    "cwd": .string(root.path), "focus": .bool(false)
                ])
                let workspace = try created["workspace"].decode(Workspace.self)
                do {
                    let pane = try created["root_pane"].decode(Pane.self)
                    guard let defaults = UserDefaults(suiteName: "herdr-agent-drop-\(token)") else {
                        throw HerdrError.message("Could not create isolated test defaults")
                    }
                    defer { defaults.removePersistentDomain(forName: "herdr-agent-drop-\(token)") }
                    let profile = DeviceProfile(name: "Drop test", kind: remote ? .ssh : .local,
                        host: "127.0.0.1", user: NSUserName(), port: port, identityFile: key,
                        socketPath: socket, executable: executable)
                    let store = SessionStore(profile: profile, defaults: defaults,
                        tunnel: SSHTunnel(sshExecutable: ssh), fileTransfer: RemoteFileTransfer(sshExecutable: ssh))
                    defer { store.disconnect() }
                    await store.refresh()
                    guard store.connected else { throw HerdrError.message(store.connectionError ?? "Test device did not connect") }
                    store.selectedPane = pane.id
                    let transport = HerdrMac.TerminalController()
                    let host = NSHostingView(rootView: AnyView(HerdrMac.TerminalSurface(
                        controller: transport, pane: pane, store: store, dark: true,
                        fontSize: 13, selected: true)))
                    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 780),
                        styleMask: [.titled, .resizable], backing: .buffered, defer: false)
                    window.contentView = host
                    window.makeKeyAndOrderFront(nil)
                    defer {
                        host.rootView = AnyView(EmptyView())
                        transport.stop()
                        window.orderOut(nil)
                    }
                    func terminal(_ root: NSView) -> HerdrTerminalView? {
                        if let view = root as? HerdrTerminalView { return view }
                        return root.subviews.compactMap { terminal($0) }.first
                    }
                    func wait(_ predicate: () -> Bool, timeout: Double = 20) async throws {
                        let deadline = Date().addingTimeInterval(timeout)
                        while true {
                            try Task.checkCancellation()
                            if let error = store.operationError ?? transport.error { throw HerdrError.message(error) }
                            if predicate() { return }
                            guard Date() < deadline else { throw HerdrError.message("Timed out: \(agent) \(remote ? "SSH" : "local")") }
                            try await Task.sleep(for: .milliseconds(100))
                        }
                    }
                    try await wait { transport.ready }
                    guard let view = terminal(host), case .inMemory(let session) = view.configuration.backend else {
                        throw HerdrError.message("Expected an attached in-memory terminal")
                    }
                    func screen() -> String { session.readViewportText() ?? "" }
                    func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
                    let command: String
                    if agent == "codex" {
                        command = "codex --no-alt-screen -a never -s read-only -c " + quote("projects.\"\(root.path)\".trust_level=\"trusted\"")
                    } else {
                        command = "claude --setting-sources '' --strict-mcp-config --mcp-config '{\"mcpServers\":{}}' --allowedTools Read"
                    }
                    try require(view.paste(text: command), "Could not paste the agent command")
                    try require(view.sendKey(.enter), "Could not start the agent")
                    // Startup screens vary by CLI version. Log them for review;
                    // allow only trust for the generated, disposable test folder.
                    var readySamples = 0
                    for _ in 0..<100 {
                        let output = screen()
                        if output.contains("Yes, I trust this folder") || output.contains("Yes, continue") {
                            try require(view.sendKey(.enter), "Could not send Enter to the agent")
                            readySamples = 0
                            try await Task.sleep(for: .milliseconds(500))
                            continue
                        }
                        // The footer can truncate policy labels for long cwd
                        // paths. A loaded model header plus the prompt is stable.
                        let ready = (agent == "codex" && output.contains("Ask Codex to do anything") &&
                                     output.contains("model:") && !output.contains("loading")) ||
                            (agent == "claude" && (output.contains("for shortcuts") || output.contains("Try \"")))
                        readySamples = ready ? readySamples + 1 : 0
                        if readySamples >= 2 { break }
                        try await Task.sleep(for: .milliseconds(300))
                    }
                    print("STARTUP \(agent) \(remote ? "SSH" : "local"):\n\(screen())")
                    guard readySamples >= 2 else { throw HerdrError.message("Agent did not reach its prompt") }
                    let prompt = "Read the text file and inspect the image I am attaching. Reply only DROP_OK:<the exact text file contents>:<the image's dominant color in lowercase>. Do not modify any files. Files: "
                    try require(view.paste(text: prompt), "Could not paste the test prompt")
                    let board = NSPasteboard.withUniqueName()
                    defer { board.releaseGlobally() }
                    try require(board.writeObjects([textURL, imageURL] as [NSURL]), "Could not write file URLs to the pasteboard")
                    let drag = FileDragInfo(pasteboard: board, window: window)
                    try require(view.performDragOperation(drag), "The terminal rejected the file drop")
                    // The cwd is already visible during startup. Require both
                    // dropped files in the draft before submitting anything.
                    try await wait {
                        draftContainsDroppedFiles(screen(),
                            textReference: remote ? textURL.lastPathComponent : textURL.path,
                            imageReference: remote ? imageURL.lastPathComponent : imageURL.path,
                            pathPrefix: remote ? "/tmp/herdr-drop-" : root.path)
                    }
                    try await wait { !transport.uploadingFiles }
                    if let error = store.operationError { throw HerdrError.message(error) }
                    print("DRAFT \(agent) \(remote ? "SSH" : "local"):\n\(screen())")
                    if remote {
                        // A path-only implementation cannot pass after the
                        // local originals disappear, even on loopback SSH.
                        try FileManager.default.removeItem(at: textURL)
                        try FileManager.default.removeItem(at: imageURL)
                    }
                    try require(view.sendKey(.enter), "Could not send Enter to the agent")
                    do { try await wait({ screen().contains("DROP_OK:\(token):red") }, timeout: 120) }
                    catch { print("RESULT:\n\(screen())"); throw error }
                    print("PASS: \(agent) \(remote ? "real SSH" : "local") drag/drop reads text and image")
                    _ = try await client.request("workspace.close", params: ["workspace_id": .string(workspace.id)])
                } catch {
                    _ = try? await client.request("workspace.close", params: ["workspace_id": .string(workspace.id)])
                    throw error
                }
            }
        }
    }
}
