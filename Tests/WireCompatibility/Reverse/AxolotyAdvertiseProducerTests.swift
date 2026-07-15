// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import Testing
import Axoloty

@Suite
@MainActor
struct AxolotyAdvertiseProducerTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["WIRE_REVERSE_LIVE"] == "1"))
    func testPublishesAdvertiseForCoatyJS() async throws {
        let environment = ProcessInfo.processInfo.environment
        let host = environment["WIRE_BROKER_HOST"] ?? "127.0.0.1"
        let port = UInt16(environment["WIRE_BROKER_PORT"] ?? "1883") ?? 1883
        let namespace = environment["WIRE_NAMESPACE"] ?? "wire-compat-v1"

        let communication = CommunicationOptions(
            namespace: namespace,
            mqttClientOptions: MQTTClientOptions(host: host, port: port),
            shouldAutoStart: false
        )
        let container = Container.resolve(
            components: Components(controllers: [:], objectTypes: []),
            configuration: Configuration(communication: communication)
        )
        defer { container.shutdown() }

        guard let manager = container.communicationManager else {
            Issue.record("Container did not resolve a communication manager")
            return
        }

        let stateStream = await manager.observeCommunicationStateStream()
        let online = _Concurrency.Task { for await state in stateStream where state == .online { return } }
        manager.start()
        try await _Concurrency.Task.sleep(for: .seconds(1))
        online.cancel()

        let object = CoatyObject(
            coreType: .CoatyObject,
            objectType: "com.coaty.test.WireFixture",
            objectId: CoatyUUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
            name: "wire-fixture"
        )
        manager.publishAdvertise(try AdvertiseEvent.with(object: object))
        try await _Concurrency.Task.sleep(for: .milliseconds(500))
    }
}
