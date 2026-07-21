// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import Testing

@testable import Axoloty

/// Verifies that the raw JSON `String` fields on SensorThings types
/// (`Sensor.metadata`, `FeatureOfInterest.metadata`, `Observation.result`)
/// round-trip through `Codable` as raw JSON values — not as JSON string
/// literals — preserving wire compatibility after the `AnyCodable` removal
/// (#110 Phase 4).
@Suite
struct SensorThingsWireRoundTripTests {

    @Test
    func observationResultEncodesAsRawJSONNumber() throws {
        let observation = Observation(
            phenomenonTime: 1000,
            result: "42",
            resultTime: 2000,
            name: "Test"
        )
        let encoded = try JSONEncoder().encode(observation)
        let json = try #require(String(data: encoded, encoding: .utf8))
        // `result` must be the raw JSON number 42, not the string "42".
        #expect(json.contains("\"result\":42"))
        #expect(!json.contains("\"result\":\"42\""))

        let decoded = try JSONDecoder().decode(Observation.self, from: encoded)
        #expect(decoded.result == "42")
    }

    @Test
    func observationResultEncodesAsRawJSONString() throws {
        let observation = Observation(
            phenomenonTime: 1000,
            result: "\"hello\"",
            resultTime: 2000,
            name: "Test"
        )
        let encoded = try JSONEncoder().encode(observation)
        let json = try #require(String(data: encoded, encoding: .utf8))
        // `result` must be the raw JSON string "hello", not a double-encoded string.
        #expect(json.contains("\"result\":\"hello\""))

        let decoded = try JSONDecoder().decode(Observation.self, from: encoded)
        #expect(decoded.result == "\"hello\"")
    }

    @Test
    func observationResultEncodesAsRawJSONObject() throws {
        let observation = Observation(
            phenomenonTime: 1000,
            result: "{\"key\":\"value\"}",
            resultTime: 2000,
            name: "Test"
        )
        let encoded = try JSONEncoder().encode(observation)
        let json = try #require(String(data: encoded, encoding: .utf8))
        // `result` must be the raw JSON object, not a string-encoded object.
        #expect(json.contains("\"result\":{\"key\":\"value\"}"))

        let decoded = try JSONDecoder().decode(Observation.self, from: encoded)
        #expect(decoded.result == "{\"key\":\"value\"}")
    }

    @Test
    func sensorMetadataEncodesAsRawJSONNull() throws {
        let sensor = Sensor(
            description: "test",
            encodingType: SensorEncodingTypes.UNDEFINED,
            metadata: "null",
            unitOfMeasurement: UnitOfMeasurement(name: "C", symbol: "C", definition: ""),
            observationType: ObservationTypes.MEASUREMENT,
            observedProperty: ObservedProperty(name: "Temp", definition: "", description: ""),
            name: "Test"
        )
        let encoded = try JSONEncoder().encode(sensor)
        let json = try #require(String(data: encoded, encoding: .utf8))
        // `metadata` must be the raw JSON null literal, not the string "null".
        #expect(json.contains("\"metadata\":null"))
        #expect(!json.contains("\"metadata\":\"null\""))

        let decoded = try JSONDecoder().decode(Sensor.self, from: encoded)
        #expect(decoded.metadata == "null")
    }

    @Test
    func featureOfInterestMetadataRoundTripsRawJSON() throws {
        let feature = FeatureOfInterest(
            description: "feature",
            encodingType: EncodingTypes.UNDEFINED,
            metadata: "\"interesting\"",
            name: "F1"
        )
        let encoded = try JSONEncoder().encode(feature)
        let json = try #require(String(data: encoded, encoding: .utf8))
        // `metadata` must be the raw JSON string "interesting", not double-encoded.
        #expect(json.contains("\"metadata\":\"interesting\""))

        let decoded = try JSONDecoder().decode(FeatureOfInterest.self, from: encoded)
        #expect(decoded.metadata == "\"interesting\"")
    }

    @Test
    func sensorSourceControllerSerializesAnyToJSONString() throws {
        // Verify JSONValue.serialize(any:) produces valid raw JSON text
        // for the types SensorIo.read closures typically provide.
        #expect(JSONValue.serialize(any: 42) == "42")
        #expect(JSONValue.serialize(any: 23.5) == "23.5")
        #expect(JSONValue.serialize(any: "hello") == "\"hello\"")
        #expect(JSONValue.serialize(any: true) == "true")
        #expect(JSONValue.serialize(any: ["key": "value"]) == "{\"key\":\"value\"}")
        #expect(JSONValue.serialize(any: [1, 2, 3]) == "[1,2,3]")
    }
}
