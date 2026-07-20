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
