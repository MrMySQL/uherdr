import AppKit
import SwiftUI
import GhosttyTerminal
import HerdrCore
@testable import HerdrMac

/// Opt-in tests using installed, authenticated agent CLIs and an isolated SSH
/// server. They send only generated test files to the agents.
enum AgentFileDropTests {
    @MainActor static func run(socket: String, executable: String) async throws {
        let env = ProcessInfo.processInfo.environment
        guard socket.hasPrefix("/tmp/"), socket.contains("native-client-test"),
              let ssh = env["HERDR_DROP_TEST_SSH"], let key = env["HERDR_DROP_TEST_KEY"],
              let port = env["HERDR_DROP_TEST_PORT"] else {
            throw HerdrError.message("Requires a disposable test socket and HERDR_DROP_TEST_SSH, KEY and PORT")
        }
        let client = HerdrClient(socketPath: socket)
        for remote in [false, true] {
            for agent in ["codex", "claude"] {
                let root = URL(fileURLWithPath: "/tmp/herdr-agent-drop-test-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
                defer { try? FileManager.default.removeItem(at: root) }
                let token = UUID().uuidString.lowercased()
                let textURL = root.appendingPathComponent("it's $notes; café.txt")
                try Data(token.utf8).write(to: textURL)
                let imageURL = root.appendingPathComponent("sample image.png")
                let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64,
                    bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                for y in 0..<64 { for x in 0..<64 {
                    let offset = y * bitmap.bytesPerRow + x * 3
                    bitmap.bitmapData![offset] = 255
                    bitmap.bitmapData![offset + 1] = 0
                    bitmap.bitmapData![offset + 2] = 0
                } }
                try bitmap.representation(using: .png, properties: [:])!.write(to: imageURL)
                let created = try await client.request("workspace.create", params: [
                    "label": .string("Drop test \(agent) \(remote ? "SSH" : "local")"),
                    "cwd": .string(root.path), "focus": .bool(false)
                ])
                let workspace = try created["workspace"].decode(Workspace.self)
                let pane = try created["root_pane"].decode(Pane.self)
                let defaults = UserDefaults(suiteName: "herdr-agent-drop-\(token)")!
                defer { defaults.removePersistentDomain(forName: "herdr-agent-drop-\(token)") }
                let profile = DeviceProfile(name: "Drop test", kind: remote ? .ssh : .local,
                    host: "127.0.0.1", user: NSUserName(), port: port, identityFile: key,
                    socketPath: socket, executable: executable)
                let store = SessionStore(profile: profile, defaults: defaults,
                    tunnel: SSHTunnel(sshExecutable: ssh), fileTransfer: RemoteFileTransfer(sshExecutable: ssh))
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
                defer { transport.stop(); store.disconnect(); window.orderOut(nil) }
                func terminal(_ root: NSView) -> HerdrTerminalView? {
                    if let view = root as? HerdrTerminalView { return view }
                    return root.subviews.compactMap { terminal($0) }.first
                }
                func wait(_ predicate: () -> Bool, timeout: Double = 20) async throws {
                    let deadline = Date().addingTimeInterval(timeout)
                    while !predicate(), Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
                    guard predicate() else { throw HerdrError.message("Timed out: \(agent) \(remote ? "SSH" : "local")") }
                }
                do {
                    try await wait { transport.ready }
                    let view = terminal(host)!
                    guard case .inMemory(let session) = view.configuration.backend else { fatalError() }
                    func screen() -> String { session.readViewportText() ?? "" }
                    func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
                    let command: String
                    if agent == "codex" {
                        command = "codex --no-alt-screen -a never -s read-only -c " + quote("projects.\"\(root.path)\".trust_level=\"trusted\"")
                    } else {
                        command = "claude --setting-sources '' --strict-mcp-config --mcp-config '{\"mcpServers\":{}}' --allowedTools Read"
                    }
                    precondition(view.paste(text: command)); precondition(view.sendKey(.enter))
                    // Startup screens vary by CLI version. Log them for review;
                    // allow only trust for the generated, disposable test folder.
                    var readySamples = 0
                    for _ in 0..<100 {
                        let output = screen()
                        if output.contains("Yes, I trust this folder") || output.contains("Yes, continue") {
                            precondition(view.sendKey(.enter))
                            readySamples = 0
                            try await Task.sleep(for: .milliseconds(500))
                            continue
                        }
                        let ready = (agent == "codex" && output.contains("Ask Codex to do anything") &&
                                     output.contains("never") && !output.contains("loading")) ||
                            (agent == "claude" && (output.contains("for shortcuts") || output.contains("Try \"")))
                        readySamples = ready ? readySamples + 1 : 0
                        if readySamples >= 2 { break }
                        try await Task.sleep(for: .milliseconds(300))
                    }
                    print("STARTUP \(agent) \(remote ? "SSH" : "local"):\n\(screen())")
                    guard readySamples >= 2 else { throw HerdrError.message("Agent did not reach its prompt") }
                    let prompt = "Read the text file and inspect the image I am attaching. Reply only DROP_OK:<the exact text file contents>:<the image's dominant color in lowercase>. Do not modify any files. Files: "
                    precondition(view.paste(text: prompt))
                    let board = NSPasteboard.withUniqueName()
                    defer { board.releaseGlobally() }
                    precondition(board.writeObjects([textURL, imageURL] as [NSURL]))
                    let drag = FileDragInfo(pasteboard: board, window: window)
                    precondition(view.performDragOperation(drag))
                    try await wait { screen().contains(remote ? "/tmp/herdr-drop-" : root.path) || screen().contains("Image #") }
                    try await wait { !transport.uploadingFiles }
                    try await Task.sleep(for: .milliseconds(500))
                    guard store.operationError == nil else { throw HerdrError.message(store.operationError!) }
                    print("DRAFT \(agent) \(remote ? "SSH" : "local"):\n\(screen())")
                    if remote {
                        // A path-only implementation cannot pass after the
                        // local originals disappear, even on loopback SSH.
                        try FileManager.default.removeItem(at: textURL)
                        try FileManager.default.removeItem(at: imageURL)
                    }
                    precondition(view.sendKey(.enter))
                    do { try await wait({ screen().contains("DROP_OK:\(token):red") }, timeout: 120) }
                    catch { print("RESULT:\n\(screen())"); throw error }
                    print("PASS: \(agent) \(remote ? "real SSH" : "local") drag/drop reads text and image")
                    host.rootView = AnyView(EmptyView())
                    transport.stop()
                    _ = try await client.request("workspace.close", params: ["workspace_id": .string(workspace.id)])
                } catch {
                    host.rootView = AnyView(EmptyView())
                    transport.stop()
                    _ = try? await client.request("workspace.close", params: ["workspace_id": .string(workspace.id)])
                    throw error
                }
            }
        }
    }
}
