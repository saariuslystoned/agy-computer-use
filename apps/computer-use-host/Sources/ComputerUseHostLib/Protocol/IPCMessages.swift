import Foundation

public struct IPCRequest: Codable {
    public let id: String
    public let method: String
    public let params: [String: AnyCodable]?

    public init(id: String, method: String, params: [String: AnyCodable]? = nil) {
        self.id = id
        self.method = method
        self.params = params
    }
}

public struct IPCResponse: Codable {
    public let id: String
    public let success: Bool
    public let data: [String: AnyCodable]?
    public let error: IPCErrorPayload?

    public init(id: String, success: Bool, data: [String: AnyCodable]? = nil, error: IPCErrorPayload? = nil) {
        self.id = id
        self.success = success
        self.data = data
        self.error = error
    }
}

public struct IPCErrorPayload: Codable {
    public let code: String
    public let message: String
    public let details: [String: String]?

    public init(code: String, message: String, details: [String: String]? = nil) {
        self.code = code
        self.message = message
        self.details = details
    }
}

// AnyCodable helper for heterogeneous JSON payloads in IPC
public enum AnyCodable: Codable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case dictionary([String: AnyCodable])
    case array([AnyCodable])
    case null

    public init(_ value: Any?) {
        guard let value = value else {
            self = .null
            return
        }
        if let string = value as? String {
            self = .string(string)
        } else if let bool = value as? Bool {
            self = .bool(bool)
        } else if let int = value as? Int {
            self = .int(int)
        } else if let double = value as? Double {
            self = .double(double)
        } else if let dict = value as? [String: Any] {
            var result: [String: AnyCodable] = [:]
            for (k, v) in dict {
                result[k] = AnyCodable(v)
            }
            self = .dictionary(result)
        } else if let arr = value as? [Any] {
            self = .array(arr.map { AnyCodable($0) })
        } else {
            self = .string(String(describing: value))
        }
    }

    public var rawValue: Any {
        switch self {
        case .string(let s): return s
        case .int(let i): return i
        case .double(let d): return d
        case .bool(let b): return b
        case .dictionary(let d): return d.mapValues { $0.rawValue }
        case .array(let a): return a.map { $0.rawValue }
        case .null: return NSNull()
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? container.decode(Int.self) {
            self = .int(i)
        } else if let d = try? container.decode(Double.self) {
            self = .double(d)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let arr = try? container.decode([AnyCodable].self) {
            self = .array(arr)
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            self = .dictionary(dict)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported AnyCodable format")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .int(let i): try container.encode(i)
        case .double(let d): try container.encode(d)
        case .bool(let b): try container.encode(b)
        case .dictionary(let d): try container.encode(d)
        case .array(let a): try container.encode(a)
        case .null: try container.encodeNil()
        }
    }
}
