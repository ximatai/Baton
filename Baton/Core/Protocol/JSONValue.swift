import Foundation

enum JSONValue: Codable, Equatable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null
    init(from decoder: Decoder) throws { let c = try decoder.singleValueContainer(); if c.decodeNil() { self = .null } else if let v = try? c.decode(Bool.self) { self = .bool(v) } else if let v = try? c.decode(Double.self) { self = .number(v) } else if let v = try? c.decode(String.self) { self = .string(v) } else if let v = try? c.decode([String: JSONValue].self) { self = .object(v) } else { self = .array(try c.decode([JSONValue].self)) } }
    func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); switch self { case .string(let v): try c.encode(v); case .number(let v): try c.encode(v); case .bool(let v): try c.encode(v); case .object(let v): try c.encode(v); case .array(let v): try c.encode(v); case .null: try c.encodeNil() } }
    var string: String? { if case .string(let value) = self { value } else { nil } }
    var object: [String: JSONValue]? { if case .object(let value) = self { value } else { nil } }
    var foundationValue: Any { switch self { case .string(let v): v; case .number(let v): v; case .bool(let v): v; case .object(let v): v.mapValues(\.foundationValue); case .array(let v): v.map(\.foundationValue); case .null: NSNull() } }
}
