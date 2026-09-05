// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyProtocol
import Testing
import Axoloty
import AxolotyObjectModel
import AxolotyWire
@testable import AxolotySensorThings

private let registryThingID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
private let registrySensorID = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
private let registrySecondSensorID = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee"
private let registryObservationID = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"

@Test("Thing-driven registry requests exact Thing discovery and parent-filtered Sensor query")
func registryStartsCombinedWorkflow() async throws {
    let thingID = try fixtureID(registryThingID)
    var builder = try RuntimeBuilder(sourceID: .zero, namespace: "registry-tests")
    _ = try builder.sensorThings { configuration in
        try configuration.observations(
            forSensorsOf: thingID,
            buffering: .dropOldest(capacity: 4)
        )
    }
    let transport = SensorThingsRecordingTransport()
    let runtime = AxolotyRuntime(definition: try builder.finish(), transport: transport)
    try await runtime.start()
    try await waitForPublicationCount(transport, capability: .discover, count: 1)
    try await waitForPublicationCount(transport, capability: .query, count: 1)
    let publications = await transport.allPublications()
    #expect(publications.contains { routeEventType($0.route) == ProtocolCapability.discover.wireEventType.wireCode.description })
    #expect(publications.contains { routeEventType($0.route) == ProtocolCapability.query.wireEventType.wireCode.description })
    let queryPayload = publications.first(where: { routeEventType($0.route) == ProtocolCapability.query.wireEventType.wireCode.description })?.payload ?? []
    let queryText = String(decoding: queryPayload, as: UTF8.self)
    #expect(queryText.contains("coaty.sensorThings.Sensor"))
    #expect(queryText.contains("parentObjectId"))
    #expect(queryText.contains(registryThingID))
    await runtime.stop()
}

@Test("Thing-driven registry opens delivery only after Thing and Sensor relationships agree")
func registryTracksRelationshipsAndSensorChannel() async throws {
    let thingID = try fixtureID(registryThingID)
    let sensorID = try fixtureID(registrySensorID)
    var builder = try RuntimeBuilder(sourceID: .zero, namespace: "registry-tests")
    let streams = try builder.sensorThings { configuration in
        try configuration.observations(
            forSensorsOf: thingID,
            buffering: .dropOldest(capacity: 4)
        )
    }
    let runtime = AxolotyRuntime(definition: try builder.finish(), transport: SensorThingsRecordingTransport())
    try await runtime.start()

    let sender = "dddddddd-dddd-4ddd-8ddd-dddddddddddd"
    try #require(await runtime.receive(.profile(
        route: "coaty/3/registry-tests/ADV::coaty.sensorThings.Thing/\(sender)",
        payload: advertisePayload(try fixtureThing(id: registryThingID)),
        nowMS: 1
    )) == .accepted)
    try #require(await runtime.receive(.profile(
        route: "coaty/3/registry-tests/ADV::coaty.sensorThings.Sensor/\(sender)",
        payload: advertisePayload(try fixtureSensor(id: registrySensorID, parentID: registryThingID)),
        nowMS: 2
    )) == .accepted)

    var catalogue = streams.catalogueChanges.makeAsyncIterator()
    let change = try #require(await catalogue.next())
    #expect(change.kind == .added)
    #expect(change.total.count == 1)

    var observations = streams.observations.makeAsyncIterator()
    let observation = try fixtureObservation(id: registryObservationID, parentID: registrySensorID)
    try #require(await runtime.receive(.profile(
        route: "coaty/3/registry-tests/CHN:\(registrySensorID)/\(sender)",
        payload: channelPayload(observation),
        nowMS: 3
    )) == .accepted)
    let delivery = try #require(await observations.next())
    let observationID = try fixtureID(registryObservationID)
    #expect(delivery.observation.envelope.objectID == observationID)
    #expect(delivery.sensor.envelope.objectID == sensorID)
    #expect(delivery.thing.envelope.objectID == thingID)
    #expect(delivery.context.channelIdentifier == registrySensorID)
    await runtime.stop()
}

@Test("Thing deadvertisement emits deterministic shrinking catalogue snapshots")
func registryThingDeadvertisementRemovesSensorsAtomically() async throws {
    let thingID = try fixtureID(registryThingID)
    var builder = try RuntimeBuilder(sourceID: .zero, namespace: "registry-tests")
    let streams = try builder.sensorThings { configuration in
        try configuration.observations(forSensorsOf: thingID, buffering: .dropOldest(capacity: 8))
    }
    let runtime = AxolotyRuntime(definition: try builder.finish(), transport: SensorThingsRecordingTransport())
    try await runtime.start()

    var catalogue = streams.catalogueChanges.makeAsyncIterator()
    let sender = "dddddddd-dddd-4ddd-8ddd-dddddddddddd"
    try #require(await runtime.receive(.profile(
        route: "coaty/3/registry-tests/ADV::coaty.sensorThings.Thing/\(sender)",
        payload: advertisePayload(try fixtureThing(id: registryThingID)),
        nowMS: 1
    )) == .accepted)
    try #require(await runtime.receive(.profile(
        route: "coaty/3/registry-tests/ADV::coaty.sensorThings.Sensor/\(sender)",
        payload: advertisePayload(try fixtureSensor(id: registrySensorID, parentID: registryThingID)),
        nowMS: 2
    )) == .accepted)
    try #require(await runtime.receive(.profile(
        route: "coaty/3/registry-tests/ADV::coaty.sensorThings.Sensor/\(sender)",
        payload: advertisePayload(try fixtureSensor(id: registrySecondSensorID, parentID: registryThingID)),
        nowMS: 3
    )) == .accepted)

    let first = try #require(await catalogue.next())
    let second = try #require(await catalogue.next())
    #expect(first.total.count == 1)
    #expect(second.total.count == 2)

    try #require(await runtime.receive(.profile(
        route: "coaty/3/registry-tests/DAD/\(sender)",
        payload: Array("{\"objectIds\":[\"\(registryThingID)\"]}".utf8),
        nowMS: 4
    )) == .accepted)
    let removedFirst = try #require(await catalogue.next())
    let removedSecond = try #require(await catalogue.next())
    #expect(removedFirst.kind == .removed)
    #expect(removedSecond.kind == .removed)
    #expect(removedFirst.total.count == 1)
    #expect(removedSecond.total.isEmpty)
    await runtime.stop()
}

private func advertisePayload<Schema: ObjectSchema>(_ object: consuming Object<Schema>) -> [UInt8] {
    let bytes = fixtureBytes(object)
    return Array("{\"object\":".utf8) + bytes + Array("}".utf8)
}
