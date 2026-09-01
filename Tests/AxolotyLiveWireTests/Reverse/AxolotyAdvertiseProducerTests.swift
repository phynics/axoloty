// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import AxolotyProtocol
import AxolotyWire
import Foundation
import Testing

@MainActor
struct AxolotyAdvertiseProducerTests {
    private static let sourceID = UUID16(parsing: "22222222-2222-4222-8222-222222222222")!

    @Test(.enabled(if: ProcessInfo.processInfo.environment["WIRE_REVERSE_LIVE"] == "1"))
    func publishesAdvertiseForCoatyJS() async throws {
        let environment = ProcessInfo.processInfo.environment
        let runtime = try makeRuntime(environment: environment)
        do {
            try await runtime.start()
            #expect(await runtime.publish(.advertise(fixturePayload)) == .accepted)
            let namespace = environment["WIRE_NAMESPACE"] ?? "wire-compat-v1"
            ModernConsumerSupport.emit(
                "{\"state\":\"awaiting-peer-ack\",\"phase\":\"peer-ack\",\"scenario\":\"axoloty-advertise\",\"namespace\":\"\(namespace)\",\"sourceId\":\"\(Self.sourceID)\"}"
            )
            try await ModernConsumerSupport.awaitPeerAcknowledgement(
                environment: environment,
                scenario: "axoloty-advertise",
                context: "namespace=\(namespace) sourceId=\(Self.sourceID)",
                timeout: .seconds(60)
            )
            await runtime.stop()
        } catch {
            await runtime.stop()
            throw error
        }
    }

    private var fixturePayload: [UInt8] {
        Array(#"{"object":{"coreType":"CoatyObject","objectType":"com.coaty.test.WireFixture","objectId":"11111111-1111-4111-8111-111111111111","name":"wire-fixture"}}"#.utf8)
    }

    private func makeRuntime(environment: [String: String]) throws -> AxolotyRuntime {
        let host = environment["WIRE_BROKER_HOST"] ?? "127.0.0.1"
        let port = UInt16(environment["WIRE_BROKER_PORT"] ?? "1883") ?? 1883
        let namespace = environment["WIRE_NAMESPACE"] ?? "wire-compat-v1"
        let identity = try RuntimeIdentity(id: Self.sourceID, name: "axoloty-advertise-producer")
        let builder = try RuntimeBuilder(identity: identity, namespace: namespace)
        let definition = try builder.finish()
        let binding = try MQTTBinding(configuration: try MQTTBindingConfiguration(host: host, port: port))
        return AxolotyRuntime(definition: definition, transport: binding)
    }
}
