// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@testable import Axoloty
import Foundation
import Testing

/// Verifies the CoatyJS Update -> modern Swift Complete direction.
@MainActor
struct AxolotyUpdateCompleteConsumerTests {
    @Test(.enabled(if: updateCompleteConsumerIsEnabled))
    func decodesUpdateAndPublishesCorrelatedComplete() async throws {
        let environment = ProcessInfo.processInfo.environment
        let manager = try makeUpdateCompleteConsumerManager(environment: environment)
        defer { manager.container.shutdown() }

        try await manager.container.startAndWaitUntilReady()
        let parsedStream = await manager.communication.observeParsedMessages()
        var iterator = parsedStream.makeAsyncIterator()
        let objectTypeFilter = EVENT_TYPE_FILTER_SEPARATOR + "com.coaty.test.WireFixture"
        let updateTopic = CommunicationTopic.createTopicStringByLevelsForSubscribe(
            eventType: .Update,
            eventTypeFilter: objectTypeFilter,
            namespace: environment["WIRE_NAMESPACE"] ?? "wire-compat-v1"
        )
        await manager.communication.acquireSubscription(topic: updateTopic)
        try signalUpdateCompleteReadiness(environment: environment)

        let parsed = try await nextUpdateCompleteMessage(&iterator)
        #expect(parsed.eventType == .Update)
        #expect(parsed.eventTypeFilter == objectTypeFilter)
        #expect(parsed.sourceId == "22222222-2222-4222-8222-222222222222")
        let update: UpdateEvent = try PayloadCoder.decode(parsed.payload)
        #expect(update.data.object.coreType == .CoatyObject)
        #expect(update.data.object.objectType == "com.coaty.test.WireFixture")
        #expect(update.data.object.objectId.string == "11111111-1111-4111-8111-111111111111")
        #expect(update.data.object.name == "wire-fixture")

        let completed = CoatyObject(
            coreType: .CoatyObject,
            objectType: "com.coaty.test.WireFixture",
            objectId: try #require(CoatyUUID(uuidString: "11111111-1111-4111-8111-111111111111")),
            name: "wire-fixture-completed"
        )
        let correlationId = try #require(parsed.correlationId)
        manager.communication.publishComplete(
            event: CompleteEvent.with(object: completed, privateData: ["reference": "axoloty-modern"]),
            correlationId: correlationId
        )
        emitUpdateCompleteState("{\"state\":\"ack\",\"scenario\":\"update-complete\",\"response\":\"complete\"}")
    }
}

private let updateCompleteConsumerIsEnabled =
    ProcessInfo.processInfo.environment["WIRE_JS_TO_MODERN_LIVE"] == "1" &&
    ProcessInfo.processInfo.environment["WIRE_SCENARIO"] == "update-complete"

@MainActor
private func makeUpdateCompleteConsumerManager(environment: [String: String]) throws ->
    (container: Container, communication: CommunicationManager)
{
    let container = Container.resolve(
        components: Components(controllers: [:], objectTypes: []),
        configuration: Configuration(
            common: CommonOptions(agentIdentity: [
                "name": "axoloty-modern-update-responder",
                "objectId": CoatyUUID(uuidString: "33333333-3333-4333-8333-333333333333")!,
            ]),
            communication: CommunicationOptions(
                namespace: environment["WIRE_NAMESPACE"] ?? "wire-compat-v1",
                mqttClientOptions: MQTTClientOptions(
                    host: environment["WIRE_BROKER_HOST"] ?? "127.0.0.1",
                    port: UInt16(environment["WIRE_BROKER_PORT"] ?? "1883") ?? 1883
                ),
                shouldAutoStart: false
            )
        )
    )
    guard let communication = container.communicationManager else {
        throw AxolotyError.invalidConfiguration(option: "communicationManager", reason: "container did not resolve a communication manager")
    }
    return (container, communication)
}

private func nextUpdateCompleteMessage(
    _ iterator: inout AsyncStream<ParsedMQTTMessage>.Iterator
) async throws -> ParsedMQTTMessage {
    do {
        while true {
            let message = try await nextValue(&iterator, timeout: .seconds(120))
            guard message.eventType == .Update,
                  message.eventTypeFilter == EVENT_TYPE_FILTER_SEPARATOR + "com.coaty.test.WireFixture"
            else { continue }
            return message
        }
    } catch is CancellationError {
        throw AxolotyError.runtime(code: .streamEnded, reason: "Update stream ended before CoatyJS published")
    } catch {
        throw AxolotyError.runtime(code: .timedOut, reason: "Timed out waiting for CoatyJS Update")
    }
}

private func signalUpdateCompleteReadiness(environment: [String: String]) throws {
    guard let path = environment["WIRE_READY_FILE"] else { return }
    try Data("ready\n".utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
}

private func emitUpdateCompleteState(_ line: String) {
    FileHandle.standardError.write(Data((line + "\n").utf8))
}
