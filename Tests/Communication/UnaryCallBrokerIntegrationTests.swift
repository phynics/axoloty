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

        let streamA = try await providerA.observeCallStream(operation: "selected-provider")
        let streamB = try await providerB.observeCallStream(operation: "selected-provider")
        let responderA = unaryResponder(manager: providerA, stream: streamA)
        let responderB = unaryResponder(manager: providerB, stream: streamB)

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
        _ = await responderA.value
        _ = await responderB.value
    }
}

@MainActor
private func unaryResponder(
    manager: CommunicationManager,
    stream: AsyncStream<CallEventSnapshot>
) -> Task<Void, Never> {
    Task {
        var iterator = stream.makeAsyncIterator()
        guard let call = await iterator.next(),
              let correlationId = call.correlationId,
              let filterJSON = call.filter,
              let filter = try? JSONDecoder().decode(ContextFilter.self, from: Data(filterJSON.utf8)),
              ObjectMatcher.matchesFilter(obj: manager.identity, filter: filter) else {
            return
        }
        manager.publishReturn(
            event: ReturnEvent.with(result: #""\#(manager.identity.name)""#, executionInfo: nil),
            correlationId: correlationId
        )
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
