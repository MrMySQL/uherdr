import Foundation

/// Runs a command and hands over every byte it prints, in order, with a size
/// cap and a deadline. Unlike `ManagedProcess`, which keeps only the last
/// 16 KiB, this suits file listings, Git records and search results.
/// Cancelling the consuming task, the deadline and the cap all kill the child.
public enum StreamingProcess {
    public enum Event: Equatable, Sendable {
        case output(Data)
        /// Always the last event. `stderr` keeps at most its last 16 KiB.
        case exit(status: Int32, stderr: String)
    }

    public enum Failure: Error, Equatable, LocalizedError {
        case launch(String)
        case timedOut
        case tooMuchOutput(limit: Int)

        public var errorDescription: String? {
            switch self {
            case let .launch(reason): return "Couldn't start the command: \(reason)"
            case .timedOut: return "The command took too long and was stopped."
            case let .tooMuchOutput(limit): return "The command printed more than \(limit) bytes and was stopped."
            }
        }
    }

    public struct Result: Equatable, Sendable {
        public let stdout: Data
        public let status: Int32
        public let stderr: String

        public init(stdout: Data, status: Int32, stderr: String) {
            self.stdout = stdout
            self.status = status
            self.stderr = stderr
        }
    }

    /// `keepInputOpen`: stdin stays an open pipe until the run ends, so a
    /// remote script can watch it and stop its job when uHerdr goes away.
    public static func events(executable: String, arguments: [String], environment: [String: String]? = nil,
                              directory: String? = nil, input: Data? = nil, keepInputOpen: Bool = false,
                              maxBytes: Int = 64 << 20, timeout: Duration = .seconds(30)) -> AsyncThrowingStream<Event, Error> {
        AsyncThrowingStream { continuation in
            let run = Run(continuation: continuation, maxBytes: maxBytes)
            // This closure is what keeps `run` alive (its process handlers hold it weakly)
            // until the stream ends, and ending the stream early kills the child.
            continuation.onTermination = { _ in run.stop() }
            run.start(executable: executable, arguments: arguments, environment: environment,
                      directory: directory, input: input, keepInputOpen: keepInputOpen, timeout: timeout)
        }
    }

    /// Collects everything. A non-zero exit is returned, not thrown, because
    /// some tools use it for an ordinary answer (ripgrep: 1 means no match).
    public static func run(executable: String, arguments: [String], environment: [String: String]? = nil,
                           directory: String? = nil, input: Data? = nil,
                           maxBytes: Int = 64 << 20, timeout: Duration = .seconds(30)) async throws -> Result {
        var stdout = Data()
        for try await event in events(executable: executable, arguments: arguments, environment: environment,
                                      directory: directory, input: input, maxBytes: maxBytes, timeout: timeout) {
            switch event {
            case let .output(data): stdout.append(data)
            case let .exit(status, stderr): return Result(stdout: stdout, status: status, stderr: stderr)
            }
        }
        throw CancellationError()
    }

    private final class Run: @unchecked Sendable {
        private let lock = NSLock()
        private let continuation: AsyncThrowingStream<Event, Error>.Continuation
        /// stdin's write end, held open for `keepInputOpen` until the run ends.
        private var heldInput: FileHandle?
        private let maxBytes: Int
        private let process = Process()
        private var stdoutBytes = 0
        private var stderrTail = Data()
        private var openStreams = 2
        private var status: Int32?
        private var finished = false
        private var deadline: DispatchWorkItem?
        /// The child's pid when it leads its own process group (Foundation
        /// starts it that way); jobs it starts in the background share it.
        private var group: pid_t?

        init(continuation: AsyncThrowingStream<Event, Error>.Continuation, maxBytes: Int) {
            self.continuation = continuation
            self.maxBytes = maxBytes
        }

        func start(executable: String, arguments: [String], environment: [String: String]?,
                   directory: String?, input: Data?, keepInputOpen: Bool = false, timeout: Duration) {
            let out = Pipe(), err = Pipe(), stdin = Pipe()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            if let environment { process.environment = environment }
            if let directory { process.currentDirectoryURL = URL(fileURLWithPath: directory) }
            process.standardOutput = out
            process.standardError = err
            process.standardInput = input == nil && !keepInputOpen ? FileHandle.nullDevice : stdin
            if keepInputOpen { lock.lock(); heldInput = stdin.fileHandleForWriting; lock.unlock() }
            out.fileHandleForReading.readabilityHandler = { [weak self] handle in self?.read(handle.availableData, stdout: true) }
            err.fileHandleForReading.readabilityHandler = { [weak self] handle in self?.read(handle.availableData, stdout: false) }
            process.terminationHandler = { [weak self] process in
                guard let self else { return }
                lock.lock(); status = process.terminationStatus; lock.unlock()
                finishIfDone()
            }
            do {
                try process.run()
                let pid = process.processIdentifier
                if getpgid(pid) == pid { lock.lock(); group = pid; lock.unlock() }
            } catch {
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                fail(Failure.launch(error.localizedDescription))
                return
            }
            if let input {
                let writer = stdin.fileHandleForWriting
                DispatchQueue.global().async {
                    try? writer.write(contentsOf: input)
                    // A held stdin stays open after its input; ending the run closes it.
                    if !keepInputOpen { try? writer.close() }
                }
            }
            let item = DispatchWorkItem { [weak self] in self?.fail(Failure.timedOut) }
            lock.lock(); deadline = item; lock.unlock()
            let (seconds, attoseconds) = timeout.components
            let nanos = Int(seconds) * 1_000_000_000 + Int(attoseconds / 1_000_000_000)
            DispatchQueue.global().asyncAfter(deadline: .now() + .nanoseconds(nanos), execute: item)
        }

        private func read(_ data: Data, stdout: Bool) {
            lock.lock()
            if finished { lock.unlock(); return }
            if data.isEmpty {
                openStreams -= 1
                lock.unlock()
                if let handle = (stdout ? process.standardOutput : process.standardError) as? Pipe {
                    handle.fileHandleForReading.readabilityHandler = nil
                }
                finishIfDone()
                return
            }
            if stdout {
                stdoutBytes += data.count
                if stdoutBytes > maxBytes {
                    lock.unlock()
                    fail(Failure.tooMuchOutput(limit: maxBytes))
                    return
                }
                continuation.yield(.output(data))
            } else {
                stderrTail.append(data)
                if stderrTail.count > 16384 { stderrTail = stderrTail.suffix(16384) }
            }
            lock.unlock()
        }

        private func finishIfDone() {
            lock.lock()
            guard !finished, openStreams == 0, let status else { lock.unlock(); return }
            finished = true
            deadline?.cancel()
            let stderr = String(decoding: stderrTail, as: UTF8.self)
            let held = heldInput
            heldInput = nil
            lock.unlock()
            try? held?.close()
            continuation.yield(.exit(status: status, stderr: stderr))
            continuation.finish()
        }

        private func fail(_ error: Error) {
            lock.lock()
            if finished { lock.unlock(); return }
            finished = true
            deadline?.cancel()
            lock.unlock()
            kill()
            continuation.finish(throwing: error)
        }

        func stop() {
            lock.lock()
            let wasFinished = finished
            finished = true
            deadline?.cancel()
            lock.unlock()
            if !wasFinished { kill() }
        }

        private func kill() {
            lock.lock(); let held = heldInput; heldInput = nil; lock.unlock()
            try? held?.close()
            (process.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
            (process.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
            // Signal the whole group, even after the child itself exited: a job
            // it left in the background (still holding the output pipe) stops
            // too, and SIGKILL reaches any that ignore SIGTERM. A group's id
            // isn't reused while any member is alive.
            lock.lock(); let group = group; lock.unlock()
            if let group {
                Darwin.kill(-group, SIGTERM)
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { Darwin.kill(-group, SIGKILL) }
                return
            }
            guard process.isRunning else { return }
            let pid = process.processIdentifier
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { [process] in
                if process.isRunning { Darwin.kill(pid, SIGKILL) }
            }
        }
    }
}
