import Foundation

/// A minimal, Codable representation of arbitrary JSON. Used to preserve the
/// full payload of a node whose `type` this build doesn't recognize, so an
/// older app can open — and losslessly re-save — a flow created by a newer one
/// without discarding the unknown node. (Number precision is limited to what a
/// `Double` can hold, which covers every field this app persists today.)
public enum JSONValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Value is not valid JSON."
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    /// Convenience: the string at `key` if this is an object holding a string.
    public func string(_ key: String) -> String? {
        if case .object(let dict) = self, case .string(let value)? = dict[key] {
            return value
        }
        return nil
    }
}

// MARK: - Keys this build doesn't know

/// A coding key for any string, so a decoder can list an object's keys and an
/// encoder can write arbitrary ones back.
struct AnyCodingKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }

    init(_ stringValue: String) { self.stringValue = stringValue }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

extension Decoder {
    /// Every key of the object being decoded that isn't in `known`, kept as raw
    /// JSON. This is how a flow saved by a newer build keeps the fields this
    /// build doesn't understand through an open/save round-trip.
    func unknownFields(excluding known: Set<String>) throws -> [String: JSONValue] {
        let container = try self.container(keyedBy: AnyCodingKey.self)
        var extras: [String: JSONValue] = [:]
        for key in container.allKeys where !known.contains(key.stringValue) {
            extras[key.stringValue] = try container.decode(JSONValue.self, forKey: key)
        }
        return extras
    }
}

extension Encoder {
    /// Writes preserved unknown fields into the object being encoded. Call it
    /// after the known keys; a key in `known` is never overwritten, so the
    /// value this build owns always wins.
    func encodeUnknownFields(_ extras: [String: JSONValue], excluding known: Set<String>) throws {
        guard !extras.isEmpty else { return }
        var container = self.container(keyedBy: AnyCodingKey.self)
        for (key, value) in extras where !known.contains(key) {
            try container.encode(value, forKey: AnyCodingKey(key))
        }
    }
}
