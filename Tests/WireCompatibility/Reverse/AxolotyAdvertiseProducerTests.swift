// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation
import Testing

@MainActor
struct AxolotyAdvertiseProducerTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["WIRE_REVERSE_LIVE"] == "1"))
    func publishesAdvertiseForCoatyJS() async throws {
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

        if container.communicationManager == nil {
            Issue.record("Container did not resolve a communication manager")
            return
        }

        // Waits for the actual online transition rather than guessing how
        // long connecting takes; see Container.startAndWaitUntilReady().
        try await container.startAndWaitUntilReady()

        let object = try CoatyObject(
            coreType: .CoatyObject,
            objectType: "com.coaty.test.WireFixture",
            objectId: #require(CoatyUUID(uuidString: "11111111-1111-4111-8111-111111111111")),
            name: "wire-fixture"
        )
        try container.communicationManager?.publishAdvertise(AdvertiseEvent.with(object: object))

        // `publish` has no completion signal to await: the underlying
        // CommunicationClient protocol's publish methods are synchronous,
        // fire-and-forget calls with no future or callback for "the packet
        // reached the wire". Without some wait here, `container.shutdown()`
        // (deferred above) could tear down the MQTT connection before this
        // publish is flushed. This is the one wait in this suite with no
        // observable condition to poll instead of a fixed duration.
        try await _Concurrency.Task.sleep(for: .milliseconds(500))
    }
}
