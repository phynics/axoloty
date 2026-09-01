// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Testing
@_spi(AxolotyRuntimeAdapter) import Axoloty
import AxolotyObjectModel
import AxolotyWire
@testable import AxolotySensorThings

private let directSensorID = "11111111-1111-4111-8111-111111111111"
private let directOtherSensorID = "22222222-2222-4222-8222-222222222222"
private let directObservationID = "33333333-3333-4333-8333-333333333333"

@Test("direct observation registers only its Channel stream")
func directObservationDoesNotRegisterMetadataTraffic() async throws {
    let sensorID = ObjectID(uuid: UUID16(bytes: (16, 15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1)))
    let channel = try SensorThingsChannel<Observation>("line-7")
    var builder = try RuntimeBuilder(sourceID: .zero, namespace: "sensor-tests")
    let result = try builder.sensorThings { configuration in
        let stream = try configuration.observations(for: sensorID, channel: channel, buffering: .fail(capacity: 4))
        return (stream, 7)
    }
    #expect(result.1 == 7)
    let definition = try builder.finish()
    #expect(definition.eventStreamCount == 1)
    #expect(definition.handlerCount == 2)
    #expect(definition.moduleCount == 1)
    let transport = SensorThingsRecordingTransport()
    let runtime = AxolotyRuntime(definition: definition, transport: transport)
    try await runtime.start()
    try await Task.sleep(for: .milliseconds(25))
    #expect(await transport.allPublications().isEmpty)
    await runtime.stop()
}

@Test("matching observations are decoded from Channel bytes with context")
func directObservationDeliversMatchingObservation() async throws {
    let sensorID = try fixtureID(directSensorID)
    let channel = try SensorThingsChannel<Observation>("line-7")
    var builder = try RuntimeBuilder(sourceID: .zero, namespace: "sensor-tests")
    let stream = try builder.sensorThings { configuration in
        try configuration.observations(for: sensorID, channel: channel, buffering: .dropOldest(capacity: 2))
    }
    let runtime = AxolotyRuntime(definition: try builder.finish(), transport: SensorThingsRecordingTransport())
    try await runtime.start()
    var iterator = stream.makeAsyncIterator()
    let observation = try fixtureObservation(id: directObservationID, parentID: directSensorID)
    let sender = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    #expect(await runtime.receive(.profile(
        topic: "coaty/3/sensor-tests/CHN:line-7/\(sender)",
        payload: channelPayload(observation),
        nowMS: 42
    )) == .accepted)
    let delivery = try #require(await iterator.next())
    #expect(delivery.context.sourceID == (try fixtureID(sender).uuid))
    #expect(delivery.context.receiptTimeMS == 42)
    #expect(delivery.observation.value.result.encodedEquals("21.5"))
    await runtime.stop()
}

@Test("mismatched parents and malformed observations are ignored by direct streams")
func directObservationDropsMismatchedAndMalformedPayloads() async throws {
    let sensorID = try fixtureID(directSensorID)
    let channel = try SensorThingsChannel<Observation>("line-7")
    var builder = try RuntimeBuilder(sourceID: .zero, namespace: "sensor-tests")
    let stream = try builder.sensorThings { configuration in
        try configuration.observations(for: sensorID, channel: channel, buffering: .dropOldest(capacity: 2))
    }
    let runtime = AxolotyRuntime(definition: try builder.finish(), transport: SensorThingsRecordingTransport())
    let diagnostics = await runtime.diagnostics()
    try await runtime.start()
    var iterator = stream.makeAsyncIterator()
    let sender = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    let mismatched = try fixtureObservation(id: directObservationID, parentID: directOtherSensorID)
    #expect(await runtime.receive(.profile(
        topic: "coaty/3/sensor-tests/CHN:line-7/\(sender)",
        payload: channelPayload(mismatched),
        nowMS: 42
    )) == .accepted)
    #expect(await runtime.receive(.profile(
        topic: "coaty/3/sensor-tests/CHN:line-7/\(sender)",
        payload: Array("{\"object\":{\"notAnObservation\":true}}".utf8),
        nowMS: 43
    )) == .accepted)
    await runtime.stop()
    #expect(await iterator.next() == nil)
    let diagnostic = try await nextDiagnostic(from: diagnostics)
    #expect(diagnostic.kind == .malformedPayload)
    #expect(diagnostic.detail.contains("Observation Channel payload"))
}

@Test("runtime stop finishes a direct public observation stream")
func directObservationStreamFinishesOnRuntimeStop() async throws {
    var builder = try RuntimeBuilder(sourceID: .zero, namespace: "sensor-tests")
    let stream = try builder.sensorThings { configuration in
        try configuration.observations(
            for: try fixtureID(directSensorID),
            channel: try SensorThingsChannel<Observation>("line-7"),
            buffering: .fail(capacity: 2)
        )
    }
    let runtime = AxolotyRuntime(definition: try builder.finish(), transport: SensorThingsRecordingTransport())
    try await runtime.start()
    var iterator = stream.makeAsyncIterator()
    await runtime.stop()
    #expect(await iterator.next() == nil)
}

@Test("strict direct observation buffering reports saturation")
func directObservationBufferSaturationIsDiagnosed() async throws {
    var builder = try RuntimeBuilder(sourceID: .zero, namespace: "sensor-tests")
    let stream = try builder.sensorThings { configuration in
        try configuration.observations(
            for: try fixtureID(directSensorID),
            channel: try SensorThingsChannel<Observation>("line-7"),
            buffering: .fail(capacity: 1)
        )
    }
    let transport = SensorThingsRecordingTransport()
    let runtime = AxolotyRuntime(definition: try builder.finish(), transport: transport)
    let diagnostics = await runtime.diagnostics()
    try await runtime.start()
    let sender = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    let first = try fixtureObservation(id: directObservationID, parentID: directSensorID, result: "1")
    let second = try fixtureObservation(id: "44444444-4444-4444-8444-444444444444", parentID: directSensorID, result: "2")
    let topic = "coaty/3/sensor-tests/CHN:line-7/\(sender)"
    #expect(await runtime.receive(.profile(topic: topic, payload: channelPayload(first), nowMS: 1)) == .accepted)
    #expect(await runtime.receive(.profile(topic: topic, payload: channelPayload(second), nowMS: 2)) == .accepted)
    #expect(await runtime.state() == .failed)
    let diagnostic = try await nextDiagnostic(from: diagnostics)
    #expect(diagnostic.kind == .capacityExceeded)
    var iterator = stream.makeAsyncIterator()
    #expect(await iterator.next() != nil)
    await runtime.stop()
}

@Test("publisher preserves ignored and rejected runtime receipts")
func publisherReceiptFidelity() async throws {
    let sensorID = try fixtureID(directSensorID)
    let ignored = SensorThingsPublisher(sensorID: sensorID, channelID: "line-7", submit: { _ in .ignored })
    do {
        try await ignored.deadvertise(sensorID)
        Issue.record("ignored publisher receipt unexpectedly succeeded")
    } catch let error as AxolotyError {
        #expect(error.userFriendlyMessage.contains("ignored"))
    }
    let rejected = SensorThingsPublisher(
        sensorID: sensorID,
        channelID: "line-7",
        submit: { _ in .rejected(.protocol(.duplicate)) }
    )
    do {
        try await rejected.deadvertise(sensorID)
        Issue.record("rejected publisher receipt unexpectedly succeeded")
    } catch let error as AxolotyError {
        #expect(error.userFriendlyMessage.contains("protocol"))
    }
}
