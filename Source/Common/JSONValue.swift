// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
//
//  JSONValue.swift
//  Axoloty

import Foundation

/// A closed representation of an arbitrary JSON value, used internally to
/// capture and re-emit JSON structure without routing through `Any`.
///
/// `JSONValue` never appears in a public signature (see #110). It exists only
/// because `Foundation.JSONDecoder` provides no raw-text access, so isolating
/// an already-decoded field's JSON substructure requires decoding into *some*
/// value model before re-encoding it.
///
/// - Important: Scoped to payload capture. ``FilterOperand`` is the sibling
///   type for filter operands; the two are kept separate deliberately so
///   neither drifts into a general-purpose value box.
/// - Important: ``int(_:)`` and ``double(_:)`` are distinct cases so that
///   `42` does not re-encode as `42.0`, which would break wire compatibility
///   against the CoatyJS reference and the fixture corpus.
/// - Important: Built only from stdlib types. Adding a Foundation type (such
///   as `Data`, `Date`, `URL`, or `Decimal`) to this enum's stored shape
///   breaks the Embedded Swift path tracked by #111.
enum JSONValue: Equatable {
    /// A JSON `null` literal.
    case null
    /// A JSON boolean literal.
    case bool(Bool)
    /// A JSON integer literal. Kept distinct from ``double(_:)`` so `42`
    /// round-trips without a decimal point.
    case int(Int)
    /// A JSON number with a fractional part. Kept distinct from ``int(_:)``
    /// so `42.5` round-trips with its decimal point.
    case double(Double)
    /// A JSON string literal.
    case string(String)
    /// A JSON array, modeled recursively.
    case array([JSONValue])
    /// A JSON object, modeled recursively.
    case object([String: JSONValue])
}

extension JSONValue: Codable {

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        // Ladder order is load-bearing and mirrors the behavior pinned for
        // `FilterOperand`/`AnyCodable`:
        //  - `Bool` before `Int` so that `true` does not become `1`;
        //  - `Int` before `Double` so that `42` stays `42`, not `42.0`.
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "JSONValue value cannot be decoded")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        case .double(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }
}

extension JSONValue {

    /// Creates a `JSONValue` from an `Any` value, trying the most specific
    /// JSON-compatible type first.
    ///
    /// Returns `nil` for values that cannot be represented as JSON. The type
    /// ladder mirrors the one pinned for `AnyCodable`: `Bool` before `Int` so
    /// that `true` does not become `1`, and `Int` before `Double` so that `42`
    /// stays `42`, not `42.0`.
    ///
    /// - Parameter value: An `Any` value to pack as `JSONValue`.
    init?(any value: Any) {
        if value is NSNull {
            self = .null
        } else if let v = value as? Bool {
            self = .bool(v)
        } else if let v = value as? Int {
            self = .int(v)
        } else if let v = value as? Double {
            self = .double(v)
        } else if let v = value as? String {
            self = .string(v)
        } else if let v = value as? [Any] {
            self = .array(v.map { JSONValue(any: $0) ?? .null })
        } else if let v = value as? [String: Any] {
            self = .object(v.mapValues { JSONValue(any: $0) ?? .null })
        } else {
            return nil
        }
    }

    /// Decodes a field from a keyed decoding container as raw JSON text.
    ///
    /// This is the decode-side half of the "store raw JSON `String`" pattern:
    /// the field is decoded into a ``JSONValue`` (the internal value model) and
    /// re-encoded to `String`, preserving the JSON structure without routing
    /// through `Any`. Used by types whose wire encoding requires a raw JSON
    /// value (object, array, number, etc.) rather than a JSON string.
    ///
    /// - Parameters:
    ///   - container: The keyed decoding container to read from.
    ///   - key: The coding key of the field to decode.
    /// - Returns: The raw JSON text of the decoded field.
    /// - Throws: A ``DecodingError`` if the field cannot be decoded as a
    ///   ``JSONValue``.
    static func decodeRawString<K: CodingKey>(
        from container: KeyedDecodingContainer<K>,
        forKey key: K
    ) throws -> String {
        let value = try container.decode(JSONValue.self, forKey: key)
        let data = try JSONEncoder().encode(value)
        // JSON produced by `JSONEncoder` is always valid UTF-8 by spec.
        return String(data: data, encoding: .utf8)!
    }

    /// Encodes a raw JSON `String` into a keyed encoding container.
    ///
    /// This is the encode-side half of the "store raw JSON `String`" pattern:
    /// the `String` is parsed into a ``JSONValue`` (the internal value model)
    /// and then encoded, so it appears as a raw JSON value on the wire rather
    /// than a JSON string literal.
    ///
    /// - Parameters:
    ///   - string: The raw JSON text to encode.
    ///   - container: The keyed encoding container to write into.
    ///   - key: The coding key of the field to encode.
    /// - Throws: An ``EncodingError`` if `string` is not valid JSON.
    static func encodeRawString<K: CodingKey>(
        _ string: String,
        to container: inout KeyedEncodingContainer<K>,
        forKey key: K
    ) throws {
        // `String.data(using: .utf8)` cannot fail for a Swift `String` —
        // Swift strings are always representable in UTF-8.
        let data = string.data(using: .utf8)!
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        try container.encode(value, forKey: key)
    }

    /// Decodes an optional field from a keyed decoding container as raw JSON
    /// text, or `nil` if the key is absent or the value is `null`.
    ///
    /// Optional-field counterpart to ``decodeRawString(from:forKey:)``.
    ///
    /// - Parameters:
    ///   - container: The keyed decoding container to read from.
    ///   - key: The coding key of the optional field to decode.
    /// - Returns: The raw JSON text of the decoded field, or `nil`.
    /// - Throws: A ``DecodingError`` if the field is present but cannot be
    ///   decoded as a ``JSONValue``.
    static func decodeRawStringIfPresent<K: CodingKey>(
        from container: KeyedDecodingContainer<K>,
        forKey key: K
    ) throws -> String? {
        guard let value = try container.decodeIfPresent(JSONValue.self, forKey: key) else {
            return nil
        }
        let data = try JSONEncoder().encode(value)
        return String(data: data, encoding: .utf8)!
    }

    /// Encodes an optional raw JSON `String` into a keyed encoding container,
    /// skipping the key entirely if the string is `nil`.
    ///
    /// Optional-field counterpart to ``encodeRawString(_:to:forKey:)``.
    ///
    /// - Parameters:
    ///   - string: The optional raw JSON text to encode.
    ///   - container: The keyed encoding container to write into.
    ///   - key: The coding key of the optional field to encode.
    /// - Throws: An ``EncodingError`` if `string` is non-nil but not valid
    ///   JSON.
    static func encodeRawStringIfPresent<K: CodingKey>(
        _ string: String?,
        to container: inout KeyedEncodingContainer<K>,
        forKey key: K
    ) throws {
        guard let string else { return }
        try encodeRawString(string, to: &container, forKey: key)
    }

    /// Serializes an `Any` value to raw JSON text.
    ///
    /// Used at boundaries that receive an untyped `Any` (e.g. ``SensorIo``
    /// read closures) and need to store it as raw JSON `String`. Returns
    /// `"null"` for values that cannot be represented as JSON.
    ///
    /// - Parameter value: An `Any` value to serialize.
    /// - Returns: The raw JSON text representation of `value`, or `"null"`.
    static func serialize(any value: Any) -> String {
        guard let jsonValue = JSONValue(any: value) else {
            return "null"
        }
        guard let data = try? JSONEncoder().encode(jsonValue),
              let string = String(data: data, encoding: .utf8) else {
            return "null"
        }
        return string
    }
}
