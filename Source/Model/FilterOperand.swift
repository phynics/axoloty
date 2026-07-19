//  Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
//
//  FilterOperand.swift
//  Axoloty

import Foundation

/// A JSON literal appearing as an operand in an ``ObjectFilterExpression``.
///
/// This is a closed model of the JSON literals a filter can carry — not a
/// general-purpose value box. It exists because a Coaty filter addresses
/// object properties by *string path* (e.g. `"object.logLabels.count"`),
/// resolved only at match time, so an operand's type cannot be known
/// statically at the call site.
///
/// - Important: Deliberately scoped to filtering. Do not use it to carry
///   application payloads; those are raw JSON strings decoded on demand.
/// - Important: ``int(_:)`` and ``double(_:)`` are distinct cases so that
///   `42` does not re-encode as `42.0`, which would break wire
///   compatibility against the CoatyJS reference and the fixture corpus.
/// - Important: Built only from stdlib types. Adding a Foundation type
///   (such as `Data`, `Date`, `URL`, or `Decimal`) to this enum's stored
///   shape breaks the Embedded Swift path tracked by #111.
public enum FilterOperand: Hashable, Sendable {
    /// A JSON string literal.
    case string(String)
    /// A JSON integer literal. Kept distinct from ``double(_:)`` so `42`
    /// round-trips without a decimal point.
    case int(Int)
    /// A JSON number with a fractional part. Kept distinct from ``int(_:)``
    /// so `42.5` round-trips with its decimal point.
    case double(Double)
    /// A JSON boolean literal.
    case bool(Bool)
    /// A JSON `null` literal.
    case null
    /// A JSON array, modeled recursively.
    case array([FilterOperand])
    /// A JSON object, modeled recursively.
    case object([String: FilterOperand])
}

extension FilterOperand: Codable {

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        // Ladder order is load-bearing and mirrors the behavior pinned in
        // `AnyCodableCharacterizationTests`:
        //  - `Bool` before `Int` so that `true` does not become `1`;
        //  - `Int` before `Double` so that `42` stays `42`, not `42.0`.
        // The *result* of each step is a closed case, not an `Any`, so the
        // recovered type depends on the ladder rather than on what was
        // encoded — but the ladder reproduces the pinned behavior.
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
        } else if let value = try? container.decode([FilterOperand].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: FilterOperand].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "FilterOperand value cannot be decoded")
        }
    }

    public func encode(to encoder: Encoder) throws {
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
