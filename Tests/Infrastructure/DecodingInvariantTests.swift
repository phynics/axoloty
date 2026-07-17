// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@testable import Axoloty
import Foundation
import Testing

/// Malformed-but-parseable peer payloads for the two decoders converted away
/// from force-unwrapping their `rawValue` initializers/combination invariants
/// in #139: they must now throw a `DecodingError` instead of trapping.
struct DecodingInvariantTests {
    @Test
    func orderByPropertyRejectsUnknownSortingOrder() throws {
        let payload = """
            [{"objectFilterProperty":"name"},"not-a-sorting-order"]
            """
        let data = try #require(payload.data(using: .utf8))

        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(OrderByProperty.self, from: data)
        }
    }

    @Test
    func objectFilterExpressionRejectsUnknownOperator() throws {
        let payload = "[9999]"
        let data = try #require(payload.data(using: .utf8))

        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(ObjectFilterExpression.self, from: data)
        }
    }

    @Test
    func coatyTimeIntervalRejectsOverSpecifiedCombination() throws {
        let payload = """
            {"_start":0,"_end":1000,"_duration":500}
            """
        let data = try #require(payload.data(using: .utf8))

        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(CoatyTimeInterval.self, from: data)
        }
    }

    @Test
    func coatyTimeIntervalRejectsUnderSpecifiedCombination() throws {
        let payload = "{}"
        let data = try #require(payload.data(using: .utf8))

        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(CoatyTimeInterval.self, from: data)
        }
    }

    @Test
    func coatyTimeIntervalAcceptsEachValidCombination() throws {
        let combinations = [
            #"{"_start":0,"_end":1000}"#,
            #"{"_start":0,"_duration":500}"#,
            #"{"_duration":500,"_end":1000}"#,
            #"{"_duration":500}"#,
        ]

        for payload in combinations {
            let data = try #require(payload.data(using: .utf8))
            _ = try JSONDecoder().decode(CoatyTimeInterval.self, from: data)
        }
    }
}
