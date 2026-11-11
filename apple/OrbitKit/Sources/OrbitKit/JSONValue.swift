import Foundation

/// Arbitrary JSON (task params/results, metadata) that round-trips losslessly.
public enum JSONValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    /// Key lookup. The shared decoder converts snake_case keys to camelCase — including keys inside
    /// arbitrary JSON objects — so lookups accept the server's snake_case name and try both forms.
    public subscript(key: String) -> JSONValue? {
        guard case .object(let o) = self else { return nil }
        return o[key] ?? o[JSONValue.camelCase(key)]
    }

    static func camelCase(_ s: String) -> String {
        let parts = s.split(separator: "_", omittingEmptySubsequences: true)
        guard let first = parts.first else { return s }
        return String(first) + parts.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
    }
    public var string: String? { if case .string(let s) = self { return s }; return nil }
    public var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var number: Double? { if case .number(let n) = self { return n }; return nil }
    public var array: [JSONValue]? { if case .array(let a) = self { return a }; return nil }

    /// Compact human-readable rendering for UI.
    public var display: String {
        switch self {
        case .null: return "—"
        case .bool(let b): return b ? "yes" : "no"
        case .number(let n): return n.rounded() == n ? String(Int64(n)) : String(n)
        case .string(let s): return s
        default:
            let data = (try? JSONEncoder.orbit.encode(self)) ?? Data()
            return String(decoding: data, as: UTF8.self)
        }
    }
}

extension JSONEncoder {
    public static let orbit: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.outputFormatting = [.sortedKeys]
        return e
    }()
}

extension JSONDecoder {
    public static let orbit: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()
}
