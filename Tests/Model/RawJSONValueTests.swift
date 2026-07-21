// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
//
//  RawJSONValueTests.swift
//  Axoloty

import Testing
@testable import Axoloty
import Foundation

/// Characterizes `RawJSONValue`, the internal payload-capture type introduced
/// for #110 Phase 3. Mirrors the decode-ladder guarantees already pinned for
/// `FilterOperand` so later snapshot wiring can rely on them.
@Suite
struct RawJSONValueTests {

    // MARK: - Number typing.

    @Test
    func testIntegerDecodesAsIntNotDouble() throws {
        let decoded = try JSONDecoder().decode(RawJSONValue.self, from: Data("42".utf8))

        guard case .int(42) = decoded else {
            Issue.record("Expected .int(42), got \(decoded)")
            return
        }
    }

    @Test
    func testIntegerReencodesWithoutDecimalPoint() throws {
        let decoded = try JSONDecoder().decode(RawJSONValue.self, from: Data("42".utf8))
        let reencoded = String(decoding: try JSONEncoder().encode(decoded), as: UTF8.self)

        #expect(reencoded == "42")
    }

    @Test
    func testFractionalNumberDecodesAsDouble() throws {
        let decoded = try JSONDecoder().decode(RawJSONValue.self, from: Data("42.5".utf8))

        guard case .double(42.5) = decoded else {
            Issue.record("Expected .double(42.5), got \(decoded)")
            return
        }
    }

    /// `Foundation.JSONDecoder` tolerates a whole-number double literal as an
    /// `Int` (i.e. `try? container.decode(Int.self)` succeeds for `"42.0"`),
    /// so the ladder recovers `.int(42)` here rather than `.double(42.0)` —
    /// the resulting JSON text loses the decimal point. This is the same
    /// "recovery depends on ladder order, not on what was encoded" quirk
    /// #110 documents for `FilterOperand`'s identical ladder;
    /// pinned here as a known, shared characteristic rather
    /// than a `RawJSONValue`-specific defect.
    @Test
    func testWholeNumberDoubleLiteralIsRecoveredAsIntByLadderOrder() throws {
        let decoded = try JSONDecoder().decode(RawJSONValue.self, from: Data("42.0".utf8))

        guard case .int(42) = decoded else {
            Issue.record("Expected .int(42), got \(decoded)")
            return
        }

        let reencoded = String(decoding: try JSONEncoder().encode(decoded), as: UTF8.self)
        #expect(reencoded == "42")
    }

    // MARK: - Primitive round trips.

    @Test
    func testBooleanRoundTrips() throws {
        for literal in ["true", "false"] {
            let decoded = try JSONDecoder().decode(RawJSONValue.self, from: Data(literal.utf8))
            let reencoded = String(decoding: try JSONEncoder().encode(decoded), as: UTF8.self)
            #expect(reencoded == literal)
        }
    }

    @Test
    func testNullRoundTrips() throws {
        let decoded = try JSONDecoder().decode(RawJSONValue.self, from: Data("null".utf8))
        #expect(decoded == .null)

        let reencoded = String(decoding: try JSONEncoder().encode(decoded), as: UTF8.self)
        #expect(reencoded == "null")
    }

    @Test
    func testStringRoundTripsIncludingUnicodeAndEmpty() throws {
        for value in ["", "hello", "héllo 🎉"] {
            let json = try JSONEncoder().encode(value)
            let decoded = try JSONDecoder().decode(RawJSONValue.self, from: json)
            #expect(decoded == .string(value))

            let reencodedValue = try JSONDecoder().decode(String.self, from: try JSONEncoder().encode(decoded))
            #expect(reencodedValue == value)
        }
    }

    // MARK: - Nested structures.

    @Test
    func testNestedArrayRoundTrips() throws {
        let json = Data("[1, \"two\", 3.5, true, null, [4, 5]]".utf8)
        let decoded = try JSONDecoder().decode(RawJSONValue.self, from: json)

        #expect(decoded == .array([
            .int(1), .string("two"), .double(3.5), .bool(true), .null, .array([.int(4), .int(5)]),
        ]))
    }

    @Test
    func testNestedObjectRoundTrips() throws {
        let json = Data("""
        {"name":"widget","count":3,"price":9.99,"tags":["a","b"],"meta":{"active":true}}
        """.utf8)
        let decoded = try JSONDecoder().decode(RawJSONValue.self, from: json)

        #expect(decoded == .object([
            "name": .string("widget"),
            "count": .int(3),
            "price": .double(9.99),
            "tags": .array([.string("a"), .string("b")]),
            "meta": .object(["active": .bool(true)]),
        ]))

        // Re-encoding and re-decoding must reach a fixed point.
        let reencoded = try JSONEncoder().encode(decoded)
        let roundTripped = try JSONDecoder().decode(RawJSONValue.self, from: reencoded)
        #expect(roundTripped == decoded)
    }

    // MARK: - Failure behavior.

    @Test
    func testDecodingEmptyDataThrowsRatherThanProducingNull() {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(RawJSONValue.self, from: Data())
        }
    }

    // MARK: - Equatable.

    @Test
    func testIntAndDoubleAreNotEqualEvenWhenNumericallyEqual() {
        let intValue: RawJSONValue = .int(1)
        let doubleValue: RawJSONValue = .double(1.0)

        #expect(intValue != doubleValue)
    }
}
