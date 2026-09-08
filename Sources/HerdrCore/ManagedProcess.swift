import Foundation
import Darwin

private final class ProcessOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var ended = false
    func receive(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        if chunk.isEmpty { ended = true }
        data.append(chunk)
        if data.count > 16384 { data = data.suffix(16384) }
    }
    var snapshot: (String, Bool) {
        lock.lock(); defer { lock.unlock() }
        return (String(decoding: data, as: UTF8.self), ended)
    }
}

/// Owns only this child, drains both pipes continuously, and bounds captured output.
@MainActor
public final class ManagedProcess {
    private let process = Process()
    private let stdout = Pipe(), stderr = Pipe()
    private let out = ProcessOutput(), err = ProcessOutput()
    public var isRunning: Bool { process.isRunning }
    public var errorText: String { err.snapshot.0.trimmingCharacters(in: .whitespacesAndNewlines) }

    public init(executable: String, arguments: [String]) throws {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout; process.standardError = stderr
        let outBuffer = out, errBuffer = err
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let chunk = (try? handle.read(upToCount: 65536)) ?? Data(); outBuffer.receive(chunk)
            if chunk.isEmpty { handle.readabilityHandler = nil }
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let chunk = (try? handle.read(upToCount: 65536)) ?? Data(); errBuffer.receive(chunk)
            if chunk.isEmpty { handle.readabilityHandler = nil }
        }
        do { try process.run() }
        catch { closePipes(); throw error }
    }

    public func result(timeout: TimeInterval = 12) async throws -> String {
        defer { stop() }
        let deadline = Date().addingTimeInterval(timeout)
        while isRunning || !out.snapshot.1 || !err.snapshot.1 {
            try Task.checkCancellation()
            guard Date() < deadline else { throw HerdrError.message("SSH connection timed out.") }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard process.terminationStatus == 0 else {
            throw HerdrError.message(errorText.isEmpty ? "SSH exited with status \(process.terminationStatus)." : errorText)
        }
        return out.snapshot.0
    }

    public func stop() {
        if process.isRunning {
            process.terminate()
            let child = process
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if child.isRunning { kill(child.processIdentifier, SIGKILL) }
            }
        }
        closePipes()
    }

    private func closePipes() {
        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        try? stdout.fileHandleForReading.close(); try? stderr.fileHandleForReading.close()
        try? stdout.fileHandleForWriting.close(); try? stderr.fileHandleForWriting.close()
    }
}
