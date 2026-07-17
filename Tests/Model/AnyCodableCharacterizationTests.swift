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

    // MARK: - Like operator operand mutation.

    /// A `Like` match rewrites the filter's second operand, caching a compiled
    /// `NSRegularExpression` into it.
    ///
    /// `ObjectMatcher._matchesLike` does this to avoid recompiling the pattern,
    /// under a source comment reading "NOTE: Ask if this kind of caching is
    /// okay". It is a write to shared filter state performed during matching.
    ///
    /// - Important: This pins present, undesirable behavior. #110 Phase 2
    ///   compiles the pattern at decode time and removes the mutation, at which
    ///   point this test is expected to be inverted deliberately.
    @Test

    func testLikeMatchReplacesSecondOperandWithACompiledRegex() throws {
        let filter = Self.likeFilter()

        #expect(ObjectMatcher.matchesFilter(obj: try Self.helloObject(), filter: filter))

        let expression = try #require(filter.condition).expression
        #expect(expression.firstOperand?.value is String)
        #expect(expression.secondOperand?.value is NSRegularExpression)
    }

    /// Because the cached regex is not `Encodable`, a filter can no longer be
    /// encoded once it has been used for a `Like` match.
    ///
    /// This is latent rather than active: the common receive-side flow decodes
    /// a filter, matches it, and never re-encodes it. It is a landmine because
    /// ``PayloadCoder/encode(_:)`` force-tries the encode, so a filter that is
    /// matched and then published crashes rather than throwing.
    ///
    /// - Important: Pins present, undesirable behavior. #110 Phase 2 removes
    ///   the mutation, after which encoding must succeed and this test is
    ///   expected to be inverted deliberately.
    @Test

    func testFilterCannotBeReEncodedAfterALikeMatch() throws {
        let filter = Self.likeFilter()
        #expect(throws: Never.self) { try JSONEncoder().encode(filter) }

        _ = ObjectMatcher.matchesFilter(obj: try Self.helloObject(), filter: filter)

        #expect(throws: EncodingError.self) { try JSONEncoder().encode(filter) }
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
                                                   op1: AnyCodable("H%"))))
    }
}
