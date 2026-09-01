// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyObjectModel
import AxolotyProtocol
import AxolotyWire
import Testing
@_spi(AxolotyRuntimeAdapter) import Axoloty
@testable import AxolotySensorThings

actor SensorThingsRecordingTransport: AxolotyRuntimeTransport {
    private(set) var publications: [OwnedProtocolPublication] = []
    private(set) var lifecycle: [String] = []

    func start(receive: @escaping @Sendable (RuntimeInboundFrame) -> Void) async throws {
        lifecycle.append("start")
    }

    func setFailureHandler(_ handler: @escaping @Sendable (Error) -> Void) async {}

    func perform(_ effect: RuntimeTransportEffect, namespace: String) async throws {
        guard case let .publish(publication) = effect else { return }
        publications.append(publication)
    }

    func stop() async {
        lifecycle.append("stop")
    }

    func installSubscriptions(namespace: String) async throws {
        lifecycle.append("install")
    }

    func removeSubscriptions(namespace: String) async throws {
        lifecycle.append("remove")
    }

    func allPublications() -> [OwnedProtocolPublication] {
        publications
    }
}

struct SensorThingsFixtureError: Error, Sendable {}

func fixtureJSON(_ json: String) throws -> SensorThingsJSONValue {
    let bytes = Array(json.utf8)
    return try bytes.withUnsafeBufferPointer { buffer in
        try SensorThingsJSONValue(copying: ByteSlice(
            bytes: buffer.baseAddress!,
            length: buffer.count
        ))
    }
}

func fixtureText(_ text: String) throws -> BoundedEncodedText<128> {
    let bytes = Array(text.utf8)
    return try bytes.withUnsafeBufferPointer { buffer in
        try #require(BoundedEncodedText<128>(bytes: ByteSlice(
            bytes: buffer.baseAddress!,
            length: buffer.count
        )))
    }
}

func fixtureID(_ value: String) throws -> ObjectID {
    guard let uuid = UUID16(parsing: value) else { throw SensorThingsFixtureError() }
    return ObjectID(uuid: uuid)
}

func fixtureThing(id: String, description: String = "thing", properties: String = "{\"line\":7}") throws -> Object<Thing> {
    let name = try fixtureText(description)
    return try Object<Thing>(
        envelope: ObjectEnvelope<128, 128>(
            objectID: fixtureID(id),
            objectType: Thing.schema.objectType,
            name: name,
            coreType: .coatyObject
        ),
        fields: Thing(
            description: name,
            properties: .value(try fixtureJSON(properties))
        )
    )
}

func fixtureSensor(
    id: String,
    parentID: String,
    description: String = "sensor"
) throws -> Object<Sensor> {
    let name = try fixtureText(description)
    return try Object<Sensor>(
        envelope: ObjectEnvelope<128, 128>(
            objectID: fixtureID(id),
            objectType: Sensor.schema.objectType,
            name: name,
            coreType: .coatyObject,
            parentObjectID: fixtureID(parentID)
        ),
        fields: Sensor(
            description: name,
            encodingType: try #require(BoundedEncodedText<128>("application/json")),
            metadata: try fixtureJSON("{\"kind\":\"fixture\"}"),
            unitOfMeasurement: UnitOfMeasurement(
                name: .value(try #require(BoundedEncodedText<128>("Celsius"))),
                symbol: .value(try #require(BoundedEncodedText<128>("C"))),
                definition: .value(try #require(BoundedEncodedText<128>("urn:celsius")))
            ),
            observationType: .measurement,
            observedProperty: ObservedProperty(
                name: try #require(BoundedEncodedText<128>("temperature")),
                definition: try #require(BoundedEncodedText<128>("urn:temperature")),
                description: try #require(BoundedEncodedText<128>("air temperature"))
            )
        )
    )
}

func fixtureObservation(
    id: String,
    parentID: String,
    result: String = "21.5"
) throws -> Object<Observation> {
    let name = try #require(BoundedEncodedText<128>("observation"))
    return try Object<Observation>(
        envelope: ObjectEnvelope<128, 128>(
            objectID: fixtureID(id),
            objectType: Observation.schema.objectType,
            name: name,
            coreType: .coatyObject,
            parentObjectID: fixtureID(parentID)
        ),
        fields: Observation(
            phenomenonTime: try SensorThingsNumber("100"),
            result: try fixtureJSON(result),
            resultTime: try SensorThingsNumber("101")
        )
    )
}

func fixtureBytes<Schema: ObjectSchema>(_ object: borrowing Object<Schema>) -> [UInt8] {
    object.withEncodedBytes { bytes in
        (0..<bytes.length).compactMap(bytes.byte(at:))
    }
}

func channelPayload<Schema: ObjectSchema>(_ object: borrowing Object<Schema>) -> [UInt8] {
    let objectBytes = fixtureBytes(object)
    return Array("{\"object\":".utf8) + objectBytes + Array("}".utf8)
}

func publicationObjectType(_ publication: OwnedProtocolPublication) -> String? {
    let bytes = publication.payload
    guard let objectStart = bytes.firstIndex(of: 0x7B) else { return nil }
    let text = String(decoding: bytes[objectStart...], as: UTF8.self)
    guard let typeStart = text.range(of: "\"objectType\":\"") else { return nil }
    let suffix = text[typeStart.upperBound...]
    guard let end = suffix.firstIndex(of: "\"") else { return nil }
    return String(suffix[..<end])
}

func publicationObjectID(_ publication: OwnedProtocolPublication) -> String? {
    let text = String(decoding: publication.payload, as: UTF8.self)
    guard let idStart = text.range(of: "\"objectId\":\"") else { return nil }
    let suffix = text[idStart.upperBound...]
    guard let end = suffix.firstIndex(of: "\"") else { return nil }
    return String(suffix[..<end])
}

func waitForPublicationCount(
    _ transport: SensorThingsRecordingTransport,
    _ count: Int
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while await transport.allPublications().count < count {
        if clock.now >= deadline { throw SensorThingsFixtureError() }
        try await Task.sleep(for: .milliseconds(5))
    }
}

func waitForPublicationCount(
    _ transport: SensorThingsRecordingTransport,
    capability: ProtocolCapability,
    count: Int
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while await transport.allPublications().filter({ $0.routingKey.capability == capability }).count < count {
        if clock.now >= deadline { throw SensorThingsFixtureError() }
        try await Task.sleep(for: .milliseconds(5))
    }
}

func waitForSensorThingsAdvertisementCount(
    _ transport: SensorThingsRecordingTransport,
    _ count: Int
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while await transport.allPublications().filter({ publication in
        guard publication.routingKey.capability == .advertise else { return false }
        let type = publicationObjectType(publication)
        return type == "coaty.sensorThings.Thing" || type == "coaty.sensorThings.Sensor"
    }).count < count {
        if clock.now >= deadline { throw SensorThingsFixtureError() }
        try await Task.sleep(for: .milliseconds(5))
    }
}

func nextDiagnostic(from stream: AsyncStream<RuntimeDiagnostic>) async throws -> RuntimeDiagnostic {
    try await withThrowingTaskGroup(of: RuntimeDiagnostic.self) { group in
        group.addTask {
            var iterator = stream.makeAsyncIterator()
            guard let diagnostic = await iterator.next() else { throw SensorThingsFixtureError() }
            return diagnostic
        }
        group.addTask {
            try await Task.sleep(for: .seconds(2))
            throw SensorThingsFixtureError()
        }
        guard let result = try await group.next() else { throw SensorThingsFixtureError() }
        group.cancelAll()
        return result
    }
}
