// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import Testing

@testable import Axoloty

/// Verifies that `CallEvent`'s `parameters` field, now stored as raw JSON
/// `String`, round-trips through `Codable` as a raw JSON value — not a JSON
/// string literal — preserving wire compatibility after the `AnyCodable`
/// removal (#110 Phase 4). Also pins the `getParameterByName` /
/// `getParameterByIndex` accessors against the new `String?` return type.
@Suite
struct CallEventWireRoundTripTests {

    @Test
    func callEventParametersEncodesAsRawJSONObject() throws {
        let event = try CallEvent.with(
            operation: "doThing",
            parameters: "{\"operand\":7}"
        )
        let encoded = try JSONEncoder().encode(event)
        let json = try #require(String(data: encoded, encoding: .utf8))
        // `parameters` must be a raw JSON object, not a string-encoded object.
        #expect(json.contains("\"parameters\":{\"operand\":7}"))
        #expect(!json.contains("\"parameters\":\"{"))

        let decoded = try JSONDecoder().decode(CallEvent.self, from: encoded)
        #expect(decoded.data.parameters == "{\"operand\":7}")
    }

    @Test
    func callEventParametersEncodesAsRawJSONArray() throws {
        let event = try CallEvent.with(
            operation: "doThing",
            parameters: "[1,2,3]"
        )
        let encoded = try JSONEncoder().encode(event)
        let json = try #require(String(data: encoded, encoding: .utf8))
        // `parameters` must be a raw JSON array, not a string-encoded array.
        #expect(json.contains("\"parameters\":[1,2,3]"))

        let decoded = try JSONDecoder().decode(CallEvent.self, from: encoded)
        #expect(decoded.data.parameters == "[1,2,3]")
    }

    @Test
    func callEventWithNilParametersOmitsField() throws {
        let event = try CallEvent.with(operation: "doThing", parameters: nil)
        let encoded = try JSONEncoder().encode(event)
        let json = try #require(String(data: encoded, encoding: .utf8))
        #expect(!json.contains("parameters"))

        let decoded = try JSONDecoder().decode(CallEvent.self, from: encoded)
        #expect(decoded.data.parameters == nil)
    }

    @Test
    func getParameterByNameReturnsRawJSONText() throws {
        let event = try CallEvent.with(
            operation: "doThing",
            parameters: "{\"operand\":7,\"name\":\"hello\"}"
        )
        #expect(event.data.getParameterByName(name: "operand") == "7")
        #expect(event.data.getParameterByName(name: "name") == "\"hello\"")
        #expect(event.data.getParameterByName(name: "missing") == nil)
    }

    @Test
    func getParameterByIndexReturnsRawJSONText() throws {
        let event = try CallEvent.with(
            operation: "doThing",
            parameters: "[42,\"hello\",true]"
        )
        #expect(event.data.getParameterByIndex(index: 0) == "42")
        #expect(event.data.getParameterByIndex(index: 1) == "\"hello\"")
        #expect(event.data.getParameterByIndex(index: 2) == "true")
        #expect(event.data.getParameterByIndex(index: 3) == nil)
        #expect(event.data.getParameterByIndex(index: -1) == nil)
    }

    @Test
    func getParameterByNameReturnsNilForArrayParameters() throws {
        let event = try CallEvent.with(
            operation: "doThing",
            parameters: "[1,2,3]"
        )
        #expect(event.data.getParameterByName(name: "0") == nil)
    }

    @Test
    func getParameterByIndexReturnsNilForObjectParameters() throws {
        let event = try CallEvent.with(
            operation: "doThing",
            parameters: "{\"key\":\"value\"}"
        )
        #expect(event.data.getParameterByIndex(index: 0) == nil)
    }
}
