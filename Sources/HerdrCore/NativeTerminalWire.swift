import Foundation

/// The direct terminal wire contract is pinned to stock Herdr protocol 22.
enum NativeTerminalWire {
    static let wireLimit = 2 * 1_024 * 1_024
    static let inputLimit = 1_024 * 1_024
    static func failure(_ message: String = "Malformed native terminal message") -> HerdrError { .message(message) }
    static func integer(_ value: UInt64) -> Data {
        if value < 251 { return Data([UInt8(value)]) }
        let size = value <= UInt16.max ? 2 : value <= UInt32.max ? 4 : 8
        return Data([size == 2 ? 251 : size == 4 ? 252 : 253] + (0..<size).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }
    static func blob(_ data: Data) -> Data { integer(UInt64(data.count)) + data }
    static func string(_ value: String) -> Data { blob(Data(value.utf8)) }
    static func dimension(_ value: Int) -> UInt64 { UInt64(min(Int(UInt16.max), max(1, value))) }
    static func hello(cols: Int, rows: Int) -> Data { Data([0,22]) + integer(dimension(cols)) + integer(dimension(rows)) + Data([0,0,0]) }
    static func resize(cols: Int, rows: Int) -> Data { Data([3]) + integer(dimension(cols)) + integer(dimension(rows)) + Data([0,0,0]) }
    static func control(pane: String, takeover: Bool) -> Data { Data([8]) + string(pane) + Data([takeover ? 1 : 0]) }
    static func scroll(_ delta: Double) -> Data {
        let lines = UInt64(min(100, max(1, abs(delta))))
        return Data([6,0,delta > 0 ? 0 : 1]) + integer(lines) + Data([0,0,0])
    }
    static func packet(_ message: Data) throws -> Data {
        guard !message.isEmpty, message.count <= wireLimit else { throw failure("Native terminal message exceeds 2 MiB") }
        let n = UInt32(message.count)
        return Data((0..<4).map { UInt8(truncatingIfNeeded: n >> ($0 * 8)) }) + message
    }
    static func input(_ bytes: Data) throws -> Data {
        guard bytes.count <= inputLimit else { throw failure("Native terminal input exceeds 1 MiB") }
        // Ghostty emits each mouse report as one write. Paste envelopes and ordinary keys
        // must remain raw input, even when they contain text resembling mouse reports.
        guard bytes.starts(with: [27,91,60]), let last = bytes.last, last == 77 || last == 109,
              let report = String(data: bytes.dropFirst(3).dropLast(), encoding: .ascii),
              report.allSatisfy({ $0.isNumber || $0 == ";" }) else { return Data([1]) + blob(bytes) }
        let fields = report.split(separator: ";", omittingEmptySubsequences: false)
        guard fields.count == 3, let cb = UInt16(fields[0]), cb < 128,
              let col = UInt32(fields[1]), let row = UInt32(fields[2]),
              (1...65_536).contains(col), (1...65_536).contains(row) else { throw failure("Invalid SGR mouse report") }
        let button = cb & 3
        let modifiers = UInt8((cb & 4 != 0 ? 1 : 0) | (cb & 8 != 0 ? 2 : 0) | (cb & 16 != 0 ? 4 : 0))
        var kind: Data
        if cb & 64 != 0 {
            guard last == 77 else { throw failure("Invalid mouse wheel release") }
            kind = Data([UInt8(4 + button)])
        } else if cb & 32 != 0 && button == 3 {
            kind = Data([3])
        } else {
            guard button < 3 else { throw failure("Invalid SGR mouse button") }
            let mapped: UInt8 = button == 1 ? 2 : button == 2 ? 1 : 0
            kind = Data([last == 109 ? 1 : cb & 32 != 0 ? 2 : 0, mapped])
        }
        return Data([16]) + kind + Data([0]) + integer(UInt64(col - 1)) + integer(UInt64(row - 1)) + Data([0, modifiers, 1])
    }
    static func endpoint(kind: String, json: [String: Any]) throws -> Data {
        Data([20]) + string(kind) + blob(try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]))
    }
    static func shellHello(cols: Int, rows: Int) throws -> Data {
        try endpoint(kind: "endpoint.hello.v1", json: [
            "generation": 1, "cell_width_px": 0, "cell_height_px": 0,
            "surface_size": ["cols": dimension(cols), "rows": dimension(rows)],
            "pixel_mouse": false, "direct_graphics": false, "endpoint_keybindings": false,
            "mouse_capture": false, "surface_active": true,
            "snapshot_codecs": ["shell.snapshot.v1"], "surface_codecs": ["shell.surface.v1"],
            "input_codecs": ["shell.input.semantic.v1"], "blob_codecs": ["shell.blob.v1"]])
    }
    static func focus(boot: String, pane: String, id: String) throws -> Data {
        Data([15]) + string(boot) + blob(try JSONSerialization.data(withJSONObject: ["id": id, "method": "pane.focus", "params": ["pane_id": pane]], options: [.sortedKeys]))
    }
    enum Message: Equatable {
        case welcome, ignored
        case frame(Data), clipboard(Data), mouseCapture(Bool), error(String), shutdown(String)
        case endpoint(String, String)
        case response(boot: String, id: String, final: Bool, bytes: Data)
    }
    static func decode(_ data: Data) throws -> Message {
        guard data.count <= wireLimit else { throw failure() }
        var r = Reader(data: data)
        let tag = try r.uint(max: 20)
        let result: Message
        switch tag {
        case 0:
            let version = try r.uint(max: UInt64(UInt32.max))
            let encoding = try r.uint(max: 1)
            let error = try r.optionalString()
            guard error == nil else { throw failure(error!) }
            guard version == 22, encoding == 1 else { throw failure("Unsupported native terminal protocol or encoding") }
            result = .welcome
        case 1:
            _ = try r.uint(); _ = try r.uint(max: 65535); _ = try r.uint(max: 65535); _ = try r.bool()
            result = .frame(try r.blob())
        case 2: _ = try r.blob(); result = .ignored
        case 3: result = .shutdown(try r.optionalString() ?? "Herdr closed the terminal connection")
        case 4: _ = try r.uint(max: 2); _ = try r.string(); _ = try r.optionalString(); result = .ignored
        case 5:
            let encoded = try r.string()
            guard let decoded = Data(base64Encoded: encoded), decoded.count <= inputLimit else { throw failure("Invalid native terminal clipboard data") }
            result = .clipboard(decoded)
        case 6: _ = try r.optionalString(); result = .ignored
        case 7: result = .ignored
        case 8: let enabled = try r.bool(); _ = try r.bool(); result = .mouseCapture(enabled)
        case 9: _ = try r.uint(max: 65535); result = .ignored
        case 11: _ = try r.uint(); _ = try r.uint(max: UInt64(UInt32.max)); result = .ignored
        case 15: result = .error(try r.string())
        case 16: _ = try r.uint(max: 65535); _ = try r.byte(); result = .ignored
        case 17: _ = try r.bool(); result = .ignored
        case 18: result = .response(boot: try r.string(), id: try r.string(), final: try r.bool(), bytes: try r.blob())
        case 20: result = .endpoint(try r.string(), try r.string())
        // Semantic surfaces and notifications are irrelevant on the clipboard lane.
        // Their private nested schemas are deliberately not decoded or acted upon.
        case 10, 12, 13, 14, 19: return .ignored
        default: throw failure()
        }
        guard r.offset == data.count else { throw failure("Trailing bytes in native terminal message") }
        return result
    }
    struct Reader {
        let data: Data
        var offset = 0
        mutating func byte() throws -> UInt8 {
            guard offset < data.count else { throw NativeTerminalWire.failure("Truncated native terminal message") }
            defer { offset += 1 }; return data[data.startIndex + offset]
        }
        mutating func uint(max: UInt64 = .max) throws -> UInt64 {
            let marker = try byte()
            let value: UInt64
            if marker < 251 { value = UInt64(marker) }
            else {
                guard marker <= 253 else { throw NativeTerminalWire.failure("Unsupported native terminal integer") }
                let length = marker == 251 ? 2 : marker == 252 ? 4 : 8
                var n: UInt64 = 0
                for shift in 0..<length { n |= UInt64(try byte()) << (shift * 8) }
                value = n
            }
            guard value <= max else { throw NativeTerminalWire.failure("Native terminal integer out of range") }
            return value
        }
        mutating func bool() throws -> Bool {
            let value = try byte(); guard value < 2 else { throw NativeTerminalWire.failure("Invalid native terminal boolean") }; return value == 1
        }
        mutating func blob() throws -> Data {
            let length = Int(try uint(max: UInt64(NativeTerminalWire.wireLimit)))
            guard length <= data.count - offset else { throw NativeTerminalWire.failure("Truncated native terminal data") }
            defer { offset += length }; return Data(data[(data.startIndex + offset)..<(data.startIndex + offset + length)])
        }
        mutating func string() throws -> String {
            guard let string = String(data: try blob(), encoding: .utf8) else { throw NativeTerminalWire.failure("Invalid native terminal UTF-8") }; return string
        }
        mutating func optionalString() throws -> String? { try bool() ? string() : nil }
    }
}

struct NativeTerminalFramer {
    private var bytes = Data()
    mutating func append(_ incoming: Data) throws -> [Data] {
        bytes.append(incoming)
        var output = [Data]()
        var offset = 0
        while bytes.count - offset >= 4 {
            let start = bytes.startIndex + offset
            let n = (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[start + $1]) << ($1 * 8) }
            guard n > 0, n <= NativeTerminalWire.wireLimit else { throw NativeTerminalWire.failure("Native terminal frame exceeds 2 MiB or is empty") }
            guard bytes.count - offset - 4 >= Int(n) else { break }
            output.append(Data(bytes[(start + 4)..<(start + 4 + Int(n))]))
            offset += 4 + Int(n)
        }
        if offset > 0 { bytes.removeFirst(offset) }
        guard bytes.count <= NativeTerminalWire.wireLimit + 4 else { throw NativeTerminalWire.failure() }
        return output
    }
}
