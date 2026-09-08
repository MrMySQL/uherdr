import Foundation
import GhosttyTerminal

/// Herdr owns the authoritative terminal. Render its frames through Ghostty's
/// replay path so asynchronous protocol replies cannot become shell input.
@MainActor
final class GhosttyStreamBridge {
    let session: InMemoryTerminalSession

    init(input: @escaping @Sendable (Data) -> Void,
         resize: @escaping @Sendable (InMemoryTerminalViewport) -> Void) {
        session = InMemoryTerminalSession(
            write: input, resize: resize,
            suppressesPixelOnlyResizes: true, suppressesTerminalResponses: true
        )
    }

    func receive(_ data: Data) {
        session.receive(data)
    }
}
