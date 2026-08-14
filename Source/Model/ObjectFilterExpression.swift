//  Copyright (c) 2019 Siemens AG. Licensed under the MIT License.
//
//  ObjectFilterExpression.swift
//  Axoloty
//

import Foundation

/// A filter expression consisting of a filter operator and its operands.
///
/// Invalid operator/operand combinations are unrepresentable: each case
/// carries exactly the operands its operator requires. For example, `.between`
/// always has two operands, and `.exists` has none.
///
/// The wire format is the unkeyed `[operatorInt, op1?, op2?]` array
/// preserved from the CoatyJS reference; ``ObjectFilterOperator``'s raw
/// values are the wire contract.
///
/// Tip: use one of the typesafe `FilterOperations` functions to construct
/// an expression.
public enum ObjectFilterExpression: Codable, Equatable {

    // MARK: - Cases.

    /// Checks if the filter property is less than the given value.
    case lessThan(FilterOperand)

    /// Checks if the filter property is less than or equal to the given value.
    case lessThanOrEqual(FilterOperand)

    /// Checks if the filter property is greater than the given value.
    case greaterThan(FilterOperand)

    /// Checks if the filter property is greater than or equal to the given value.
    case greaterThanOrEqual(FilterOperand)

    /// Checks if the filter property is between the two given values.
    case between(FilterOperand, FilterOperand)

    /// Checks if the filter property is not between the two given values.
    case notBetween(FilterOperand, FilterOperand)

    /// Checks if the filter property string matches the given pattern.
    ///
    /// The `matcher` is compiled once at decode time and carries no
    /// additional wire data; it is `nil` if the pattern could not be compiled.
    case like(pattern: String, matcher: NSRegularExpression?)

    /// Checks if the filter property is deep equal to the given value.
    case equals(FilterOperand)

    /// Checks if the filter property is not deep equal to the given value.
    case notEquals(FilterOperand)

    /// Checks if the filter property exists.
    case exists

    /// Checks if the filter property doesn't exist.
    case notExists

    /// Checks containment: strings use substring matching; arrays contain every requested
    /// element; and objects contain every requested key-value pair, recursively. Other
    /// primitive values require equality.
    case contains(FilterOperand)

    /// Checks if the candidate property value does not contain the requested
    /// value according to ``contains(_:)`` semantics.
    case notContains(FilterOperand)

    /// Checks if the filter property value is included in the given array.
    case valuesIn([FilterOperand])

    /// Checks if the filter property value is not included in the given array.
    case valuesNotIn([FilterOperand])

    // MARK: - Convenience factory for Like (compiles the pattern).

    /// Creates a `.like` expression, compiling the pattern immediately.
    public static func like(_ pattern: String) -> ObjectFilterExpression {
        .like(pattern: pattern, matcher: ObjectMatcher._createLikeRegexp(pattern: pattern))
    }

    // MARK: - Equatable (matcher is ignored for .like — only the pattern matters).

    public static func == (lhs: ObjectFilterExpression, rhs: ObjectFilterExpression) -> Bool {
        switch (lhs, rhs) {
        case (.lessThan(let l), .lessThan(let r)),
             (.lessThanOrEqual(let l), .lessThanOrEqual(let r)),
             (.greaterThan(let l), .greaterThan(let r)),
             (.greaterThanOrEqual(let l), .greaterThanOrEqual(let r)),
             (.equals(let l), .equals(let r)),
             (.notEquals(let l), .notEquals(let r)),
             (.contains(let l), .contains(let r)),
             (.notContains(let l), .notContains(let r)):
            return l == r
        case (.between(let l1, let l2), .between(let r1, let r2)),
             (.notBetween(let l1, let l2), .notBetween(let r1, let r2)):
            return l1 == r1 && l2 == r2
        case (.like(let l, _), .like(let r, _)):
            return l == r
        case (.valuesIn(let l), .valuesIn(let r)),
             (.valuesNotIn(let l), .valuesNotIn(let r)):
            return l == r
        case (.exists, .exists), (.notExists, .notExists):
            return true
        default:
            return false
        }
    }

    // MARK: - Codable (wire format: [operatorInt, op1?, op2?]).

    public init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        let opInt = try container.decode(Int.self)
        guard let op = ObjectFilterOperator(rawValue: opInt) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "\(opInt) is not a valid ObjectFilterOperator"
            )
        }
        self = try Self.decodeExpression(op, from: &container)

        guard container.isAtEnd else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "ObjectFilterExpression contains an unexpected operand"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try encodeExpression(to: &container)
    }

    private static func decodeExpression(
        _ op: ObjectFilterOperator,
        from container: inout UnkeyedDecodingContainer
    ) throws -> Self {
        switch op {
        case .LessThan, .LessThanOrEqual, .GreaterThan, .GreaterThanOrEqual, .Equals, .NotEquals:
            return try decodeSingleOperand(op, from: &container)
        case .Between, .NotBetween:
            return try decodeRange(op, from: &container)
        case .Like:
            let pattern = try container.decode(String.self)
            return .like(pattern: pattern, matcher: ObjectMatcher._createLikeRegexp(pattern: pattern))
        case .Exists:
            return .exists
        case .NotExists:
            return .notExists
        case .Contains, .NotContains:
            return try decodeContainment(op, from: &container)
        case .In, .NotIn:
            return try decodeMembership(op, from: &container)
        }
    }

    private static func decodeSingleOperand(
        _ op: ObjectFilterOperator,
        from container: inout UnkeyedDecodingContainer
    ) throws -> Self {
        let operand = try container.decode(FilterOperand.self)
        switch op {
        case .LessThan:
            return .lessThan(operand)
        case .LessThanOrEqual:
            return .lessThanOrEqual(operand)
        case .GreaterThan:
            return .greaterThan(operand)
        case .GreaterThanOrEqual:
            return .greaterThanOrEqual(operand)
        case .Equals:
            return .equals(operand)
        case .NotEquals:
            return .notEquals(operand)
        default:
            fatalError("Unexpected single-operand filter operator")
        }
    }

    private static func decodeRange(
        _ op: ObjectFilterOperator,
        from container: inout UnkeyedDecodingContainer
    ) throws -> Self {
        let first = try container.decode(FilterOperand.self)
        let second = try container.decode(FilterOperand.self)
        switch op {
        case .Between:
            return .between(first, second)
        case .NotBetween:
            return .notBetween(first, second)
        default:
            fatalError("Unexpected range filter operator")
        }
    }

    private static func decodeContainment(
        _ op: ObjectFilterOperator,
        from container: inout UnkeyedDecodingContainer
    ) throws -> Self {
        let operand = try container.decode(FilterOperand.self)
        switch op {
        case .Contains:
            return .contains(operand)
        case .NotContains:
            return .notContains(operand)
        default:
            fatalError("Unexpected containment filter operator")
        }
    }

    private static func decodeMembership(
        _ op: ObjectFilterOperator,
        from container: inout UnkeyedDecodingContainer
    ) throws -> Self {
        let operands = try container.decode([FilterOperand].self)
        switch op {
        case .In:
            return .valuesIn(operands)
        case .NotIn:
            return .valuesNotIn(operands)
        default:
            fatalError("Unexpected membership filter operator")
        }
    }

    private func encodeExpression(to container: inout UnkeyedEncodingContainer) throws {
        switch self {
        case .lessThan, .lessThanOrEqual, .greaterThan, .greaterThanOrEqual,
             .equals, .notEquals, .contains, .notContains:
            try Self.encodeSingleOperand(self, to: &container)
        case .between, .notBetween:
            try Self.encodeRange(self, to: &container)
        case .like(let pattern, _):
            try container.encode(ObjectFilterOperator.Like.rawValue)
            try container.encode(pattern)
        case .exists, .notExists:
            try Self.encodeNoOperand(self, to: &container)
        case .valuesIn, .valuesNotIn:
            try Self.encodeMembership(self, to: &container)
        }
    }

    private static func encodeSingleOperand(
        _ expression: Self,
        to container: inout UnkeyedEncodingContainer
    ) throws {
        let (filterOperator, value): (ObjectFilterOperator, FilterOperand)
        switch expression {
        case .lessThan(let operand):
            (filterOperator, value) = (.LessThan, operand)
        case .lessThanOrEqual(let operand):
            (filterOperator, value) = (.LessThanOrEqual, operand)
        case .greaterThan(let operand):
            (filterOperator, value) = (.GreaterThan, operand)
        case .greaterThanOrEqual(let operand):
            (filterOperator, value) = (.GreaterThanOrEqual, operand)
        case .equals(let operand):
            (filterOperator, value) = (.Equals, operand)
        case .notEquals(let operand):
            (filterOperator, value) = (.NotEquals, operand)
        case .contains(let operand):
            (filterOperator, value) = (.Contains, operand)
        case .notContains(let operand):
            (filterOperator, value) = (.NotContains, operand)
        default:
            fatalError("Unexpected single-operand expression")
        }
        try container.encode(filterOperator.rawValue)
        try container.encode(value)
    }

    private static func encodeRange(
        _ expression: Self,
        to container: inout UnkeyedEncodingContainer
    ) throws {
        let (filterOperator, first, second): (ObjectFilterOperator, FilterOperand, FilterOperand)
        switch expression {
        case .between(let firstValue, let secondValue):
            (filterOperator, first, second) = (.Between, firstValue, secondValue)
        case .notBetween(let firstValue, let secondValue):
            (filterOperator, first, second) = (.NotBetween, firstValue, secondValue)
        default:
            fatalError("Unexpected range expression")
        }
        try container.encode(filterOperator.rawValue)
        try container.encode(first)
        try container.encode(second)
    }

    private static func encodeNoOperand(
        _ expression: Self,
        to container: inout UnkeyedEncodingContainer
    ) throws {
        switch expression {
        case .exists:
            try container.encode(ObjectFilterOperator.Exists.rawValue)
        case .notExists:
            try container.encode(ObjectFilterOperator.NotExists.rawValue)
        default:
            fatalError("Unexpected no-operand expression")
        }
    }

    private static func encodeMembership(
        _ expression: Self,
        to container: inout UnkeyedEncodingContainer
    ) throws {
        let (filterOperator, values): (ObjectFilterOperator, [FilterOperand])
        switch expression {
        case .valuesIn(let operands):
            (filterOperator, values) = (.In, operands)
        case .valuesNotIn(let operands):
            (filterOperator, values) = (.NotIn, operands)
        default:
            fatalError("Unexpected membership expression")
        }
        try container.encode(filterOperator.rawValue)
        try container.encode(values)
    }

}
