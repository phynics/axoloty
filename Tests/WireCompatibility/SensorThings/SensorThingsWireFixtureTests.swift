// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@testable import Axoloty
import Foundation
import Testing

/// Wire-format fixture tests for SensorThings object types (T-021 scenarios
/// 7-9).
///
/// No `@coaty/sensor-things` package exists for the pinned CoatyJS 2.4.0
/// agent, so cross-implementation live coverage is not possible. Instead,
/// these offline tests decode pinned JSON payloads representing the wire shape
/// a peer would send over standard Advertise/Channel topics, and assert that
/// Axoloty decodes all semantic fields correctly — including nested types
/// (UnitOfMeasurement, ObservedProperty, Polygon, CoatyTimeInterval) and
/// heterogeneous raw JSON fields (metadata, result).
///
/// The transport layer is already proven compatible by the Advertise/Channel
/// rows in the compatibility matrix; these tests lock in the field-schema
/// decode contract.
@Suite
struct SensorThingsWireFixtureTests {

    // MARK: - Thing

    /// A fully-populated Thing with properties decodes all fields.
    @Test
    func thingFullyPopulatedDecodes() throws {
        let json = """
            {"coreType":"CoatyObject","objectType":"coaty.sensorThings.Thing","objectId":"11111111-1111-4111-8111-111111111111","name":"office-thing","description":"Office environment sensor","properties":{"floor":"3","room":"301"}}
            """
        let thing = try JSONDecoder().decode(Thing.self, from: Data(json.utf8))

        #expect(thing.objectType == "coaty.sensorThings.Thing")
        #expect(thing.objectId == CoatyUUID(uuidString: "11111111-1111-4111-8111-111111111111"))
        #expect(thing.name == "office-thing")
        #expect(thing.description == "Office environment sensor")
        #expect(thing.properties?["floor"] == "3")
        #expect(thing.properties?["room"] == "301")
    }

    /// A minimal Thing (no optional properties) decodes with nil properties.
    @Test
    func thingMinimalDecodesWithNilProperties() throws {
        let json = """
            {"coreType":"CoatyObject","objectType":"coaty.sensorThings.Thing","objectId":"22222222-2222-4222-8222-222222222222","name":"bare-thing","description":"No props","properties":null}
            """
        let thing = try JSONDecoder().decode(Thing.self, from: Data(json.utf8))

        #expect(thing.description == "No props")
        #expect(thing.properties == nil)
    }

    // MARK: - FeatureOfInterest

    /// A FeatureOfInterest with a raw JSON object metadata decodes correctly.
    @Test
    func featureOfInterestWithObjectMetadataDecodes() throws {
        let json = """
            {"coreType":"CoatyObject","objectType":"coaty.sensorThings.FeatureOfInterest","objectId":"33333333-3333-4333-8333-333333333333","name":"foi-1","description":"Living room","encodingType":"application/vnd.geo+json","metadata":{"type":"Point","coordinates":[52.5,13.4]}}
            """
        let foi = try JSONDecoder().decode(FeatureOfInterest.self, from: Data(json.utf8))

        #expect(foi.objectType == "coaty.sensorThings.FeatureOfInterest")
        #expect(foi.name == "foi-1")
        #expect(foi.description == "Living room")
        #expect(foi.encodingType == "application/vnd.geo+json")
        // metadata is raw JSON text: the object {"type":"Point","coordinates":[52.5,13.4]}
        #expect(foi.metadata.contains("\"type\":\"Point\""))
        #expect(foi.metadata.contains("52.5"))
    }

    /// A FeatureOfInterest with a null metadata decodes correctly.
    @Test
    func featureOfInterestWithNullMetadataDecodes() throws {
        let json = """
            {"coreType":"CoatyObject","objectType":"coaty.sensorThings.FeatureOfInterest","objectId":"44444444-4444-4444-8444-444444444444","name":"foi-null","description":"No metadata","encodingType":"","metadata":null}
            """
        let foi = try JSONDecoder().decode(FeatureOfInterest.self, from: Data(json.utf8))

        #expect(foi.metadata == "null")
    }

    // MARK: - Sensor

    /// A fully-populated Sensor with nested UnitOfMeasurement, ObservedProperty,
    /// Polygon observedArea, and CoatyTimeInterval decodes all fields.
    @Test
    func sensorFullyPopulatedDecodes() throws {
        let json = """
            {"coreType":"CoatyObject","objectType":"coaty.sensorThings.Sensor","objectId":"55555555-5555-4555-8555-555555555555","name":"temp-sensor","description":"DHT22 temperature sensor","encodingType":"application/pdf","metadata":"http://example.com/datasheet.pdf","unitOfMeasurement":{"name":"Degree Celsius","symbol":"degC","definition":"http://qudt.org/vocab/unit#DegreeCelsius"},"observationType":"http://www.opengis.net/def/observationType/OGC-OM/2.0/OM_Measurement","observedArea":{"type":"Polygon","coordinates":[[[0.0,0.0],[1.0,0.0],[1.0,1.0],[0.0,1.0],[0.0,0.0]]]},"phenomenonType":{"_start":1000,"_end":2000},"resultTime":{"_start":3000,"_duration":500},"observedProperty":{"name":"Temperature","definition":"http://example.com/properties/Temperature","description":"Air temperature"}}
            """
        let sensor = try JSONDecoder().decode(Sensor.self, from: Data(json.utf8))

        #expect(sensor.objectType == "coaty.sensorThings.Sensor")
        #expect(sensor.name == "temp-sensor")
        #expect(sensor.description == "DHT22 temperature sensor")
        #expect(sensor.encodingType == "application/pdf")
        // metadata is raw JSON text: a JSON string re-encoded by the decoder.
        #expect(sensor.metadata.contains("datasheet"))
        #expect(sensor.unitOfMeasurement.name == "Degree Celsius")
        #expect(sensor.unitOfMeasurement.symbol == "degC")
        #expect(sensor.unitOfMeasurement.definition == "http://qudt.org/vocab/unit#DegreeCelsius")
        #expect(sensor.observationType == .measurement)
        #expect(sensor.observedArea?.type == .Polygon)
        #expect(sensor.phenomenonTime != nil)
        #expect(sensor.resultTime != nil)
        #expect(sensor.observedProperty.name == "Temperature")
        #expect(sensor.observedProperty.definition == "http://example.com/properties/Temperature")
        #expect(sensor.observedProperty.description == "Air temperature")
    }

    /// A minimal Sensor (no optional fields) decodes with nil optionals.
    @Test
    func sensorMinimalDecodesWithNilOptionals() throws {
        let json = """
            {"coreType":"CoatyObject","objectType":"coaty.sensorThings.Sensor","objectId":"66666666-6666-4666-8666-666666666666","name":"bare-sensor","description":"Bare","encodingType":"","metadata":null,"unitOfMeasurement":{"name":"","symbol":"","definition":""},"observationType":"http://www.opengis.net/def/observationType/OGC-OM/2.0/OM_Observation","observedProperty":{"name":"X","definition":"","description":""}}
            """
        let sensor = try JSONDecoder().decode(Sensor.self, from: Data(json.utf8))

        #expect(sensor.observedArea == nil)
        #expect(sensor.phenomenonTime == nil)
        #expect(sensor.resultTime == nil)
        #expect(sensor.metadata == "null")
    }

    // MARK: - Observation

    /// An Observation with a raw JSON number result and all optional fields
    /// decodes correctly.
    @Test
    func observationWithNumberResultDecodes() throws {
        let json = """
            {"coreType":"CoatyObject","objectType":"coaty.sensorThings.Observation","objectId":"77777777-7777-4777-8777-777777777777","name":"obs-1","phenomenonTime":1500.5,"result":42,"resultTime":1600.0,"resultQuality":["quality-good"],"validTime":{"_start":1000,"_duration":500},"parameters":{"unit":"degC"},"featureOfInterest":"33333333-3333-4333-8333-333333333333"}
            """
        let obs = try JSONDecoder().decode(Observation.self, from: Data(json.utf8))

        #expect(obs.objectType == "coaty.sensorThings.Observation")
        #expect(obs.name == "obs-1")
        #expect(obs.phenomenonTime == 1500.5)
        #expect(obs.result == "42")
        #expect(obs.resultTime == 1600.0)
        #expect(obs.resultQuality == ["quality-good"])
        #expect(obs.validTime != nil)
        #expect(obs.parameters?["unit"] == "degC")
        #expect(obs.featureOfInterest == CoatyUUID(uuidString: "33333333-3333-4333-8333-333333333333"))
    }

    /// An Observation with a raw JSON object result decodes correctly.
    @Test
    func observationWithObjectResultDecodes() throws {
        let json = """
            {"coreType":"CoatyObject","objectType":"coaty.sensorThings.Observation","objectId":"88888888-8888-4888-8888-888888888888","name":"obs-obj","phenomenonTime":1000,"result":{"temp":23.5,"unit":"C"},"resultTime":2000}
            """
        let obs = try JSONDecoder().decode(Observation.self, from: Data(json.utf8))

        #expect(obs.result.contains("\"temp\":23.5"))
        #expect(obs.result.contains("\"unit\":\"C\""))
        #expect(obs.resultQuality == nil)
        #expect(obs.validTime == nil)
        #expect(obs.parameters == nil)
        #expect(obs.featureOfInterest == nil)
    }

    /// An Observation with a null result decodes correctly.
    @Test
    func observationWithNullResultDecodes() throws {
        let json = """
            {"coreType":"CoatyObject","objectType":"coaty.sensorThings.Observation","objectId":"99999999-9999-4999-8999-999999999999","name":"obs-null","phenomenonTime":1000,"result":null,"resultTime":2000}
            """
        let obs = try JSONDecoder().decode(Observation.self, from: Data(json.utf8))

        #expect(obs.result == "null")
    }

    // MARK: - Forward compatibility (scenario 9)

    /// A Thing payload with unknown fields decodes without error.
    @Test
    func thingDecodesWithUnknownFields() throws {
        let json = """
            {"coreType":"CoatyObject","objectType":"coaty.sensorThings.Thing","objectId":"11111111-1111-4111-8111-111111111111","name":"thing","description":"d","properties":null,"futureField":"value","nested":{"a":1}}
            """
        let thing = try? JSONDecoder().decode(Thing.self, from: Data(json.utf8))
        #expect(thing != nil)
        #expect(thing?.description == "d")
    }

    /// An Observation with reordered JSON keys decodes identically.
    @Test
    func observationDecodesWithReorderedKeys() throws {
        let ordered = """
            {"coreType":"CoatyObject","objectType":"coaty.sensorThings.Observation","objectId":"77777777-7777-4777-8777-777777777777","name":"obs","phenomenonTime":1000,"result":42,"resultTime":2000}
            """
        let reordered = """
            {"resultTime":2000,"result":42,"phenomenonTime":1000,"name":"obs","objectId":"77777777-7777-4777-8777-777777777777","objectType":"coaty.sensorThings.Observation","coreType":"CoatyObject"}
            """
        let a = try JSONDecoder().decode(Observation.self, from: Data(ordered.utf8))
        let b = try JSONDecoder().decode(Observation.self, from: Data(reordered.utf8))

        #expect(a.phenomenonTime == b.phenomenonTime)
        #expect(a.result == b.result)
        #expect(a.resultTime == b.resultTime)
        #expect(a.name == b.name)
    }

    /// A Sensor with unknown fields in nested UnitOfMeasurement decodes
    /// without error (forward compat at the nested-type level).
    @Test
    func sensorDecodesWithUnknownNestedFields() throws {
        let json = """
            {"coreType":"CoatyObject","objectType":"coaty.sensorThings.Sensor","objectId":"55555555-5555-4555-8555-555555555555","name":"s","description":"d","encodingType":"","metadata":null,"unitOfMeasurement":{"name":"C","symbol":"degC","definition":"def","futureUnitField":42},"observationType":"http://www.opengis.net/def/observationType/OGC-OM/2.0/OM_Observation","observedProperty":{"name":"T","definition":"","description":""}}
            """
        let sensor = try? JSONDecoder().decode(Sensor.self, from: Data(json.utf8))
        #expect(sensor != nil)
        #expect(sensor?.unitOfMeasurement.name == "C")
    }

    /// A Sensor with an unknown observationType value fails decoding rather
    /// than silently accepting an invalid type.
    @Test
    func sensorRejectsUnknownObservationType() throws {
        let json = """
            {"coreType":"CoatyObject","objectType":"coaty.sensorThings.Sensor","objectId":"55555555-5555-4555-8555-555555555555","name":"s","description":"d","encodingType":"","metadata":null,"unitOfMeasurement":{"name":"","symbol":"","definition":""},"observationType":"http://example.com/unknown","observedProperty":{"name":"T","definition":"","description":""}}
            """
        let sensor = try? JSONDecoder().decode(Sensor.self, from: Data(json.utf8))
        #expect(sensor == nil)
    }

    // MARK: - Unicode and edge cases

    /// A Thing with Unicode in description and properties decodes correctly.
    @Test
    func thingWithUnicodeDecodes() throws {
        let json = """
            {"coreType":"CoatyObject","objectType":"coaty.sensorThings.Thing","objectId":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","name":"世界-thing","description":"温度传感器 ✓","properties":{"部屋":"リビング","フロア":"3階"}}
            """
        let thing = try JSONDecoder().decode(Thing.self, from: Data(json.utf8))

        #expect(thing.name == "世界-thing")
        #expect(thing.description == "温度传感器 ✓")
        #expect(thing.properties?["部屋"] == "リビング")
    }

    /// An Observation with a Unicode string result decodes correctly.
    @Test
    func observationWithUnicodeStringResultDecodes() throws {
        let json = """
            {"coreType":"CoatyObject","objectType":"coaty.sensorThings.Observation","objectId":"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb","name":"obs-unicode","phenomenonTime":1000,"result":"héllo 世界 ✓","resultTime":2000}
            """
        let obs = try JSONDecoder().decode(Observation.self, from: Data(json.utf8))

        #expect(obs.result == "\"héllo 世界 ✓\"")
    }
}
