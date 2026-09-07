import Foundation

public enum JSONValue: Codable, Sendable, Equatable {
    case string(String), number(Double), bool(Bool), array([JSONValue]), object([String: JSONValue]), null
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    public subscript(_ key: String) -> JSONValue {
        if case .object(let v) = self { return v[key] ?? .null }; return .null
    }
    public var string: String? { if case .string(let s) = self { return s }; return nil }
    public func decode<T: Decodable>(_ type: T.Type) throws -> T { try JSONDecoder().decode(type, from: JSONEncoder().encode(self)) }
}

public enum APIResponse {
    public static func result(from data: Data, expectedID: String) throws -> JSONValue {
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        guard value["id"].string == expectedID else { throw HerdrError.message("Mismatched response from herdr") }
        if let message = value["error"]["message"].string { throw HerdrError.message(message) }
        guard case .object = value["result"] else { throw HerdrError.message("Invalid response from herdr") }
        return value["result"]
    }
}

/// Framing is byte based: UTF-8 characters may straddle reads from a pipe or socket.
public struct JSONLineBuffer {
    private var pending = Data()
    private let limit: Int
    public init(limit: Int = 48 * 1024 * 1024) { self.limit = limit }
    public mutating func append(_ data: Data) throws -> [Data] {
        pending.append(data)
        var result: [Data] = []
        while let end = pending.firstIndex(of: 10) {
            guard pending.distance(from: pending.startIndex, to: end) <= limit else { throw HerdrError.message("Herdr frame exceeds the size limit") }
            if end != pending.startIndex { result.append(Data(pending[..<end])) }
            pending.removeSubrange(...end)
        }
        guard pending.count <= limit else { throw HerdrError.message("Herdr frame exceeds the size limit") }
        return result
    }
}

public struct TerminalEnvelope: Decodable {
    public let type: String
    public let reason: String?
    public let bytes: String?
    public let width: Int?
    public let height: Int?
    public let seq: UInt64?
    public let full: Bool?
    public func decodedBytes() throws -> Data {
        guard let bytes, let data = Data(base64Encoded: bytes) else { throw HerdrError.message("Invalid ANSI terminal frame") }
        return data
    }
}
