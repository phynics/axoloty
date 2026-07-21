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
            let filter = ObjectFilter(condition: ObjectFilterCondition(
                property: ObjectFilterProperty("name"),
                expression: .equals("wire-fixture")
            ))
            let queryEvent = QueryEvent.with(objectTypes: [fixture.objectType], objectFilter: filter)
            // #134: the CoatyJS consumer emits its "ready" signal on a fixed
            // 500ms timer (`coatyjs-core-consumer.js`) rather than gating on the
            // MQTT SUBACK, so the first QRY can race the broker's subscription
            // confirmation and be dropped (0 RTV). By the retry the consumer's
            // subscription is confirmed, so the second QRY is delivered. The
            // proper fix is a subscribe-then-ping-self handshake on the
            // consumer (CoatyJS doesn't expose SUBACK); this producer-side
            // retry is the pragmatic workaround the ticket offers.
            let response: RetrieveEvent
            do {
                response = try await awaitResponse(
                    from: await manager.communication.publishQuery(queryEvent),
                    eventType: .Retrieve,
                    as: RetrieveEvent.self
                )
            } catch let error as AxolotyError {
                guard case .runtime(code: .timedOut, reason: _) = error else { throw error }
                response = try await awaitResponse(
                    from: await manager.communication.publishQuery(queryEvent),
                    eventType: .Retrieve,
                    as: RetrieveEvent.self
                )
            }
            #expect(response.data.objects.first?.objectId == fixture.objectId)
            #expect(response.data.privateData?["responder"] as? String == "coatyjs-2.4.0")
        case "query-retrieve-filter-negative":
            let filter = ObjectFilter(condition: ObjectFilterCondition(
                property: ObjectFilterProperty("name"),
                expression: .equals("no-match")
            ))
            let stream = await manager.communication.publishQuery(
                QueryEvent.with(objectTypes: [fixture.objectType], objectFilter: filter)
            )
            await assertNoRetrieveResponse(stream, label: "negative string")
        case "query-retrieve-filter-operands":
            let operands: [(String, FilterOperand)] = [
                ("int", 42),
                ("double", 42.5),
                ("bool", true),
                ("null", .null),
            ]
            for (label, operand) in operands {
                let filter = ObjectFilter(condition: ObjectFilterCondition(
                    property: ObjectFilterProperty("name"),
                    expression: .equals(operand)
                ))
                let stream = await manager.communication.publishQuery(
                    QueryEvent.with(objectTypes: [fixture.objectType], objectFilter: filter)
                )
                await assertNoRetrieveResponse(stream, label: label)
            }
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
            let resultJSON = try #require(response.data.result)
            let result = try JSONDecoder().decode(CallReturnResult.self, from: Data(resultJSON.utf8))
            #expect(result.answer == 49)
            #expect(result.objectId == fixture.objectId.string)
            let execJSON = try #require(response.data.executionInfo)
            let execInfo = try JSONDecoder().decode(CallReturnExecInfo.self, from: Data(execJSON.utf8))
            #expect(execInfo.responder == "coatyjs-2.4.0")
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
            throw AxolotyError.invalidConfiguration(option: "communicationManager", reason: "container did not resolve a communication manager")
        }
        try communication.start()
        return (container, communication)
    }

    private func awaitResponse<Event: Codable>(
        from stream: AsyncStream<ResponseEventSnapshot>,
        eventType: CommunicationEventType,
        as _: Event.Type
    ) async throws -> Event {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        var iterator = stream.makeAsyncIterator()
        while clock.now < deadline {
            let response = try await nextValue(
                &iterator,
                timeout: clock.now.duration(to: deadline)
            )
            guard response.eventType == eventType.rawValue,
                  response.sourceId == "33333333-3333-4333-8333-333333333333",
                  let payload = String(data: response.payload, encoding: .utf8),
                  let event: Event = try? PayloadCoder.decode(payload)
            else {
                continue
            }
            return event
        }
        throw AxolotyError.runtime(code: .timedOut, reason: "Timed out waiting for a \(eventType.rawValue) response")
    }

    /// Asserts that no Retrieve response arrives from the CoatyJS consumer
    /// within the given timeout, proving a filter that should not match was
    /// correctly evaluated as "no match" by the reference implementation.
    private func assertNoRetrieveResponse(
        _ stream: AsyncStream<ResponseEventSnapshot>,
        timeout: Duration = .seconds(3),
        label: String
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var iterator = stream.makeAsyncIterator()
        while clock.now < deadline {
            do {
                let response = try await nextValue(
                    &iterator,
                    timeout: clock.now.duration(to: deadline)
                )
                guard response.eventType == CommunicationEventType.Retrieve.rawValue,
                      response.sourceId == "33333333-3333-4333-8333-333333333333" else {
                    continue
                }
                Issue.record("Unexpected Retrieve from CoatyJS for \(label) filter — the filter should not have matched")
                return
            } catch {
                return
            }
        }
    }
}

/// Typed decode of the `call-return` result payload sent by the CoatyJS
/// reference consumer (`coatyjs-core-consumer.js`). Mirrors the private
/// `ReturnPayload.Result` struct in `CoatyJsCallReturnCaptureTests.swift`.
private struct CallReturnResult: Codable {
    let answer: Int
    let objectId: String
}

/// Typed decode of the `call-return` executionInfo payload.
private struct CallReturnExecInfo: Codable {
    let responder: String
}
