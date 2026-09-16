import Foundation
import Darwin

public enum NativeTerminalEvent: Sendable {
    case frame(Data)
    case mouseCapture(Bool)
    case clipboard(Data)
    case clipboardReady(Bool)
    case error(String)
}

/// Stock Herdr protocol-22 control with a focused endpoint used only for clipboard writes.
/// A single worker owns all file descriptors; stop never closes a descriptor under a read.
public final class NativeTerminalConnection: @unchecked Sendable {
    private let socketPath: String
    private let pane: String
    private let takeover: Bool
    private let onEvent: @Sendable (NativeTerminalEvent) -> Void
    private let lock = NSLock()
    private var started = false
    private var stopped = false
    private var focused = false
    private var focusGeneration: UInt64 = 0
    private var cols: Int
    private var rows: Int
    private var commands = [Data]()
    private var commandBytes = 0
    private let workerKey = DispatchSpecificKey<Bool>()
    private let finished = DispatchGroup()
    private let queue = DispatchQueue(label: "dev.herdr.native.terminal", qos: .userInitiated)

    public init(socketPath: String, pane: String, cols: Int, rows: Int, takeover: Bool,
                onEvent: @escaping @Sendable (NativeTerminalEvent) -> Void) {
        self.socketPath = DeviceProfile.clientSocketPath(for: socketPath)
        self.pane = pane; self.cols = cols; self.rows = rows
        self.takeover = takeover; self.onEvent = onEvent
        queue.setSpecific(key: workerKey, value: true)
    }
    public func start() {
        lock.lock()
        guard !started, !stopped else { lock.unlock(); return }
        started = true
        finished.enter()
        lock.unlock()
        queue.async {
            defer { self.finished.leave() }
            self.run()
        }
    }
    public func send(_ data: Data) {
        guard !data.isEmpty else { return }
        do { try enqueue(NativeTerminalWire.input(data)) }
        catch { emit(.error(error.localizedDescription)) }
    }
    public func resize(cols: Int, rows: Int) {
        lock.lock(); self.cols = cols; self.rows = rows; lock.unlock()
        do { try enqueue(NativeTerminalWire.resize(cols: cols, rows: rows)) }
        catch { emit(.error(error.localizedDescription)) }
    }
    public func scroll(delta: Double) {
        guard delta.isFinite, delta != 0 else { return }
        do { try enqueue(NativeTerminalWire.scroll(delta)) }
        catch { emit(.error(error.localizedDescription)) }
    }
    public func setFocused(_ value: Bool) {
        lock.lock()
        let changed = focused != value
        if changed { focused = value; focusGeneration &+= 1 }
        lock.unlock()
        if changed && !value { emit(.clipboardReady(false)) }
    }
    public func stop() {
        lock.lock(); stopped = true; focused = false; focusGeneration &+= 1
        commands.removeAll(); commandBytes = 0; lock.unlock()
        // Reconnect must not race the prior server-side control lease. A callback on
        // this worker may stop itself, in which case completion follows its return.
        if DispatchQueue.getSpecific(key: workerKey) == nil { finished.wait() }
    }
    private var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    private func emit(_ event: NativeTerminalEvent, clipboardGeneration: UInt64? = nil) {
        lock.lock()
        let allowed = !stopped && (clipboardGeneration == nil || (focused && clipboardGeneration == focusGeneration))
        lock.unlock()
        if allowed { onEvent(event) }
    }
    private func enqueue(_ message: Data) throws {
        let packet = try NativeTerminalWire.packet(message)
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { return }
        guard commandBytes + packet.count <= NativeTerminalWire.wireLimit, commands.count < 4096 else {
            throw NativeTerminalWire.failure("Native terminal input queue is full")
        }
        commands.append(packet); commandBytes += packet.count
    }
    private func state(takeCommands: Bool, clipboardGeneration: UInt64? = nil) -> (Bool, UInt64, Int, Int, [Data]) {
        lock.lock(); defer { lock.unlock() }
        let mayTake = takeCommands && (!focused || clipboardGeneration == focusGeneration)
        let pending = mayTake ? commands : []
        if mayTake { commands.removeAll(keepingCapacity: true); commandBytes = 0 }
        return (focused, focusGeneration, cols, rows, pending)
    }
    private final class Lane {
        let fd: Int32
        var incoming = NativeTerminalFramer()
        var outgoing = Data()
        var writeDeadline: TimeInterval?
        var handshakeDeadline = ProcessInfo.processInfo.systemUptime + 5
        var welcomed = false
        var attached = false
        var boot: String?
        var focusRequest: String?
        var response = Data()
        var clipboardReady = false
        let generation: UInt64
        init(fd: Int32, generation: UInt64 = 0) { self.fd = fd; self.generation = generation }
        deinit { Darwin.close(fd) }
        func append(_ message: Data) throws { try appendPacket(NativeTerminalWire.packet(message)) }
        func appendPacket(_ packet: Data) throws {
            guard outgoing.count + packet.count <= NativeTerminalWire.wireLimit else { throw NativeTerminalWire.failure("Native terminal write queue is full") }
            if outgoing.isEmpty { writeDeadline = ProcessInfo.processInfo.systemUptime + 3 }
            outgoing.append(packet)
        }
    }
    private func connectLane(generation: UInt64 = 0) throws -> Lane {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw systemError("create native terminal socket") }
        let lane = Lane(fd: fd, generation: generation)
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { throw systemError("configure native terminal socket") }
        var one: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout.size(ofValue: one))) == 0 else { throw systemError("configure native terminal socket") }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX); address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let path = Array(socketPath.utf8CString)
        guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw NativeTerminalWire.failure("Native terminal socket path is too long") }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path.map { UInt8(bitPattern: $0) }) }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if result != 0 {
            guard errno == EINPROGRESS || errno == EAGAIN else { throw systemError("connect to herdr native terminal at \(socketPath)") }
            let deadline = ProcessInfo.processInfo.systemUptime + 3
            while true {
                guard !isStopped else { throw NativeTerminalWire.failure("Native terminal connection cancelled") }
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw NativeTerminalWire.failure("Native terminal connect timed out") }
                var pollfd = Darwin.pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                let ready = Darwin.poll(&pollfd, 1, 50)
                if ready < 0 && errno == EINTR { continue }
                guard ready >= 0 else { throw systemError("connect native terminal") }
                if ready > 0 {
                    var error: Int32 = 0; var size = socklen_t(MemoryLayout.size(ofValue: error))
                    guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) == 0, error == 0 else {
                        throw NativeTerminalWire.failure("Could not connect native terminal: \(String(cString: strerror(error == 0 ? errno : error)))")
                    }
                    break
                }
            }
        }
        return lane
    }
    private func run() {
        do {
            let direct = try connectLane()
            var shell: Lane?
            let initial = state(takeCommands: false)
            try direct.append(NativeTerminalWire.hello(cols: initial.2, rows: initial.3))
            while !isStopped {
                let current = state(takeCommands: false)
                // Preserve all input order while the focused clipboard endpoint is becoming
                // ready, so a first mouse release cannot outrun its OSC 52 recipient.
                // Each accepted batch fits the lane limit only once the previous batch
                // has drained. Keep new commands queued while a slow peer catches up.
                if direct.welcomed && direct.outgoing.isEmpty && (!current.0 || (shell?.clipboardReady == true && shell?.generation == current.1)) {
                    for packet in state(takeCommands: true, clipboardGeneration: shell?.clipboardReady == true ? shell?.generation : nil).4 { try direct.appendPacket(packet) }
                }
                if let active = shell, !current.0 || active.generation != current.1 { shell = nil }
                // Establish the resize owner before opening the foreground clipboard endpoint.
                if current.0, shell == nil, direct.attached, direct.outgoing.isEmpty {
                    let next = try connectLane(generation: current.1)
                    try next.append(NativeTerminalWire.shellHello(cols: current.2, rows: current.3))
                    shell = next
                }
                var lanes = [direct]
                if let shell { lanes.append(shell) }
                var descriptors = lanes.map { Darwin.pollfd(fd: $0.fd, events: Int16(POLLIN | ($0.outgoing.isEmpty ? 0 : POLLOUT)), revents: 0) }
                let ready = Darwin.poll(&descriptors, nfds_t(descriptors.count), 50)
                if ready < 0 && errno == EINTR { continue }
                guard ready >= 0 else { throw systemError("poll native terminal") }
                guard !isStopped else { break }
                for (index, lane) in lanes.enumerated() {
                    let flags = descriptors[index].revents
                    if flags & Int16(POLLOUT) != 0 { try flush(lane) }
                    if flags & Int16(POLLIN | POLLHUP) != 0 {
                        for message in try read(lane) {
                            if lane === direct { try receiveDirect(message, lane: direct) }
                            else { try receiveShell(message, lane: lane) }
                        }
                    }
                    if flags & Int16(POLLERR | POLLNVAL) != 0 { throw NativeTerminalWire.failure("Native terminal socket disconnected") }
                    let now = ProcessInfo.processInfo.systemUptime
                    if let deadline = lane.writeDeadline, now >= deadline { throw NativeTerminalWire.failure("Native terminal write timed out") }
                    if !lane.welcomed, now >= lane.handshakeDeadline { throw NativeTerminalWire.failure("Native terminal handshake timed out") }
                    if lane === direct, !lane.attached, now >= lane.handshakeDeadline { throw NativeTerminalWire.failure("Native terminal attach timed out") }
                    if lane !== direct, !lane.clipboardReady, now >= lane.handshakeDeadline { throw NativeTerminalWire.failure("Native terminal clipboard focus timed out") }
                }
            }
            shell = nil
            detach(direct)
        } catch {
            emit(.mouseCapture(false))
            emit(.clipboardReady(false))
            emit(.error(error.localizedDescription))
        }
        stop()
    }
    private func detach(_ lane: Lane) {
        guard lane.welcomed else { return }
        // Finish an in-flight packet before appending Detach. The server responds
        // with Shutdown after releasing its control lease; bound unresponsive peers.
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        do {
            try lane.append(Data([4]))
            while ProcessInfo.processInfo.systemUptime < deadline {
                var descriptor = Darwin.pollfd(fd: lane.fd, events: Int16(POLLIN | (lane.outgoing.isEmpty ? 0 : POLLOUT)), revents: 0)
                let ready = Darwin.poll(&descriptor, 1, 25)
                if ready < 0 && errno == EINTR { continue }
                guard ready >= 0 else { return }
                if descriptor.revents & Int16(POLLOUT) != 0 { try flush(lane) }
                if descriptor.revents & Int16(POLLIN | POLLHUP) != 0 {
                    if try read(lane).contains(where: { if case .shutdown = $0 { return true }; return false }) { return }
                }
                if descriptor.revents & Int16(POLLERR | POLLNVAL) != 0 { return }
            }
        } catch { /* Closing the descriptor also releases a broken connection. */ }
    }
    private func flush(_ lane: Lane) throws {
        guard !lane.outgoing.isEmpty else { return }
        let n = lane.outgoing.withUnsafeBytes { Darwin.write(lane.fd, $0.baseAddress!, $0.count) }
        if n < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) { return }
        guard n > 0 else { throw systemError("write native terminal") }
        lane.outgoing.removeFirst(n)
        if lane.outgoing.isEmpty { lane.writeDeadline = nil }
    }
    private func read(_ lane: Lane) throws -> [NativeTerminalWire.Message] {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        // One read per poll keeps cancellation responsive even during continuous output.
        let n = Darwin.read(lane.fd, &buffer, buffer.count)
        if n < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) { return [] }
        guard n > 0 else { throw n == 0 ? NativeTerminalWire.failure("Herdr closed the native terminal connection") : systemError("read native terminal") }
        return try lane.incoming.append(Data(buffer.prefix(n))).map { try NativeTerminalWire.decode($0) }
    }
    private func receiveDirect(_ message: NativeTerminalWire.Message, lane: Lane) throws {
        switch message {
        case .welcome:
            guard !lane.welcomed else { throw NativeTerminalWire.failure("Duplicate native terminal welcome") }
            lane.welcomed = true
            try lane.append(NativeTerminalWire.control(pane: pane, takeover: takeover))
        case .frame(let bytes):
            guard lane.welcomed else { throw NativeTerminalWire.failure("Native terminal frame before welcome") }
            lane.attached = true
            emit(.frame(bytes))
        case .mouseCapture(let enabled): emit(.mouseCapture(enabled))
        case .error(let message), .shutdown(let message): throw NativeTerminalWire.failure(message)
        default: break
        }
    }
    private func receiveShell(_ message: NativeTerminalWire.Message, lane: Lane) throws {
        // Blur invalidates this lane immediately, even before its descriptor is closed.
        let current = state(takeCommands: false)
        guard current.0, current.1 == lane.generation else { return }
        switch message {
        case .endpoint(let kind, let json):
            guard kind == "endpoint.welcome.v1" || kind == "shell.snapshot.v1" else { return }
            guard let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { throw NativeTerminalWire.failure("Invalid clipboard endpoint message") }
            if kind == "endpoint.welcome.v1" {
                if let error = object["error"] as? [String: Any] { throw NativeTerminalWire.failure(error["message"] as? String ?? "Clipboard endpoint rejected connection") }
                guard object["generation"] as? Int == 1 else { throw NativeTerminalWire.failure("Unsupported clipboard endpoint generation") }
                lane.welcomed = true
            } else if lane.focusRequest == nil {
                guard lane.welcomed, let boot = object["boot_id"] as? String, !boot.isEmpty else { throw NativeTerminalWire.failure("Clipboard endpoint omitted its boot identity") }
                let id = UUID().uuidString
                lane.boot = boot; lane.focusRequest = id
                try lane.append(NativeTerminalWire.focus(boot: boot, pane: pane, id: id))
            }
        case .response(let boot, let id, let final, let bytes):
            guard boot == lane.boot, id == lane.focusRequest else { return }
            guard lane.response.count + bytes.count <= NativeTerminalWire.inputLimit else { throw NativeTerminalWire.failure("Clipboard endpoint response exceeds 1 MiB") }
            lane.response.append(bytes)
            if final {
                _ = try APIResponse.result(from: lane.response, expectedID: id)
                lane.response.removeAll(); lane.clipboardReady = true
                emit(.clipboardReady(true), clipboardGeneration: lane.generation)
            }
        case .clipboard(let bytes):
            if lane.clipboardReady { emit(.clipboard(bytes), clipboardGeneration: lane.generation) }
        case .error(let message), .shutdown(let message): throw NativeTerminalWire.failure(message)
        default: break
        }
    }
    private func systemError(_ operation: String) -> HerdrError {
        .message("Could not \(operation): \(String(cString: strerror(errno)))")
    }
}
