import Foundation
import GhosttyTerminal

/// Herdr owns the authoritative terminal. Render its frames through Ghostty's
/// replay path so asynchronous protocol replies cannot become shell input.
@MainActor
final class GhosttyStreamBridge {
    let session: InMemoryTerminalSession
    private let pasteBuffer: TerminalPasteBuffer
    private var semanticPastes = false

    init(input: @escaping @Sendable (Data) -> Void,
         resize: @escaping @Sendable (InMemoryTerminalViewport) -> Void,
         pasteRejected: @escaping @Sendable () -> Void = {}) {
        let pasteBuffer = TerminalPasteBuffer(write: input, reject: pasteRejected)
        self.pasteBuffer = pasteBuffer
        session = InMemoryTerminalSession(
            write: { pasteBuffer.append($0) }, resize: resize,
            suppressesPixelOnlyResizes: true, suppressesTerminalResponses: true
        )
    }

    func receive(_ data: Data, semanticPastes: Bool = false) {
        let wasSemantic = self.semanticPastes
        self.semanticPastes = semanticPastes
        // This is the outer terminal's paste mode, not the application's.
        // Stock Herdr 0.9+ recognizes framed input as a semantic paste and
        // applies the real PTY mode itself, on the same ordered connection.
        // The caller supplies a complete JSON terminal.frame from Herdr's
        // ANSI blit encoder, not an arbitrary PTY/pipe read. Its control
        // sequences are complete, so this is a safe boundary for reassertion.
        let mode = semanticPastes ? "\u{1b}[?2004h" : wasSemantic ? "\u{1b}[?2004l" : ""
        // Herdr's blit encoder assumes the host has DECAWM disabled (its
        // interactive client does this in TerminalGuard). JSON control does
        // not initialize our surface. In-flight frames can be wider than the
        // grid during resize; wrapping them corrupts adjacent rows and can
        // scroll the whole viewport, invalidating subsequent partial frames.
        session.receive(Data("\u{1b}[?7l".utf8) + data + Data(mode.utf8))
    }

    func resetInput() { pasteBuffer.reset() }
    var hasRejectedPaste: Bool { pasteBuffer.isBlocked }

    static func supportsSemanticPastes(serverVersion: String) -> Bool {
        let parts = serverVersion.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, let major = Int(parts[0]), let minor = Int(parts[1]),
              let patch = Int(parts[2]), major >= 0, minor >= 0, patch >= 0 else { return false }
        return (major, minor, patch) >= (0, 9, 0)
    }
}
