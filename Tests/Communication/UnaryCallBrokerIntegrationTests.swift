// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@testable import Axoloty
import Foundation
import Testing

/// Broker-backed coverage for context-selected unary Call routing.
@MainActor
struct UnaryCallBrokerIntegrationTests {
    @Test
    func contextSelectsOneOfTwoProviders() async throws {
        let caller = makeUnaryBrokerManager(identityName: "caller")
        let providerA = makeUnaryBrokerManager(identityName: "provider-a")
        let providerB = makeUnaryBrokerManager(identityName: "provider-b")
        defer {
            caller.stop()
            providerA.stop()
            providerB.stop()
        }

        try await caller.startAndWaitUntilReady()
        try await providerA.startAndWaitUntilReady()
        try await providerB.startAndWaitUntilReady()

        let registrationA = try await providerA.registerCallHandler(
            operation: "selected-provider",
            context: providerA.identity
        ) { _ in
            .success(result: #""provider-a""#)
        }
        let registrationB = try await providerB.registerCallHandler(
            operation: "selected-provider",
            context: providerB.identity
        ) { _ in
            .success(result: #""provider-b""#)
        }
        defer {
            registrationA.cancel()
            registrationB.cancel()
        }

        let context = ObjectFilter(condition: ObjectFilterCondition(
            property: ObjectFilterProperty("name"),
            expression: .equals("provider-b")
        ))
        let result = try await caller.call(
            operation: "selected-provider",
            parameters: #"{"input":41}"#,
            context: context,
            timeout: .seconds(3)
        )

        #expect(result.result == #""provider-b""#)
        #expect(result.sourceId == providerB.identity.objectId.string)
    }
}

@MainActor
private func makeUnaryBrokerManager(identityName: String) -> CommunicationManager {
    let mqtt = MQTTClientOptions(
        host: "127.0.0.1",
        port: 1883,
        shouldTryMDNSDiscovery: false,
        autoReconnect: false
    )
    let options = CommunicationOptions(
        namespace: "unary-call-integration",
        shouldEnableCrossNamespacing: false,
        mqttClientOptions: mqtt,
        shouldAutoStart: false
    )
    // The options above always include an MQTT client configuration.
    // swiftlint:disable:next force_try
    return try! CommunicationManager(identity: Identity(name: identityName), communicationOptions: options, commonOptions: nil)
}
