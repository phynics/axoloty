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

    @Test(arguments: [
        "[9999]",
        "[]",
        "[0]",
        "[4,1]",
        "[6]",
        "[7,1,2]",
        "[0,1,2]",
    ])
    func objectFilterExpressionRejectsMalformedShape(_ payload: String) throws {
        let data = try #require(payload.data(using: .utf8))

        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(ObjectFilterExpression.self, from: data)
        }
    }

    @Test(arguments: [
        #"{"conditions":["name",[7]]}"#,
        #"{"conditions":["name"]}"#,
        #"{"conditions":"malformed"}"#,
        #"{"conditions":null}"#,
        #"{"conditions":{"and":"malformed"}}"#,
        #"{"conditions":{}}"#,
        #"{"conditions":{"and":[],"or":[]}}"#,
        #"{"conditions":["name",[7],"unexpected"]}"#,
        #"{"conditions":["name",[0,1,2]]}"#,
        #"{"conditions":["",[9]]}"#,
        #"{"conditions":[[""],[9]]}"#,
        #"{"conditions":[".",[9]]}"#,
        #"{"conditions":[".name",[9]]}"#,
        #"{"conditions":["name.",[9]]}"#,
        #"{"conditions":["name..value",[9]]}"#,
        #"{"conditions":[["name",""] ,[9]]}"#,
        #"{"conditions":[["", "name"],[9]]}"#,
        #"{"conditions":[["name","","value"],[9]]}"#,
    ])
    func objectFilterRejectsMalformedConditionsInsteadOfMatchingAll(_ payload: String) throws {
        let data = try #require(payload.data(using: .utf8))

        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(ObjectFilter.self, from: data)
        }
    }

    @Test
    func objectFilterAcceptsEmptyFilterObject() throws {
        let data = try #require("{}".data(using: .utf8))

        let filter = try JSONDecoder().decode(ObjectFilter.self, from: data)

        #expect(filter.condition == nil)
        #expect(filter.conditions == nil)
    }

    @Test
    func objectFilterAcceptsDotsInsideArrayPropertyComponent() throws {
        let payload = #"{"conditions":[["property.with.dots"],[9]]}"#
        let data = try #require(payload.data(using: .utf8))

        _ = try JSONDecoder().decode(ObjectFilter.self, from: data)
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

    @Test
    func coatyTimeIntervalRejectsNegativeDuration() throws {
        let data = try #require(#"{"_duration":-1}"#.data(using: .utf8))

        do {
            _ = try JSONDecoder().decode(CoatyTimeInterval.self, from: data)
            Issue.record("A negative duration must be rejected during decoding")
        } catch let error as AxolotyError {
            #expect(error.userFriendlyMessage == "CoatyTimeInterval: duration cannot be negative")
            if case .decodingFailure = error {
                // Expected structured error category.
            } else {
                Issue.record("Expected decodingFailure for a negative wire duration")
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func coatyTimeIntervalAcceptsNegativeTimestamps() throws {
        let data = try #require(#"{"_start":-1000,"_end":0}"#.data(using: .utf8))

        _ = try JSONDecoder().decode(CoatyTimeInterval.self, from: data)
    }
}
