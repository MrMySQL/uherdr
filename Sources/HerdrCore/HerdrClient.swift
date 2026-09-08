import Foundation
import Darwin

public protocol HerdrRequesting: Sendable {
    func request(_ method: String, params: [String: JSONValue], timeout: Int) async throws -> JSONValue
}

public extension HerdrRequesting {
    func request(_ method: String, params: [String: JSONValue] = [:]) async throws -> JSONValue {
        try await request(method, params: params, timeout: 8)
    }
}

/// Requests are serialized off the UI thread. Each has its own socket and bounded deadline.
public final class HerdrClient: HerdrRequesting, @unchecked Sendable {
    public let socketPath: String
    private let queue = DispatchQueue(label: "dev.herdr.native.api", qos: .userInitiated)
    public init(socketPath: String) { self.socketPath = socketPath }

    public func request(_ method: String, params: [String: JSONValue] = [:], timeout: Int = 8) async throws -> JSONValue {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try self.perform(method, params: params, timeout: timeout)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func perform(_ method: String, params: [String: JSONValue], timeout: Int) throws -> JSONValue {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw posixError("create socket") }
        defer { Darwin.close(fd) }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout.size(ofValue: noSigPipe)))
        var duration = timeval(tv_sec: timeout, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &duration, socklen_t(MemoryLayout.size(ofValue: duration)))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &duration, socklen_t(MemoryLayout.size(ofValue: duration)))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8CString)
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw HerdrError.message("Socket path is too long") }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            pathBytes.withUnsafeBytes { source in buffer.copyBytes(from: source) }
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { throw posixError("connect to herdr at \(socketPath)") }
        let id = UUID().uuidString
        var data = try JSONEncoder().encode(JSONValue.object(["id": .string(id), "method": .string(method), "params": .object(params)]))
        data.append(10)
        try data.withUnsafeBytes { bytes in
            var sent = 0
            while sent < bytes.count {
                let n = Darwin.write(fd, bytes.baseAddress!.advanced(by: sent), bytes.count - sent)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw posixError("send request") }
                sent += n
            }
        }
        var framing = JSONLineBuffer()
        var buffer = [UInt8](repeating: 0, count: 65536)
        let deadline = Date().addingTimeInterval(TimeInterval(timeout))
        while Date() < deadline {
            let n = Darwin.read(fd, &buffer, buffer.count)
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { throw n == 0 ? HerdrError.message("Herdr closed the connection") : posixError("read response") }
            let lines = try framing.append(Data(buffer.prefix(n)))
            if let response = lines.first { return try APIResponse.result(from: response, expectedID: id) }
        }
        throw HerdrError.message("Herdr request timed out")
    }

    private func posixError(_ operation: String) -> HerdrError {
        .message("Could not \(operation): \(String(cString: strerror(errno)))")
    }
}
