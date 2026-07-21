// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import Testing

@testable import Axoloty

/// Verifies that `ReturnEvent`'s `result` and `executionInfo` fields,
/// now stored as raw JSON `String`, round-trip through `Codable` as raw
/// JSON values — not JSON string literals — preserving wire compatibility
/// after the `AnyCodable` removal (#110 Phase 4).
@Suite
struct ReturnEventWireRoundTripTests {

    @Test
    func returnEventResultEncodesAsRawJSONObject() throws {
        let event = ReturnEvent.with(
            result: "{\"answer\":49,\"objectId\":\"abc\"}",
            executionInfo: nil
        )
        let encoded = try JSONEncoder().encode(event)
        let json = try #require(String(data: encoded, encoding: .utf8))
        // `result` must be a raw JSON object, not a string-encoded object.
        #expect(json.contains("\"result\":{\"answer\":49,\"objectId\":\"abc\"}"))
        #expect(!json.contains("\"result\":\"{"))

        let decoded = try JSONDecoder().decode(ReturnEvent.self, from: encoded)
        #expect(decoded.data.result == "{\"answer\":49,\"objectId\":\"abc\"}")
    }

    @Test
    func returnEventExecutionInfoEncodesAsRawJSONNumber() throws {
        let event = ReturnEvent.with(
            result: "42",
            executionInfo: "5000"
        )
        let encoded = try JSONEncoder().encode(event)
        let json = try #require(String(data: encoded, encoding: .utf8))
        // `executionInfo` must be the raw JSON number 5000, not the string "5000".
        #expect(json.contains("\"executionInfo\":5000"))
        #expect(!json.contains("\"executionInfo\":\"5000\""))

        let decoded = try JSONDecoder().decode(ReturnEvent.self, from: encoded)
        #expect(decoded.data.executionInfo == "5000")
    }

    @Test
    func returnEventWithOmittedFieldsDecodesAsNil() throws {
        let json = #"{"type":"RTN"}"#
        let event: ReturnEvent = try PayloadCoder.decode(json)
        #expect(event.data.result == nil)
        #expect(event.data.executionInfo == nil)
        #expect(event.data.error == nil)
    }

    @Test
    func returnEventErrorPathPreservesErrorFields() throws {
        let error = ReturnError(code: -32602, message: "Invalid params")
        let event = ReturnEvent.with(error: error, executionInfo: nil)
        let encoded = try JSONEncoder().encode(event)
        let json = try #require(String(data: encoded, encoding: .utf8))
        #expect(json.contains("\"error\":{\"code\":-32602,\"message\":\"Invalid params\"}"))

        let decoded = try JSONDecoder().decode(ReturnEvent.self, from: encoded)
        #expect(decoded.data.error?.code == -32602)
        #expect(decoded.data.error?.message == "Invalid params")
        #expect(decoded.data.result == nil)
    }
}
