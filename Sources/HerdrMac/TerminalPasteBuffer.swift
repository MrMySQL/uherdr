import Foundation

/// Ghostty emits the paste opener in one callback, followed by the payload
/// and closer. Herdr 0.9 requires the whole paste in one input message.
/// Ordinary callbacks (especially a lone Escape key) must never be delayed.
final class TerminalPasteBuffer: @unchecked Sendable {
    static let start = Data("\u{1b}[200~".utf8)
    static let end = Data("\u{1b}[201~".utf8)
    static let limit = 1_048_576 // Herdr's limit includes both delimiters.
    private let lock = NSLock()
    private var pending: Data?
    private var blocked = false
    private let write: @Sendable (Data) -> Void
    private let reject: @Sendable () -> Void
    var isBlocked: Bool { lock.withLock { blocked } }

    init(write: @escaping @Sendable (Data) -> Void, reject: @escaping @Sendable () -> Void) {
        self.write = write
        self.reject = reject
    }

    func reset() {
        lock.withLock { pending = nil; blocked = false }
    }

    func append(_ data: Data) {
        lock.withLock {
            guard !blocked, !data.isEmpty else { return }
            consume(data)
        }
    }

    private func consume(_ data: Data) {
        if var packet = pending {
            let searchStart = max(0, packet.count - Self.end.count + 1)
            packet.append(data)
            if let end = packet.range(of: Self.end, in: searchStart..<packet.count) {
                pending = nil
                guard end.upperBound <= Self.limit else { fail(); return }
                write(Data(packet[..<end.upperBound]))
                consume(Data(packet[end.upperBound...]))
            } else if packet.count > Self.limit {
                fail()
            } else {
                pending = packet
            }
        } else if let start = data.range(of: Self.start) {
            if start.lowerBound > data.startIndex { write(Data(data[..<start.lowerBound])) }
            pending = Self.start
            consume(Data(data[start.upperBound...]))
        } else if !data.isEmpty {
            write(data)
        }
    }

    private func fail() {
        pending = nil
        blocked = true
        reject()
    }
}
