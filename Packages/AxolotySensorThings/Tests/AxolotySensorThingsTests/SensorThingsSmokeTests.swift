// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Testing
import AxolotyObjectModel
import AxolotyWire
@testable import AxolotySensorThings

@Test("channel identifiers reject separators and wildcards")
func channelRejectsSeparators() throws {
    #expect(throws: Error.self) { try SensorThingsChannel<Observation>("bad/topic") }
    #expect(throws: Error.self) { try SensorThingsChannel<Observation>("bad+topic") }
    #expect(throws: Error.self) { try SensorThingsChannel<Observation>("bad#topic") }
    #expect(throws: Error.self) { try SensorThingsChannel<Observation>("") }
    let channel = try SensorThingsChannel<Observation>("observations")
    #expect(channel.identifier == "observations")
}

@Test("limits enforce bounded component capacities")
func limitsAreBounded() throws {
    let limits = try SensorThingsLimits(eventBufferCapacity: 4, maximumTrackedSensors: 8)
    #expect(limits.eventBufferCapacity == 4)
    #expect(limits.maximumTrackedSensors == 8)
    let id = ObjectID(uuid: UUID16(bytes: (1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1)))
    let channel = try SensorThingsChannel<Observation>("observations")
    #expect(throws: Error.self) {
        try SensorThingsObserverConfiguration(
            sensorID: id,
            observationChannel: channel,
            limits: SensorThingsLimits(eventBufferCapacity: 0)
        )
    }
    #expect(throws: Error.self) {
        try SensorThingsObserverConfiguration(
            sensorID: id,
            observationChannel: channel,
            limits: SensorThingsLimits(maximumTrackedSensors: 65)
        )
    }
}

@Test("raw JSON and number lexemes remain exact")
func rawJSONPreservesLexemes() throws {
    let value = try SensorThingsJSONValue(#"{"unicode":"é","n":1.2300}"#)
    #expect(value.kind == .object)
    #expect(value.encodedEquals(#"{"unicode":"é","n":1.2300}"#))
    let number = try SensorThingsNumber("1.2300")
    #expect(number.double == 1.23)
    #expect(number.int64 == nil)
    #expect(number.encodedEquals("1.2300"))
}

@Test("all four interval forms are representable")
func intervalForms() throws {
    let start = try SensorThingsNumber("100")
    let end = try SensorThingsNumber("200")
    #expect(CoatyTimeInterval.startEnd(start, end) == .startEnd(start, end))
    #expect(CoatyTimeInterval.startDuration(start, 0) == .startDuration(start, 0))
    #expect(CoatyTimeInterval.durationEnd(25, end) == .durationEnd(25, end))
    #expect(CoatyTimeInterval.durationOnly(50) == .durationOnly(50))
}

@Test("Thing object keeps its schema identity")
func thingObjectRoundTrip() throws {
    let uuid = UUID16(bytes: (1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16))
    let id = ObjectID(uuid: uuid)
    let name = try #require(BoundedEncodedText<128>("thing"))
    let thing = try Thing(
        description: name,
        properties: .value(try SensorThingsJSONValue("{\"line\":7}"))
    )
    let envelope = try ObjectEnvelope<128, 128>(
        objectID: id,
        objectType: Thing.schema.objectType,
        name: name,
        coreType: .coatyObject
    )
    let object = try Object<Thing>(envelope: envelope, fields: thing)
    #expect(object.value == thing)
    #expect(Object<Thing>.schema.objectType == Thing.schema.objectType)
    #expect(object.withEncodedBytes { $0.length > 0 })
}
