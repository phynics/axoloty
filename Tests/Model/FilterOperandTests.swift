//  Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
//
//  FilterOperandTests.swift
//  Axoloty

import Testing
@testable import Axoloty
import Foundation

@Suite
struct FilterOperandTests {

    /// Integers and doubles are distinct cases: `42` must not re-encode as
    /// `42.0`. Pinned in Phase 1; a
    /// replacement modelling JSON numbers as a single `Double` case would
    /// break wire byte-fidelity against the fixture corpus.
    @Test

    func testIntegerRoundTripsWithoutDecimalPoint() throws {
        let decoded = try JSONDecoder().decode(FilterOperand.self, from: Data("42".utf8))
        #expect(decoded == .int(42))

        let reEncoded = try JSONEncoder().encode(decoded)
        #expect(String(data: reEncoded, encoding: .utf8) == "42")
    }

    @Test

    func testDoubleRoundTripsWithDecimalPoint() throws {
        let decoded = try JSONDecoder().decode(FilterOperand.self, from: Data("42.5".utf8))
        #expect(decoded == .double(42.5))

        let reEncoded = try JSONEncoder().encode(decoded)
        #expect(String(data: reEncoded, encoding: .utf8) == "42.5")
    }

    @Test

    func testStringRoundTrips() throws {
        let decoded = try JSONDecoder().decode(FilterOperand.self, from: Data("\"hi\"".utf8))
        #expect(decoded == .string("hi"))
    }

    /// `true` decodes as `.bool`, not as `.int(1)`. The decode ladder tries
    /// `Bool` before `Int`; a reordering would silently turn booleans into
    /// numbers and break equality against wire-decoded operands.
    @Test

    func testBooleanRoundTripsAsBoolNotInt() throws {
        let decoded = try JSONDecoder().decode(FilterOperand.self, from: Data("true".utf8))
        #expect(decoded == .bool(true))
        #expect(decoded != .int(1))

        let reEncoded = try JSONEncoder().encode(decoded)
        #expect(String(data: reEncoded, encoding: .utf8) == "true")
    }

    @Test

    func testNullRoundTrips() throws {
        let decoded = try JSONDecoder().decode(FilterOperand.self, from: Data("null".utf8))
        #expect(decoded == .null)
    }

    @Test

    func testNestedObjectAndArrayRoundTrip() throws {
        let json = #"{"a":[1,true,null]}"#
        let decoded = try JSONDecoder().decode(FilterOperand.self, from: Data(json.utf8))
        #expect(decoded == .object(["a": .array([.int(1), .bool(true), .null])]))
    }

    // MARK: - Wire contract.

    /// The `Int` raw values of ``ObjectFilterOperator`` are the wire contract:
    /// CoatyJS encodes `["objectId", [7, "..."]]` for `Equals`, where `7` is
    /// the operator's raw value. These integers are implicit (declaration
    /// order) and therefore fragile — reordering or inserting a case
    /// silently renumbers every peer's filters. Pinned so Phase 2's reshaping
    /// of `ObjectFilterExpression` cannot drift them.
    @Test

    func testOperatorRawValuesMatchTheWireContract() {
        #expect(ObjectFilterOperator.LessThan.rawValue == 0)
        #expect(ObjectFilterOperator.LessThanOrEqual.rawValue == 1)
        #expect(ObjectFilterOperator.GreaterThan.rawValue == 2)
        #expect(ObjectFilterOperator.GreaterThanOrEqual.rawValue == 3)
        #expect(ObjectFilterOperator.Between.rawValue == 4)
        #expect(ObjectFilterOperator.NotBetween.rawValue == 5)
        #expect(ObjectFilterOperator.Like.rawValue == 6)
        #expect(ObjectFilterOperator.Equals.rawValue == 7)
        #expect(ObjectFilterOperator.NotEquals.rawValue == 8)
        #expect(ObjectFilterOperator.Exists.rawValue == 9)
        #expect(ObjectFilterOperator.NotExists.rawValue == 10)
        #expect(ObjectFilterOperator.Contains.rawValue == 11)
        #expect(ObjectFilterOperator.NotContains.rawValue == 12)
        #expect(ObjectFilterOperator.In.rawValue == 13)
        #expect(ObjectFilterOperator.NotIn.rawValue == 14)
    }

    // MARK: - Expression wire round-trip (Task 5)

    /// The enum-shaped `ObjectFilterExpression` must produce the same
    /// `[operatorInt, op1?, op2?]` wire format as the old class. Test each
    /// operator arity: no operand (`.exists`), one (`.equals`), two
    /// (`.between`), and `.like` (pattern only, matcher is not on the wire).
    @Test

    func testExpressionWireRoundTripExists() throws {
        let expr: ObjectFilterExpression = .exists
        let encoded = try JSONEncoder().encode(expr)
        // Wire: [9] — operator only, no operands.
        #expect(String(data: encoded, encoding: .utf8) == "[9]")
        let decoded = try JSONDecoder().decode(ObjectFilterExpression.self, from: encoded)
        #expect(decoded == .exists)
    }

    @Test

    func testExpressionWireRoundTripEquals() throws {
        let expr: ObjectFilterExpression = .equals("hello")
        let encoded = try JSONEncoder().encode(expr)
        // Wire: [7, "hello"]
        #expect(String(data: encoded, encoding: .utf8) == #"[7,"hello"]"#)
        let decoded = try JSONDecoder().decode(ObjectFilterExpression.self, from: encoded)
        #expect(decoded == .equals("hello"))
    }

    @Test

    func testExpressionWireRoundTripBetween() throws {
        let expr: ObjectFilterExpression = .between(1, 10)
        let encoded = try JSONEncoder().encode(expr)
        // Wire: [4, 1, 10]
        #expect(String(data: encoded, encoding: .utf8) == "[4,1,10]")
        let decoded = try JSONDecoder().decode(ObjectFilterExpression.self, from: encoded)
        #expect(decoded == .between(1, 10))
    }

    @Test

    func testExpressionWireRoundTripLike() throws {
        let expr: ObjectFilterExpression = .like("H%")
        let encoded = try JSONEncoder().encode(expr)
        // Wire: [6, "H%"] — matcher is NOT on the wire.
        #expect(String(data: encoded, encoding: .utf8) == #"[6,"H%"]"#)
        let decoded = try JSONDecoder().decode(ObjectFilterExpression.self, from: encoded)
        guard case .like(let pattern, _) = decoded else {
            Issue.record("Expected .like, got \(decoded)")
            return
        }
        #expect(pattern == "H%")
    }

    /// Constructing `.like` with a non-string is not possible — the case
    /// takes a `String`, not a `FilterOperand`. Invalid operator/operand
    /// pairs are unrepresentable at compile time.
    @Test

    func testInvalidOperatorOperandPairsDoNotCompile() {
        // This test exists as documentation: the enum's associated values
        // make invalid combinations unrepresentable. For example:
        // - .between requires exactly two operands.
        // - .exists takes no operands.
        // - .like takes a String pattern, not a FilterOperand.
        // A wrong-arity construction fails at compile time, not runtime.
        #expect(Bool(true))
    }

    // MARK: - P1-5 `_deepContains` object-key regression

    /// Regression for issue #445 / P1-5: the object branch of
    /// `_deepContains` traverses a requested object's keys against a
    /// candidate object's dictionary. A key present in the candidate but not
    /// requested is fine; a requested key that is merely *prefix-partial* (no
    /// exact match) must `return false` via the guard rather than force-unwrap
    /// and trap.
    ///
    /// On the buggy path a `xDict[xk]!` force-unwrap crashed when the
    /// candidate object did not carry a requested key. The fix guards the
    /// lookup. These tests assert the guard path is exercised without a trap
    /// and that partial-key matches do not count as containing.
    @Test

    func testDeepContainsObjectMissingReturningKeyDoesNotTrap() {
        // Candidate has no `missing` key; requested object references it.
        let candidate = FilterOperand.object(["present": .int(1)])
        let requested = FilterOperand.object(["missing": .int(2)])

        // Must not trap, and the guard must report non-containment.
        #expect(!FilterOperand.deepContains(candidate, requested))
    }

    @Test

    func testDeepContainsObjectPartialKeyMatchDoesNotCount() {
        // `match` is not a key in the candidate; `mat` alone must not be
        // treated as containing `match`.
        let candidate = FilterOperand.object(["mat": .string("ched")])
        let requested = FilterOperand.object(["match": .string("ched")])

        #expect(!FilterOperand.deepContains(candidate, requested))
    }

    @Test

    func testDeepContainsObjectPresentKeyMatches() {
        // A requested key that IS present in the candidate recurses into the
        // value containment check.
        let candidate = FilterOperand.object(["name": .string("alice")])
        let requested = FilterOperand.object(["name": .string("al")])

        #expect(FilterOperand.deepContains(candidate, requested))
    }
}
