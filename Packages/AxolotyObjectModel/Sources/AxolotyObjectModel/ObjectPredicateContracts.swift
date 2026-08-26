// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyWire

/// The Coaty object-filter operators, retaining their protocol integer values.
public enum ObjectPredicateOperator: UInt8, Sendable, Equatable {
    /// Strictly less than.
    case lessThan = 0
    /// Less than or equal to.
    case lessThanOrEqual = 1
    /// Strictly greater than.
    case greaterThan = 2
    /// Greater than or equal to.
    case greaterThanOrEqual = 3
    /// Inclusive range test.
    case between = 4
    /// Negated inclusive range test.
    case notBetween = 5
    /// Coaty SQL-like wildcard matching.
    case like = 6
    /// Recursive JSON equality.
    case equals = 7
    /// Negated recursive JSON equality.
    case notEquals = 8
    /// Tests field presence, including explicit null.
    case exists = 9
    /// Tests field absence.
    case notExists = 10
    /// Recursive containment.
    case contains = 11
    /// Negated recursive containment.
    case notContains = 12
    /// Top-level membership in an operand array.
    case valuesIn = 13
    /// Negated top-level membership in an operand array.
    case valuesNotIn = 14
}

/// A bounded predicate operand. Raw values are copied into the predicate arena.
public enum ObjectPredicateLiteral {
    /// A complete borrowed JSON value.
    case raw(ByteSlice)
    /// JSON null.
    case null
    /// JSON boolean.
    case bool(Bool)
    /// A JSON string literal without Foundation.
    case string(StaticString)
    /// A JSON number lexeme, retained exactly.
    case number(StaticString)
}

/// One typed Coaty predicate expression.
public enum ObjectPredicateExpression {
    /// A one-operand comparison.
    case lessThan(ObjectPredicateLiteral)
    /// A one-operand comparison.
    case lessThanOrEqual(ObjectPredicateLiteral)
    /// A one-operand comparison.
    case greaterThan(ObjectPredicateLiteral)
    /// A one-operand comparison.
    case greaterThanOrEqual(ObjectPredicateLiteral)
    /// An inclusive range.
    case between(ObjectPredicateLiteral, ObjectPredicateLiteral)
    /// A negated inclusive range.
    case notBetween(ObjectPredicateLiteral, ObjectPredicateLiteral)
    /// A wildcard string pattern.
    case like(ObjectPredicateLiteral)
    /// Recursive equality.
    case equals(ObjectPredicateLiteral)
    /// Negated recursive equality.
    case notEquals(ObjectPredicateLiteral)
    /// Presence test.
    case exists
    /// Absence test.
    case notExists
    /// Recursive containment.
    case contains(ObjectPredicateLiteral)
    /// Negated recursive containment.
    case notContains(ObjectPredicateLiteral)
    /// Top-level membership; the literal must be a JSON array.
    case valuesIn(ObjectPredicateLiteral)
    /// Negated top-level membership; the literal must be a JSON array.
    case valuesNotIn(ObjectPredicateLiteral)
}

/// Short aliases used by schema code when the predicate context is already clear.
public typealias PredicateOperator = ObjectPredicateOperator
/// Short alias for a predicate literal.
public typealias PredicateLiteral = ObjectPredicateLiteral
/// Short alias for a predicate expression.
public typealias PredicateExpression = ObjectPredicateExpression
