import Foundation
@testable import HerdrCore

enum NativeTerminalTests {
    static func run() throws {
        // Literal fixtures catch fixed-width encoding, tag drift, and coordinate/modifier errors.
        XCTAssertEqual(NativeTerminalWire.hello(cols: 300, rows: 24), Data([0,22,251,44,1,24,0,0,0]))
        XCTAssertEqual(try NativeTerminalWire.input(Data("\u{1b}[<0;11;6M".utf8)), Data([16,0,0,0,10,5,0,0,1]))
        XCTAssertEqual(try NativeTerminalWire.input(Data("\u{1b}[<52;11;6M".utf8)), Data([16,2,0,0,10,5,0,5,1]))
        XCTAssertEqual(try NativeTerminalWire.input(Data("\u{1b}[<0;11;6m".utf8)), Data([16,1,0,0,10,5,0,0,1]))
        XCTAssertEqual(try NativeTerminalWire.input(Data("\u{1b}[<35;1;1M".utf8)), Data([16,3,0,0,0,0,0,1]))
        XCTAssertEqual(try NativeTerminalWire.input(Data("\u{1b}[<65;2;3M".utf8)), Data([16,5,0,1,2,0,0,1]))
        let paste = Data("\u{1b}[200~\u{1b}[<0;11;6M\u{1b}[201~".utf8)
        XCTAssertEqual(try NativeTerminalWire.input(paste), Data([1,UInt8(paste.count)]) + paste)
        XCTAssertThrowsError(try NativeTerminalWire.input(Data(repeating: 65, count: 1_048_577)))
        XCTAssertThrowsError(try NativeTerminalWire.input(Data("\u{1b}[<0;0;1M".utf8)))
        var stream = NativeTerminalFramer()
        XCTAssertEqual(try stream.append(Data([4,0])).count, 0)
        XCTAssertEqual(try stream.append(Data([0,0,0,22])).count, 0)
        XCTAssertEqual(try stream.append(Data([1,0,3,0,0,0,8,1,0])), [Data([0,22,1,0]), Data([8,1,0])])
        var tooBig = NativeTerminalFramer()
        XCTAssertThrowsError(try tooBig.append(Data([1,0,32,0])))
        XCTAssertEqual(try NativeTerminalWire.decode(Data([0,22,1,0])), .welcome)
        XCTAssertEqual(try NativeTerminalWire.decode(Data([1,253,1,0,0,0,0,0,0,0,80,24,1,3,65,0xc3,0xa9])), .frame(Data([65,0xc3,0xa9])))
        XCTAssertEqual(try NativeTerminalWire.decode(Data([8,1,0])), .mouseCapture(true))
        XCTAssertEqual(try NativeTerminalWire.decode(Data([5,4,89,87,73,61])), .clipboard(Data("ab".utf8)))
        for bad: Data in [Data(), Data([8,2,0]), Data([8,1]), Data([8,1,0,1]), Data([1,0,80,24,1,5,65]), Data([0,21,1,0]), Data([5,1,255]), Data([5,1,63]), Data([255])] {
            XCTAssertThrowsError(try NativeTerminalWire.decode(bad))
        }
        print("PASS: native terminal wire, SGR mouse, fragmentation, and malformed payload tests")
    }
}

// Real Unix peer exercises transport ordering, endpoint focus, clipboard gating, and close.
// Payload expectations are independent of the production encoder.
private final class NativeEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events = [NativeTerminalEvent]()
    func append(_ event: NativeTerminalEvent) { lock.lock(); events.append(event); lock.unlock() }
    func contains(_ predicate: (NativeTerminalEvent) -> Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }; return events.contains(where: predicate)
    }
    func wait(_ predicate: (NativeTerminalEvent) -> Bool) throws {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if contains(predicate) { return }
            Thread.sleep(forTimeInterval: 0.01)
        }
        throw HerdrError.message("Native terminal fixture timed out waiting for event")
    }
}

extension NativeTerminalTests {
    static func runSocketLifecycle() throws {
        let root = "/tmp/hn-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let fixture = try NativeSocketFixture(path: root + "/herdr-client.sock")
        let log = NativeEventLog()
        let connection = NativeTerminalConnection(socketPath: root + "/herdr.api", pane: "w1:p1", cols: 80, rows: 24, takeover: false) { log.append($0) }
        defer { connection.stop() }
        connection.setFocused(true)
        connection.send(Data("a".utf8))
        connection.start()
        let direct = try fixture.accept()
        defer { Darwin.close(direct) }
        XCTAssertEqual(try fixture.receive(direct), Data([0,22,80,24,0,0,0]))
        try fixture.send(direct, [0,22,1,0], fragmented: true)
        XCTAssertEqual(try fixture.receive(direct), Data([8,5,119,49,58,112,49,0]))
        XCTAssertTrue(!fixture.readable(fixture.listener, milliseconds: 50))
        try fixture.send(direct, [1,0,80,24,1,0])
        let shell = try fixture.accept()
        defer { Darwin.close(shell) }
        var hello = NativeTerminalWire.Reader(data: try fixture.receive(shell))
        XCTAssertEqual(try hello.uint(), 20)
        XCTAssertEqual(try hello.string(), "endpoint.hello.v1")
        let helloObject = try JSONSerialization.jsonObject(with: Data(try hello.string().utf8)) as! [String: Any]
        XCTAssertEqual(helloObject["generation"] as? Int, 1)
        XCTAssertEqual(helloObject["direct_graphics"] as? Bool, false)
        XCTAssertEqual(helloObject["surface_active"] as? Bool, true)
        XCTAssertTrue(!fixture.readable(direct, milliseconds: 50))
        try fixture.control(shell, kind: "endpoint.welcome.v1", json: #"{"generation":1}"#)
        try fixture.control(shell, kind: "shell.snapshot.v1", json: #"{"boot_id":"boot"}"#)
        var focus = NativeTerminalWire.Reader(data: try fixture.receive(shell))
        XCTAssertEqual(try focus.uint(), 15)
        XCTAssertEqual(try focus.string(), "boot")
        let request = try JSONSerialization.jsonObject(with: Data(try focus.string().utf8)) as! [String: Any]
        XCTAssertEqual(request["method"] as? String, "pane.focus")
        XCTAssertEqual((request["params"] as? [String: String])?["pane_id"], "w1:p1")
        let id = request["id"] as! String
        // Clipboard before the stable-pane focus acknowledgement must never be delivered.
        try fixture.send(shell, [5,4,98,50,120,107]) // "old"
        XCTAssertTrue(!fixture.readable(direct, milliseconds: 50))
        let response = Data("{\"id\":\"\(id)\",\"result\":{\"type\":\"ok\"}}".utf8)
        try fixture.send(shell, Data([18]) + fixture.string("boot") + fixture.string(id) + Data([1]) + fixture.blob(response))
        try log.wait { if case .clipboardReady(true) = $0 { return true }; return false }
        XCTAssertEqual(try fixture.receive(direct), Data([1,1,97]))
        try fixture.send(shell, [5,4,98,109,86,51]) // "new"
        try log.wait { if case .clipboard(let data) = $0 { return data == Data("new".utf8) }; return false }
        XCTAssertTrue(!log.contains { if case .clipboard(let data) = $0 { return data == Data("old".utf8) }; return false })
        connection.resize(cols: 300, rows: 40)
        connection.scroll(delta: -2)
        connection.send(Data("\u{1b}[<0;11;6M".utf8))
        XCTAssertEqual(try fixture.receive(direct), Data([3,251,44,1,40,0,0,0]))
        XCTAssertEqual(try fixture.receive(direct), Data([6,0,1,2,0,0,0]))
        XCTAssertEqual(try fixture.receive(direct), Data([16,0,0,0,10,5,0,0,1]))
        try fixture.send(direct, [8,1,0])
        try fixture.send(direct, [1,1,80,24,1,2,79,75], fragmented: true)
        try log.wait { if case .mouseCapture(true) = $0 { return true }; return false }
        try log.wait { if case .frame(let bytes) = $0 { return bytes == Data("OK".utf8) }; return false }
        connection.setFocused(false)
        try log.wait { if case .clipboardReady(false) = $0 { return true }; return false }
        XCTAssertTrue(fixture.readable(shell, milliseconds: 1000))
        var byte: UInt8 = 0
        XCTAssertEqual(Darwin.read(shell, &byte, 1), 0)
        let detached = DispatchGroup()
        detached.enter()
        DispatchQueue.global().async {
            defer { detached.leave() }
            do {
                XCTAssertEqual(try fixture.receive(direct), Data([4]))
                try fixture.send(direct, [3,0])
            } catch { log.append(.error(error.localizedDescription)) }
        }
        connection.stop()
        detached.wait()
        XCTAssertTrue(fixture.readable(direct, milliseconds: 0))
        XCTAssertEqual(Darwin.read(direct, &byte, 1), 0)
        XCTAssertTrue(!log.contains { if case .error = $0 { return true }; return false })
        // Even an API filename ending in -client.sock still has its own derived client path.
        let alternate = try NativeSocketFixture(path: root + "/api-client-client.sock")
        let second = NativeTerminalConnection(socketPath: root + "/api-client.sock", pane: "w1:p1", cols: 80, rows: 24, takeover: false) { log.append($0) }
        second.start()
        let peer = try alternate.accept()
        defer { Darwin.close(peer) }
        XCTAssertEqual(try alternate.receive(peer), Data([0,22,80,24,0,0,0]))
        second.stop()
        XCTAssertTrue(alternate.readable(peer, milliseconds: 0))
        XCTAssertEqual(Darwin.read(peer, &byte, 1), 0)
        print("PASS: native socket paths, handshake, input order, focus clipboard gating, blur and cancellation")
    }
}

import Darwin
private final class NativeSocketFixture {
    let listener: Int32
    init(path: String) throws {
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw HerdrError.message("Fixture socket failed") }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX); address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path.utf8CString.map { UInt8(bitPattern: $0) }) }
        let status = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard status == 0, Darwin.listen(listener, 4) == 0 else { Darwin.close(listener); throw HerdrError.message("Fixture bind/listen failed") }
    }
    deinit { Darwin.close(listener) }
    func readable(_ fd: Int32, milliseconds: Int32) -> Bool {
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        return Darwin.poll(&descriptor, 1, milliseconds) > 0
    }
    func accept() throws -> Int32 {
        guard readable(listener, milliseconds: 5000) else { throw HerdrError.message("Fixture accept timed out") }
        let fd = Darwin.accept(listener, nil, nil)
        guard fd >= 0 else { throw HerdrError.message("Fixture accept failed") }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout.size(ofValue: one)))
        return fd
    }
    func receive(_ fd: Int32) throws -> Data {
        let prefix = [UInt8](try readExactly(fd, count: 4))
        let count = Int(prefix[0]) | Int(prefix[1]) << 8 | Int(prefix[2]) << 16 | Int(prefix[3]) << 24
        guard count < 2_097_152 else { throw HerdrError.message("Fixture received oversized frame") }
        return try readExactly(fd, count: count)
    }
    private func readExactly(_ fd: Int32, count: Int) throws -> Data {
        var output = Data()
        while output.count < count {
            var buffer = [UInt8](repeating: 0, count: count - output.count)
            let n = Darwin.read(fd, &buffer, buffer.count)
            guard n > 0 else { throw HerdrError.message("Fixture peer closed or timed out") }
            output.append(contentsOf: buffer.prefix(n))
        }
        return output
    }
    func blob(_ bytes: Data) -> Data {
        precondition(bytes.count < 251)
        return Data([UInt8(bytes.count)]) + bytes
    }
    func string(_ string: String) -> Data { blob(Data(string.utf8)) }
    func control(_ fd: Int32, kind: String, json: String) throws { try send(fd, Data([20]) + string(kind) + string(json)) }
    func send(_ fd: Int32, _ bytes: [UInt8], fragmented: Bool = false) throws { try send(fd, Data(bytes), fragmented: fragmented) }
    func send(_ fd: Int32, _ bytes: Data, fragmented: Bool = false) throws {
        let count = UInt32(bytes.count)
        let packet = Data((0..<4).map { UInt8(truncatingIfNeeded: count >> ($0 * 8)) }) + bytes
        var offset = 0
        while offset < packet.count {
            let n = packet.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!.advanced(by: offset), fragmented ? 1 : $0.count - offset) }
            guard n > 0 else { throw HerdrError.message("Fixture write failed") }
            offset += n
        }
    }
}
