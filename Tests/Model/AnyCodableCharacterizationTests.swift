//  Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
//
//  AnyCodableCharacterizationTests.swift
//  Axoloty

import Testing
import Axoloty
import Foundation

/// Pins CURRENT `AnyCodable` behavior so the removal tracked in #110 can prove
/// it changed nothing observable.
///
/// - Important: These are characterization tests. Where current behavior is
///   surprising, it is recorded deliberately and annotated. Do not "correct" an
///   assertion here: if a behavior should change, that is a decision for the
///   phase that changes it, made with its own justification.
/// - Note: `DeterministicFuzzTests.testAnyCodableJSONRoundTripsSemantically`
///   compares JSON to JSON and never inspects the Swift dynamic type, so it is
///   blind to the type-level regressions this suite guards against.
@Suite
struct AnyCodableCharacterizationTests {

    // MARK: - Number typing.

    /// An integer literal decodes as `Int`, not `Double`.
    ///
    /// The decode ladder tries `Int` before `Double`. A replacement modelling
    /// JSON numbers as a single `Double` case would re-encode `42` as `42.0`
    /// and break wire compatibility.
    @Test

    func testIntegerDecodesAsIntNotDouble() throws {
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: Data("42".utf8))

        #expect(decoded.value is Int)
        #expect(!(decoded.value is Double))
    }

    /// An integer re-encodes without a decimal point.
    @Test

    func testIntegerReEncodesWithoutDecimalPoint() throws {
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: Data("42".utf8))
        let reEncoded = try JSONEncoder().encode(decoded)

        #expect(String(data: reEncoded, encoding: .utf8) == "42")
    }

    /// A fractional literal decodes as `Double` and keeps its point.
    @Test

    func testDoubleRoundTripsAsDouble() throws {
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: Data("42.5".utf8))
        let reEncoded = try JSONEncoder().encode(decoded)

        #expect(decoded.value is Double)
        #expect(String(data: reEncoded, encoding: .utf8) == "42.5")
    }

    /// `true` decodes as `Bool`, not as the integer 1. The ladder tries `Bool`
    /// before `Int`; a replacement must preserve that ordering.
    @Test

    func testBooleanDecodesAsBoolNotInt() throws {
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: Data("true".utf8))

        #expect(decoded.value is Bool)
        #expect(!(decoded.value is Int))
    }

    // MARK: - Equality.

    /// `AnyCodable.==` switches on the pair of dynamic types and has no
    /// cross-type case, so an `Int` and a `Double` of equal numeric value fall
    /// through to `default: return false`.
    ///
    /// This is the same shape as the defect fixed in #102/#103, where a
    /// `CoatyUUID` never compared equal to its wire-decoded `String`. Pinned so
    /// that #110 Phase 2 makes a deliberate choice about cross-type comparison
    /// rather than an accidental one.
    @Test

    func testIntAndDoubleOfEqualValueAreNotEqual() {
        #expect(AnyCodable(42) != AnyCodable(42.0))
    }

    @Test

    func testStringEqualityIsSupported() {
        #expect(AnyCodable("a") == AnyCodable("a"))
        #expect(AnyCodable("a") != AnyCodable("b"))
    }

    /// Since #103, a `CoatyUUID` is stored as its lowercase string, so it
    /// compares equal to that string. This is the fix's contract; Phase 2 must
    /// preserve it.
    @Test

    func testCoatyUUIDEqualsItsLowercaseString() throws {
        let uuidString = "3f2504e0-4f89-11d3-9a0c-0305e82c3301"
        let uuid = try #require(CoatyUUID(uuidString: uuidString))

        #expect(AnyCodable(uuid) == AnyCodable(uuidString))
    }

    // MARK: - Ordering.

    /// String ordering uses `localizedCompare`, not raw lexicographic ordering.
    @Test

    func testStringOrderingUsesLocalizedCompare() {
        #expect(AnyCodable("a") < AnyCodable("b"))
        #expect(!(AnyCodable("b") < AnyCodable("a")))
    }

    /// Ordering across mismatched types silently returns false rather than
    /// erroring, in both directions. The public docs warn about this in prose
    /// ("Do not compare a number with a string, as the result is not defined")
    /// rather than preventing it. Phase 2's enum-shaped expression is expected
    /// to make such pairs unrepresentable; this pins today's behavior until it
    /// does.
    @Test

    func testOrderingAcrossMismatchedTypesReturnsFalse() {
        #expect(!(AnyCodable(1) < AnyCodable("a")))
        #expect(!(AnyCodable("a") < AnyCodable(1)))
    }

    // MARK: - Like operator operand mutation (Task 4: removed).

    /// Task 4 inverted this pin: a `Like` match no longer mutates the
    /// filter's operands. The pattern is compiled once at decode time into
    /// `ObjectFilterExpression.compiledLikePattern`, and the first operand
    /// remains the original string pattern.
    @Test

    func testLikeMatchPreservesSecondOperand() throws {
        let filter = Self.likeFilter()

        #expect(ObjectMatcher.matchesFilter(obj: try Self.helloObject(), filter: filter))

        let expression = try #require(filter.condition).expression
        #expect(expression.firstOperand == .string("H%"))
        // secondOperand was never set by the Like filter (only firstOperand
        // carries the pattern). It remains nil.
        #expect(expression.secondOperand == nil)
    }

    /// Task 4 inverted this pin: a filter can now be re-encoded after a
    /// `Like` match because the compiled regex is stored separately from the
    /// Codable operands, so re-encoding the expression no longer attempts to
    /// serialize an `NSRegularExpression`.
    @Test

    func testFilterCanBeReEncodedAfterALikeMatch() throws {
        let filter = Self.likeFilter()
        _ = ObjectMatcher.matchesFilter(obj: try Self.helloObject(), filter: filter)

        // Must not throw — the Like pattern is not stored in the Codable operands.
        let encoded = try JSONEncoder().encode(filter)
        let decoded = try JSONDecoder().decode(ObjectFilter.self, from: encoded)
        let reExpression = try #require(decoded.condition).expression
        #expect(reExpression.firstOperand == .string("H%"))
    }

    // MARK: - Fixtures.

    private static func helloObject() throws -> CoatyObject {
        return CoatyObject(coreType: .Log,
                           objectType: Log.objectType,
                           objectId: .init(),
                           name: "Hello")
    }

    private static func likeFilter() -> ObjectFilter {
        return ObjectFilter(
            condition: ObjectFilterCondition(
                property: ObjectFilterProperty("name"),
                expression: ObjectFilterExpression(filterOperator: .Like,
                                                   op1: "H%")))
    }
}
