// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import Testing
import Axoloty

@Suite
@MainActor
struct AxolotyCoreProducerTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["WIRE_REVERSE_LIVE"] == "1"))
    func testPublishesCoreEventsForCoatyJS() async throws {
        let environment = ProcessInfo.processInfo.environment
        let scenario = try #require(environment["WIRE_SCENARIO"])
        let manager = try makeManager(environment: environment)
        defer { manager.container.shutdown() }

        try await _Concurrency.Task.sleep(for: .seconds(1))
        switch scenario {
        case "deadvertise":
            manager.communication.publishDeadvertise(DeadvertiseEvent.with(objectIds: [fixture.objectId]))
        case "channel":
            manager.communication.publishChannel(try ChannelEvent.with(
                object: fixture, channelId: "wire-fixture-channel", privateData: ["sequence": 7]
            ))
        case "discover-resolve":
            _ = await manager.communication.publishDiscover(DiscoverEvent.with(objectTypes: [fixture.objectType]))
        case "query-retrieve":
            _ = await manager.communication.publishQuery(QueryEvent.with(objectTypes: [fixture.objectType]))
        case "update-complete":
            _ = await manager.communication.publishUpdate(try UpdateEvent.with(object: fixture))
        case "call-return":
            _ = await manager.communication.publishCall(try CallEvent.with(
                operation: "wire-fixture-operation", parameters: ["operand": AnyCodable(7)]
            ))
        default:
            Issue.record("Unsupported core wire scenario: \(scenario)")
        }
        try await _Concurrency.Task.sleep(for: .milliseconds(750))
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
            "objectId": CoatyUUID(uuidString: "22222222-2222-4222-8222-222222222222")!
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
}
