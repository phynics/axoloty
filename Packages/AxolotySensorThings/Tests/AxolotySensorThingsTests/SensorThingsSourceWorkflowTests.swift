// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyProtocol
import Testing
import Axoloty
import AxolotyObjectModel
import AxolotyWire
@testable import AxolotySensorThings

private let sourceIDOne = "11111111-1111-4111-8111-111111111111"
private let sourceIDTwo = "22222222-2222-4222-8222-222222222222"
private let thingIDOne = "33333333-3333-4333-8333-333333333333"
private let thingIDTwo = "44444444-4444-4444-8444-444444444444"

@Test("SensorThings registration is one atomic transaction and returns its result")
func sensorThingsRejectsASecondTransaction() throws {
    var builder = try RuntimeBuilder(sourceID: .zero, namespace: "sensor-tests")
    let result = try builder.sensorThings { _ in 42 }
    #expect(result == 42)
    #expect(throws: Error.self) { try builder.sensorThings { _ in 7 } }
    let definition = try builder.finish()
    #expect(definition.moduleCount == 1)
    #expect(definition.handlerCount == 2)
}

@Test("An escaped configuration cannot mutate after its transaction")
func escapedSensorThingsConfigurationIsClosed() throws {
    var builder = try RuntimeBuilder(sourceID: .zero, namespace: "sensor-tests")
    var escaped: SensorThingsConfiguration?
    try builder.sensorThings { configuration in
        escaped = configuration
    }
    #expect(throws: Error.self) {
        _ = try escaped?.observations(
            for: ObjectID(uuid: UUID16(bytes: (2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2))),
            channel: try SensorThingsChannel<Observation>("escaped"),
            buffering: .coalesceLatest
        )
    }
    let definition = try builder.finish()
    #expect(definition.eventStreamCount == 0)
    #expect(definition.moduleCount == 1)
}

@Test("SensorThings limits retain both configured bounds")
func sensorLimitsAreBounded() throws {
    let limits = try SensorThingsLimits(maximumSensors: 7, maximumObservationStreams: 11)
    #expect(limits.maximumSensors == 7)
    #expect(limits.maximumObservationStreams == 11)
    #expect(throws: Error.self) { try SensorThingsLimits(maximumSensors: 65) }
    #expect(throws: Error.self) { try SensorThingsLimits(maximumObservationStreams: 0) }
}

@Test("A throwing configuration leaves the builder unchanged")
func sensorThingsConfigurationRollsBack() async throws {
    var builder = try RuntimeBuilder(sourceID: .zero, namespace: "sensor-tests")
    let sensorID = ObjectID(uuid: UUID16(bytes: (1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1)))
    var retainedStream: SensorObservationStream?
    #expect(throws: Error.self) {
        try builder.sensorThings { configuration in
            retainedStream = try configuration.observations(
                for: sensorID,
                channel: try SensorThingsChannel<Observation>("observations"),
                buffering: .fail(capacity: 4)
            )
            throw AxolotyError.invalidArgument(argument: "configuration", reason: "test rollback")
        }
    }
    let definition = try builder.finish()
    #expect(definition.moduleCount == 0)
    #expect(definition.handlerCount == 0)
    #expect(definition.eventStreamCount == 0)
    let stream = try #require(retainedStream)
    var iterator = stream.makeAsyncIterator()
    #expect(await iterator.next() == nil)
}

@Test("a Sensor with a mismatched Thing parent is rejected atomically")
func mismatchedSensorParentRollsBackRegistration() throws {
    var builder = try RuntimeBuilder(sourceID: .zero, namespace: "sensor-tests")
    do {
        try builder.sensorThings { configuration in
            try configuration.source(
                sensor: fixtureSensor(id: sourceIDOne, parentID: thingIDOne),
                thing: fixtureThing(id: thingIDTwo),
                observationChannel: try SensorThingsChannel<Observation>("observations"),
                run: { _ in }
            )
        }
        Issue.record("mismatched Sensor parent unexpectedly succeeded")
    } catch {
        #expect((error as? AxolotyError)?.userFriendlyMessage.contains("parentObjectId") == true)
    }

    let definition = try builder.finish()
    #expect(definition.moduleCount == 0)
    #expect(definition.handlerCount == 0)
    #expect(definition.eventStreamCount == 0)
}

@Test("conflicting duplicate Thing snapshots are rejected atomically")
func conflictingThingSnapshotRollsBackRegistration() throws {
    var builder = try RuntimeBuilder(sourceID: .zero, namespace: "sensor-tests")
    do {
        try builder.sensorThings { configuration in
            try configuration.source(
                sensor: fixtureSensor(id: sourceIDOne, parentID: thingIDOne),
                thing: fixtureThing(id: thingIDOne, description: "first"),
                observationChannel: try SensorThingsChannel<Observation>("one"),
                run: { _ in }
            )
            try configuration.source(
                sensor: fixtureSensor(id: sourceIDTwo, parentID: thingIDOne),
                thing: fixtureThing(id: thingIDOne, description: "conflict"),
                observationChannel: try SensorThingsChannel<Observation>("two"),
                run: { _ in }
            )
        }
        Issue.record("conflicting duplicate Thing unexpectedly succeeded")
    } catch {
        #expect((error as? AxolotyError)?.userFriendlyMessage.contains("conflicting") == true)
    }

    let definition = try builder.finish()
    #expect(definition.moduleCount == 0)
    #expect(definition.handlerCount == 0)
    #expect(definition.eventStreamCount == 0)
}

@Test("identical Thing snapshots are advertised once while each Sensor is advertised")
func identicalThingSnapshotsAreDeduplicated() async throws {
    var builder = try RuntimeBuilder(sourceID: .zero, namespace: "sensor-tests")
    try builder.sensorThings { configuration in
        try configuration.source(
            sensor: fixtureSensor(id: sourceIDOne, parentID: thingIDOne),
            thing: fixtureThing(id: thingIDOne),
            observationChannel: try SensorThingsChannel<Observation>("one"),
            run: { _ in }
        )
        try configuration.source(
            sensor: fixtureSensor(id: sourceIDTwo, parentID: thingIDOne),
            thing: fixtureThing(id: thingIDOne),
            observationChannel: try SensorThingsChannel<Observation>("two"),
            run: { _ in }
        )
    }
    let transport = SensorThingsRecordingTransport()
    let runtime = AxolotyRuntime(definition: try builder.finish(), transport: transport)
    try await runtime.start()
    try await waitForSensorThingsAdvertisementCount(transport, 6)

    let publications = await transport.allPublications()
    let advertisements = publications.filter { routeEventType($0.route) == ProtocolCapability.advertise.wireEventType.wireCode.description }
    let sensorThingsAdvertisements = advertisements.filter {
        let type = publicationObjectType($0)
        return type == "coaty.sensorThings.Thing" || type == "coaty.sensorThings.Sensor"
    }
    try #require(sensorThingsAdvertisements.count == 6)
    #expect(sensorThingsAdvertisements.prefix(2).allSatisfy {
        publicationObjectType($0) == "coaty.sensorThings.Thing"
    })
    #expect(sensorThingsAdvertisements.dropFirst(2).allSatisfy {
        publicationObjectType($0) == "coaty.sensorThings.Sensor"
    })
    await runtime.stop()
}

@Test("source lifecycle advertises Thing before Sensor and deadvertises Sensor before Thing")
func sourceLifecycleOrdering() async throws {
    var builder = try RuntimeBuilder(sourceID: .zero, namespace: "sensor-tests")
    try builder.sensorThings { configuration in
        try configuration.source(
            sensor: fixtureSensor(id: sourceIDOne, parentID: thingIDOne),
            thing: fixtureThing(id: thingIDOne),
            observationChannel: try SensorThingsChannel<Observation>("observations"),
            run: { _ in }
        )
    }
    let transport = SensorThingsRecordingTransport()
    let runtime = AxolotyRuntime(definition: try builder.finish(), transport: transport)
    try await runtime.start()
    try await waitForSensorThingsAdvertisementCount(transport, 4)
    let startup = await transport.allPublications()
    let startupAdvertisements = startup.filter { publication in
        guard routeEventType(publication.route) == ProtocolCapability.advertise.wireEventType.wireCode.description else { return false }
        let type = publicationObjectType(publication)
        return type == "coaty.sensorThings.Thing" || type == "coaty.sensorThings.Sensor"
    }
    try #require(startupAdvertisements.count == 4)
    #expect(startupAdvertisements.prefix(2).allSatisfy {
        publicationObjectType($0) == "coaty.sensorThings.Thing"
    })
    #expect(startupAdvertisements.dropFirst(2).allSatisfy {
        publicationObjectType($0) == "coaty.sensorThings.Sensor"
    })

    await runtime.stop()
    let allPublications = await transport.allPublications()
    let shutdown = allPublications.filter { routeEventType($0.route) == ProtocolCapability.deadvertise.wireEventType.wireCode.description }
    try #require(shutdown.count == 2)
    #expect(String(decoding: shutdown[0].payload, as: UTF8.self).contains(sourceIDOne))
    #expect(String(decoding: shutdown[1].payload, as: UTF8.self).contains(thingIDOne))
}

@Test("source limits reject the next source without committing partial registration")
func sourceLimitIsAtomic() throws {
    var builder = try RuntimeBuilder(sourceID: .zero, namespace: "sensor-tests")
    do {
        try builder.sensorThings(limits: try SensorThingsLimits(maximumSensors: 1, maximumObservationStreams: 2)) { configuration in
            try configuration.source(
                sensor: fixtureSensor(id: sourceIDOne, parentID: thingIDOne),
                thing: fixtureThing(id: thingIDOne),
                observationChannel: try SensorThingsChannel<Observation>("one"),
                run: { _ in }
            )
            try configuration.source(
                sensor: fixtureSensor(id: sourceIDTwo, parentID: thingIDTwo),
                thing: fixtureThing(id: thingIDTwo),
                observationChannel: try SensorThingsChannel<Observation>("two"),
                run: { _ in }
            )
        }
        Issue.record("source limit unexpectedly succeeded")
    } catch {
        // Expected capacity rejection.
    }
    let definition = try builder.finish()
    #expect(definition.moduleCount == 0)
    #expect(definition.handlerCount == 0)
}

@Test("observation stream limits reject the next stream without committing partial registration")
func observationStreamLimitIsAtomic() throws {
    let sensorOne = try fixtureID(sourceIDOne)
    let sensorTwo = try fixtureID(sourceIDTwo)
    var builder = try RuntimeBuilder(sourceID: .zero, namespace: "sensor-tests")
    do {
        try builder.sensorThings(limits: try SensorThingsLimits(maximumSensors: 2, maximumObservationStreams: 1)) { configuration in
            _ = try configuration.observations(
                for: sensorOne,
                channel: try SensorThingsChannel<Observation>("one"),
                buffering: .coalesceLatest
            )
            _ = try configuration.observations(
                for: sensorTwo,
                channel: try SensorThingsChannel<Observation>("two"),
                buffering: .coalesceLatest
            )
        }
        Issue.record("observation stream limit unexpectedly succeeded")
    } catch {
        // Expected capacity rejection.
    }
    let definition = try builder.finish()
    #expect(definition.moduleCount == 0)
    #expect(definition.eventStreamCount == 0)
}

@Test("reconnect replays source advertisements without duplicating producer tasks")
func reconnectDoesNotDuplicateProducerTasks() async throws {
    let probe = ProducerProbe()
    var builder = try RuntimeBuilder(sourceID: .zero, namespace: "sensor-tests")
    try builder.sensorThings { configuration in
        try configuration.source(
            sensor: fixtureSensor(id: sourceIDOne, parentID: thingIDOne),
            thing: fixtureThing(id: thingIDOne),
            observationChannel: try SensorThingsChannel<Observation>("observations"),
            run: { _ in await probe.run() }
        )
    }
    let transport = SensorThingsRecordingTransport()
    let runtime = AxolotyRuntime(definition: try builder.finish(), transport: transport)
    try await runtime.start()
    try await probe.waitForRuns(1)
    await runtime.reconnect()
    #expect(await runtime.state() == .running)
    try await Task.sleep(for: .milliseconds(50))
    #expect(await probe.runs == 1)
    await runtime.stop()
}

@Test("producer failure is isolated and emits a structured diagnostic")
func producerFailureIsIsolated() async throws {
    let failure = ProducerFailure()
    var builder = try RuntimeBuilder(sourceID: .zero, namespace: "sensor-tests")
    try builder.sensorThings { configuration in
        try configuration.source(
            sensor: fixtureSensor(id: sourceIDOne, parentID: thingIDOne),
            thing: fixtureThing(id: thingIDOne),
            observationChannel: try SensorThingsChannel<Observation>("one"),
            run: { _ in throw failure }
        )
        try configuration.source(
            sensor: fixtureSensor(id: sourceIDTwo, parentID: thingIDTwo),
            thing: fixtureThing(id: thingIDTwo),
            observationChannel: try SensorThingsChannel<Observation>("two"),
            run: { publisher in
                try await publisher.channel(
                    fixtureObservation(id: "55555555-5555-4555-8555-555555555555", parentID: sourceIDTwo),
                    on: try SensorThingsChannel<Observation>("two")
                )
            }
        )
    }
    let transport = SensorThingsRecordingTransport()
    let runtime = AxolotyRuntime(definition: try builder.finish(), transport: transport)
    let diagnostics = await runtime.diagnostics()
    try await runtime.start()
    try await waitForPublicationCount(transport, capability: .channel, count: 1)
    let diagnostic = try await nextDiagnostic(from: diagnostics)
    #expect(diagnostic.kind == .handlerFailed)
    #expect(diagnostic.detail.contains("producer failed"))
    #expect(await transport.allPublications().contains { routeEventType($0.route) == ProtocolCapability.channel.wireEventType.wireCode.description })
    await runtime.stop()
}

@Test("Discover applies ID, object type, and core type filters with correct Resolve bytes")
func discoverReturnsFilteredSensorAndThingSnapshots() async throws {
    var builder = try RuntimeBuilder(sourceID: .zero, namespace: "sensor-tests")
    try builder.sensorThings { configuration in
        try configuration.source(sensor: fixtureSensor(id: sourceIDOne, parentID: thingIDOne), thing: fixtureThing(id: thingIDOne), observationChannel: try SensorThingsChannel<Observation>("observations"), run: { _ in })
        try configuration.source(sensor: fixtureSensor(id: sourceIDTwo, parentID: thingIDOne), thing: fixtureThing(id: thingIDOne), observationChannel: try SensorThingsChannel<Observation>("observations"), run: { _ in })
    }
    let transport = SensorThingsRecordingTransport()
    let runtime = AxolotyRuntime(definition: try builder.finish(), transport: transport)
    try await runtime.start()
    try await waitForSensorThingsAdvertisementCount(transport, 3)
    let requester = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
    let topic = "coaty/3/sensor-tests/DSC/\(requester)"
    #expect(await runtime.receive(.profile(route: topic + "/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", payload: Array("{\"objectId\":\"\(sourceIDOne)\"}".utf8), nowMS: 30)) == .accepted)
    try await waitForPublicationCount(transport, capability: .resolve, count: 1)
    let sensor = try #require(await transport.allPublications().last { routeEventType($0.route) == ProtocolCapability.resolve.wireEventType.wireCode.description })
    #expect(publicationObjectID(sensor) == sourceIDOne)
    #expect(publicationObjectType(sensor) == "coaty.sensorThings.Sensor")
    #expect(await runtime.receive(.profile(route: topic + "/bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", payload: Array("{\"objectTypes\":[\"coaty.sensorThings.Thing\"]}".utf8), nowMS: 31)) == .accepted)
    try await waitForPublicationCount(transport, capability: .resolve, count: 2)
    let thing = try #require(await transport.allPublications().last { routeEventType($0.route) == ProtocolCapability.resolve.wireEventType.wireCode.description })
    #expect(publicationObjectID(thing) == thingIDOne)
    #expect(publicationObjectType(thing) == "coaty.sensorThings.Thing")
    #expect(await runtime.receive(.profile(route: topic + "/cccccccc-cccc-4ccc-8ccc-cccccccccccc", payload: Array("{\"coreTypes\":[\"CoatyObject\"]}".utf8), nowMS: 32)) == .accepted)
    try await waitForPublicationCount(transport, capability: .resolve, count: 3)
    #expect(await transport.allPublications().filter { routeEventType($0.route) == ProtocolCapability.resolve.wireEventType.wireCode.description }.count == 3)
    await runtime.stop()
}

@Test("Query responds with bounded, filtered Sensor object bytes")
func queryReturnsFilteredSensorBytesWithinBound() async throws {
    var builder = try RuntimeBuilder(sourceID: .zero, namespace: "sensor-tests")
    try builder.sensorThings(limits: try SensorThingsLimits(maximumSensors: 2, maximumObservationStreams: 2)) { configuration in
        try configuration.source(
            sensor: fixtureSensor(id: sourceIDOne, parentID: thingIDOne, description: "ignore"),
            thing: fixtureThing(id: thingIDOne),
            observationChannel: try SensorThingsChannel<Observation>("one"),
            run: { _ in }
        )
        try configuration.source(
            sensor: fixtureSensor(id: sourceIDTwo, parentID: thingIDTwo, description: "wanted"),
            thing: fixtureThing(id: thingIDTwo),
            observationChannel: try SensorThingsChannel<Observation>("two"),
            run: { _ in }
        )
    }
    let transport = SensorThingsRecordingTransport()
    let runtime = AxolotyRuntime(definition: try builder.finish(), transport: transport)
    try await runtime.start()
    try await waitForSensorThingsAdvertisementCount(transport, 8)

    let correlation = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    let requester = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
    let query = Array("{\"objectTypes\":[\"coaty.sensorThings.Sensor\"],\"objectFilter\":{\"conditions\":[\"description\",[7,\"wanted\"]]}}".utf8)
    #expect(await runtime.receive(.profile(
        route: "coaty/3/sensor-tests/QRY/\(requester)/\(correlation)",
        payload: query,
        nowMS: 20
    )) == .accepted)
    try await waitForPublicationCount(transport, capability: .retrieve, count: 1)

    let response = try #require(await transport.allPublications().last { routeEventType($0.route) == ProtocolCapability.retrieve.wireEventType.wireCode.description })
    let responseText = String(decoding: response.payload, as: UTF8.self)
    #expect(responseText.contains(sourceIDTwo))
    #expect(!responseText.contains(sourceIDOne))
    #expect(!responseText.contains(thingIDOne))

    let unfilteredQuery = Array("{\"objectTypes\":[\"coaty.sensorThings.Sensor\"]}".utf8)
    #expect(await runtime.receive(.profile(
        route: "coaty/3/sensor-tests/QRY/\(requester)/dddddddd-dddd-4ddd-8ddd-dddddddddddd",
        payload: unfilteredQuery,
        nowMS: 21
    )) == .accepted)
    try await waitForPublicationCount(transport, capability: .retrieve, count: 2)
    let boundedResponse = try #require(await transport.allPublications().last { routeEventType($0.route) == ProtocolCapability.retrieve.wireEventType.wireCode.description })
    let boundedText = String(decoding: boundedResponse.payload, as: UTF8.self)
    #expect(boundedText.contains(sourceIDOne))
    #expect(boundedText.contains(sourceIDTwo))
    #expect(!boundedText.contains("\"objectType\":\"coaty.sensorThings.Thing\""))
    await runtime.stop()
}

@Test("Query with an unsupported join produces no response")
func queryRejectsUnsupportedJoinWithoutResponse() async throws {
    var builder = try RuntimeBuilder(sourceID: .zero, namespace: "sensor-tests")
    try builder.sensorThings { configuration in
        try configuration.source(
            sensor: fixtureSensor(id: sourceIDOne, parentID: thingIDOne),
            thing: fixtureThing(id: thingIDOne),
            observationChannel: try SensorThingsChannel<Observation>("observations"),
            run: { _ in }
        )
    }
    let transport = SensorThingsRecordingTransport()
    let runtime = AxolotyRuntime(definition: try builder.finish(), transport: transport)
    try await runtime.start()
    try await waitForSensorThingsAdvertisementCount(transport, 4)
    let before = await transport.allPublications().count
    let correlation = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
    #expect(await runtime.receive(.profile(
        route: "coaty/3/sensor-tests/QRY/\(sourceIDTwo)/\(correlation)",
        payload: Array("{\"objectJoinConditions\":{}}".utf8),
        nowMS: 20
    )) == .accepted)
    try await Task.sleep(for: .milliseconds(30))
    #expect(await transport.allPublications().count == before)
    await runtime.stop()
}

private actor ProducerProbe {
    private(set) var runs = 0
    func run() async {
        runs += 1
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
    func waitForRuns(_ expected: Int) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while runs < expected {
            if clock.now >= deadline { throw SensorThingsFixtureError() }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private struct ProducerFailure: Error, Sendable {}
