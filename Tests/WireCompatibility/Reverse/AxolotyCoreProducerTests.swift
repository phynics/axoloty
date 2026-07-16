// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@testable import Axoloty
import Foundation
import Testing

@MainActor
struct AxolotyCoreProducerTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["WIRE_REVERSE_LIVE"] == "1"))
    func publishesCoreEventsForCoatyJS() async throws {
        let environment = ProcessInfo.processInfo.environment
        let scenario = try #require(environment["WIRE_SCENARIO"])
        let manager = try makeManager(environment: environment)
        defer { manager.container.shutdown() }

        try await _Concurrency.Task.sleep(for: .seconds(1))
        switch scenario {
        case "deadvertise":
            manager.communication.publishDeadvertise(DeadvertiseEvent.with(objectIds: [fixture.objectId]))
        case "channel":
            try manager.communication.publishChannel(ChannelEvent.with(
                object: fixture, channelId: "wire-fixture-channel", privateData: ["sequence": 7]
            ))
        case "discover-resolve":
            let response = try await awaitResponse(
                from: await manager.communication.publishDiscover(DiscoverEvent.with(objectTypes: [fixture.objectType])),
                eventType: .Resolve,
                as: ResolveEvent.self
            )
            let resolved = try #require(response.data.object)
            #expect(resolved.objectId == fixture.objectId)
            #expect(response.data.privateData?["responder"] as? String == "coatyjs-2.4.0")
        case "query-retrieve":
            let response = try await awaitResponse(
                from: await manager.communication.publishQuery(QueryEvent.with(objectTypes: [fixture.objectType])),
                eventType: .Retrieve,
                as: RetrieveEvent.self
            )
            #expect(response.data.objects.first?.objectId == fixture.objectId)
            #expect(response.data.privateData?["responder"] as? String == "coatyjs-2.4.0")
        case "update-complete":
            let response = try await awaitResponse(
                from: await manager.communication.publishUpdate(UpdateEvent.with(object: fixture)),
                eventType: .Complete,
                as: CompleteEvent.self
            )
            let completed = try #require(response.data.object)
            #expect(completed.objectId == fixture.objectId)
            #expect(completed.name == "wire-fixture-completed")
            #expect(response.data.privateData?["responder"] as? String == "coatyjs-2.4.0")
        case "call-return":
            let response = try await awaitResponse(
                from: await manager.communication.publishCall(CallEvent.with(
                    operation: "wire-fixture-operation", parameters: ["operand": AnyCodable(7)]
                )),
                eventType: .Return,
                as: ReturnEvent.self
            )
            let result = try #require(response.data.result?.value as? [String: AnyCodable])
            #expect(result["answer"]?.value as? Int == 49)
            #expect(result["objectId"]?.value as? String == fixture.objectId.string)
            let executionInfo = try #require(response.data.executionInfo?.value as? [String: AnyCodable])
            #expect(executionInfo["responder"]?.value as? String == "coatyjs-2.4.0")
        default:
            Issue.record("Unsupported core wire scenario: \(scenario)")
        }
        try await _Concurrency.Task.sleep(for: .milliseconds(250))
    }

    private var fixture: CoatyObject {
        CoatyObject(
            coreType: .CoatyObject,
            objectType: "com.coaty.test.WireFixture",
            objectId: CoatyUUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
            name: "wire-fixture"
        )
    }

    private func makeManager(environment: [String: String]) throws -> (container: Container, communication: CommunicationManager) {
        let host = environment["WIRE_BROKER_HOST"] ?? "127.0.0.1"
        let port = UInt16(environment["WIRE_BROKER_PORT"] ?? "1883") ?? 1883
        let namespace = environment["WIRE_NAMESPACE"] ?? "wire-compat-v1"
        let common = CommonOptions(agentIdentity: [
            "name": "axoloty-core-producer",
            "objectId": CoatyUUID(uuidString: "22222222-2222-4222-8222-222222222222")!,
        ])
        let container = Container.resolve(
            components: Components(controllers: [:], objectTypes: []),
            configuration: Configuration(
                common: common,
                communication: CommunicationOptions(
                    namespace: namespace,
                    mqttClientOptions: MQTTClientOptions(host: host, port: port),
                    shouldAutoStart: false
                )
            )
        )
        guard let communication = container.communicationManager else {
            throw AxolotyError.InvalidConfiguration("Container did not resolve a communication manager")
        }
        communication.start()
        return (container, communication)
    }

    private func awaitResponse<Event: Codable>(
        from stream: EventStream<ResponseEventSnapshot>,
        eventType: CommunicationEventType,
        as _: Event.Type
    ) async throws -> Event {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        var iterator = await stream.makeAsyncIteratorAndWait()
        while clock.now < deadline {
            let response = try await nextValue(
                &iterator,
                timeout: clock.now.duration(to: deadline)
            )
            guard response.eventType == eventType.rawValue,
                  response.sourceId == "33333333-3333-4333-8333-333333333333",
                  let payload = String(data: response.payload, encoding: .utf8),
                  let event: Event = PayloadCoder.decode(payload)
            else {
                continue
            }
            return event
        }
        throw AxolotyError.RuntimeError("Timed out waiting for a \(eventType.rawValue) response")
    }
}

private final class EventStreamIteratorBox<Element: Sendable>: @unchecked Sendable {
    var iterator: EventStream<Element>.Iterator

    init(_ iterator: EventStream<Element>.Iterator) {
        self.iterator = iterator
    }
}

private func nextValue<Element: Sendable>(
    _ iterator: inout EventStream<Element>.Iterator,
    timeout: Duration
) async throws -> Element {
    let box = EventStreamIteratorBox(iterator)
    defer { iterator = box.iterator }

    return try await withThrowingTaskGroup(of: Element.self) { group in
        group.addTask {
            guard let value = await box.iterator.next() else {
                throw CancellationError()
            }
            return value
        }
        group.addTask {
            try await _Concurrency.Task.sleep(for: timeout)
            throw AxolotyError.RuntimeError("Timed out waiting for the next wire response event")
        }
        guard let value = try await group.next() else {
            throw AxolotyError.RuntimeError("Timed out waiting for the next wire response event")
        }
        group.cancelAll()
        return value
    }
}
