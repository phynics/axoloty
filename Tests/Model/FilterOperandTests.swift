//  Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
//
//  FilterOperandTests.swift
//  Axoloty

import Testing
import Axoloty
import Foundation

@Suite
struct FilterOperandTests {

    /// Integers and doubles are distinct cases: `42` must not re-encode as
    /// `42.0`. Pinned in Phase 1 (`AnyCodableCharacterizationTests`); a
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
}
