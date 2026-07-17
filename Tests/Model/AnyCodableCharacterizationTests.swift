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
}
