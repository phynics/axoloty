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

// MARK: - Comparable

extension FilterOperand: Comparable {

    /// Ordering mirrors the pinned `AnyCodable` behavior: same-type
    /// comparisons use the native operator (strings use
    /// `localizedCompare`), cross-type pairs return `false`.
    public static func < (lhs: FilterOperand, rhs: FilterOperand) -> Bool {
        switch (lhs, rhs) {
        case let (.int(l), .int(r)):
            return l < r
        case let (.double(l), .double(r)):
            return l < r
        case let (.bool(l), .bool(r)):
            return l == false && r == true
        case let (.string(l), .string(r)):
            return l.localizedCompare(r) == .orderedAscending
        default:
            return false
        }
    }
}

// MARK: - ExpressibleByLiteral (test ergonomics)

extension FilterOperand: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) { self = .null }
}

extension FilterOperand: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension FilterOperand: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self = .int(value) }
}

extension FilterOperand: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .double(value) }
}

extension FilterOperand: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension FilterOperand: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: FilterOperand...) { self = .array(elements) }
}

// MARK: - CoatyObject bridge

extension FilterOperand {

    /// Creates a string operand from a ``CoatyUUID``, normalizing to the
    /// lowercase string form — matching how ``AnyCodable`` stores UUIDs and
    /// how CoatyJS represents them on the wire (JSON has no UUID type).
    public init(_ uuid: CoatyUUID) {
        self = .string(uuid.string)
    }

    /// Creates a string operand from a non-literal `String` value.
    public init(_ string: String) {
        self = .string(string)
    }

    /// Converts a ``CoatyObject`` to a ``FilterOperand.object`` by reflecting
    /// its properties.
    ///
    /// A ``CoatyUUID`` is stored as its lowercase string, matching the
    /// normalization ``AnyCodable`` performs: a UUID property and a
    /// wire-decoded string operand compare equal. Optional properties that
    /// are `nil` are omitted (treated as absent), preserving the
    /// `.NotExists` semantics pinned in Phase 1.
    public init(_ coatyObject: CoatyObject) {
        let mirror = Mirror(reflecting: coatyObject)
        var dict: [String: FilterOperand] = [:]
        for child in mirror.children {
            guard let label = child.label else { continue }
            if let value = FilterOperand.from(child.value) {
                dict[label] = value
            }
        }
        if let superMirror = mirror.superclassMirror {
            for child in superMirror.children {
                guard let label = child.label else { continue }
                if dict[label] == nil, let value = FilterOperand.from(child.value) {
                    dict[label] = value
                }
            }
        }
        self = .object(dict)
    }
}

extension FilterOperand {

    /// Converts a reflected `Any` value to a `FilterOperand`, returning
    /// `nil` for values that cannot be represented (including
    /// `Optional.none`, which is treated as absent to preserve
    /// `.NotExists` semantics).
    internal static func from(_ value: Any) -> FilterOperand? {
        // Mirror reflects optionals with displayStyle .optional; unwrap
        // .some and return nil for .none.
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .optional {
            guard let unwrapped = mirror.children.first?.value else { return nil }
            return FilterOperand.from(unwrapped)
        }
        if let v = value as? Bool { return .bool(v) }
        if let v = value as? Int { return .int(v) }
        if let v = value as? Double { return .double(v) }
        if let v = value as? String { return .string(v) }
        if let v = value as? CoatyUUID { return .string(v.string) }
        if let v = value as? CoatyObject { return FilterOperand(v) }
        if let v = value as? [Any] {
            return .array(v.compactMap { FilterOperand.from($0) })
        }
        if let v = value as? [String: Any] {
            var dict: [String: FilterOperand] = [:]
            for (key, val) in v {
                if let converted = FilterOperand.from(val) {
                    dict[key] = converted
                }
            }
            return .object(dict)
        }
        return nil
    }
}

// MARK: - Containment operations

extension FilterOperand {

    /// Checks if a value (usually an object or array) contains another value.
    ///
    /// Primitive value types contain only the identical value. Object
    /// properties match if all the key-value pairs of the contained object
    /// are present in the containing object. Array properties match if all
    /// specified array elements are contained in them.
    ///
    /// As a special exception, an array at the top level may contain a
    /// primitive value: `contains([1, 2, 3], 3)` returns `true`.
    internal static func deepContains(_ a: FilterOperand, _ b: FilterOperand) -> Bool {
        FilterOperand._deepContains(a, b, isTopLevel: true)
    }

    /// Checks if a value is included at the top level in the given array,
    /// compared using equality.
    internal static func deepIncludes(_ array: FilterOperand, _ value: FilterOperand) -> Bool {
        guard case .array(let elements) = array else { return false }
        return elements.contains { $0 == value }
    }

    private static func _deepContains(
        _ x: FilterOperand,
        _ y: FilterOperand,
        isTopLevel: Bool
    ) -> Bool {
        switch (x, y) {
        case (.array(let xValues), .array(let yValues)):
            return yValues.allSatisfy { yv in
                xValues.contains { xv in
                    FilterOperand._deepContains(xv, yv, isTopLevel: false)
                }
            }
        case (.array(let xValues), _):
            // Special exception: a primitive on the top level is contained
            // if it matches any element.
            if isTopLevel {
                return xValues.contains { $0 == y }
            }
            return false
        case (.object(let xDict), .object(let yDict)):
            return xDict.keys.allSatisfy { xk in
                guard let yv = yDict[xk] else { return false }
                return FilterOperand._deepContains(xDict[xk]!, yv, isTopLevel: false)
            }
        default:
            return x == y
        }
    }
}
