// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import RxSwift
import Testing
@testable import Axoloty

/// Tests that transport-level state and raw MQTT messages are mirrored into
/// the Swift concurrency ``EventHub`` while the legacy Rx subjects remain
/// source-compatible.
@Suite
struct EventHubTransportTests {

    @Test
    func testCommunicationStateReplayThroughManagerEventHub() async throws {
        let manager = makeManager()
        let fakeClient = FakeCommunicationClient(delegate: manager)
        manager.client = fakeClient

        await fakeClient.simulateState(.online)

        let stream: EventStream<CommunicationState> = await manager.observeCommunicationStateStream()
        var iterator = stream.makeAsyncIterator()

        let state = try await nextValue(&iterator, timeout: .milliseconds(500))
        #expect(state == .online)
    }

    @Test
    func testMultipleConsumersReceiveRawMQTTMessages() async throws {
        let manager = makeManager()
        let fakeClient = FakeCommunicationClient(delegate: manager)
        manager.client = fakeClient

        let stream: EventStream<RawMQTTMessage> = await manager.observeRawMQTTMessageStream()
        var iteratorOne = stream.makeAsyncIterator()
        var iteratorTwo = stream.makeAsyncIterator()

        // Give the async iterator continuations time to register with the hub
        // before yielding, because raw messages are not replayed.
        try? await _Concurrency.Task.sleep(for: .milliseconds(100))

        await fakeClient.simulateRawMessage(topic: "external/topic", payload: [0xAB, 0xCD])

        let messageOne = try await nextValue(&iteratorOne, timeout: .milliseconds(500))
        let messageTwo = try await nextValue(&iteratorTwo, timeout: .milliseconds(500))

        #expect(messageOne == RawMQTTMessage(topic: "external/topic", payload: [0xAB, 0xCD]))
        #expect(messageTwo == messageOne)
    }

    @Test
    func testMQTTNIOClientMirrorsStateChangesToEventHub() async throws {
        let delegate = FakeStartable()
        let options = MQTTClientOptions(
            host: "127.0.0.1",
            port: 1883,
            shouldTryMDNSDiscovery: false,
            autoReconnect: false
        )
        options.clientId = "test-client"
        let client = MQTTNIOClient(mqttClientOptions: options, delegate: delegate)

        client.updateCommunicationState(.online)
        try? await _Concurrency.Task.sleep(for: .milliseconds(50))

        let stream: EventStream<CommunicationState> = await client.eventHub.registerStream(
            key: CommunicationEventHubKeys.communicationState,
            buffering: .state,
            onFirst: {},
            onLast: {}
        )
        var iterator = stream.makeAsyncIterator()

        let state = try await nextValue(&iterator, timeout: .milliseconds(500))
        #expect(state == .online)
    }
}

// MARK: - Helpers

private struct TimeoutError: Error {}

private final class IteratorBox<T: Sendable>: @unchecked Sendable {
    var iterator: EventStream<T>.Iterator
    init(_ iterator: EventStream<T>.Iterator) { self.iterator = iterator }
}

private func nextValue<T: Sendable>(
    _ iterator: inout EventStream<T>.Iterator,
    timeout: Duration
) async throws -> T {
    let box = IteratorBox(iterator)
    defer { iterator = box.iterator }

    return try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            guard let value = await box.iterator.next() else {
                throw CancellationError()
            }
            return value
        }

        group.addTask {
            try await _Concurrency.Task.sleep(for: timeout)
            throw TimeoutError()
        }

        guard let value = try await group.next() else {
            throw TimeoutError()
        }
        group.cancelAll()
        return value
    }
}

private func makeManager() -> CommunicationManager {
    let mqttOptions = MQTTClientOptions(
        host: "127.0.0.1",
        port: 1883,
        shouldTryMDNSDiscovery: false,
        autoReconnect: false
    )
    let communicationOptions = CommunicationOptions(
        namespace: nil,
        shouldEnableCrossNamespacing: false,
        mqttClientOptions: mqttOptions,
        shouldAutoStart: false
    )
    return CommunicationManager(
        identity: Identity(name: "TestIdentity"),
        communicationOptions: communicationOptions,
        commonOptions: nil
    )
}

// MARK: - Test seam

private final class FakeStartable: Startable {
    func didReceiveStart() {}
}

private final class FakeCommunicationClient: CommunicationClient, @unchecked Sendable {

    let rawMQTTMessages = PublishSubject<(String, [UInt8])>()
    let ioValueMessages = PublishSubject<(String, [UInt8])>()
    let messages = PublishSubject<(CommunicationTopic, String)>()
    let communicationState = BehaviorSubject<CommunicationState>(value: .offline)
    let eventHub = EventHub()
    var delegate: Startable

    init(delegate: Startable) {
        self.delegate = delegate
    }

    func simulateState(_ state: CommunicationState) async {
        communicationState.onNext(state)
        await eventHub.yieldState(
            value: state,
            to: CommunicationEventHubKeys.communicationState
        )
    }

    func simulateRawMessage(topic: String, payload: [UInt8]) async {
        rawMQTTMessages.onNext((topic, payload))
        await eventHub.yield(
            value: RawMQTTMessage(topic: topic, payload: payload),
            to: CommunicationEventHubKeys.rawMQTTMessage
        )
    }

    func connect(lastWillTopic: String, lastWillMessage: String) {}
    func disconnect() {}
    func publish(_ topic: String, message: String) {}
    func publish(_ topic: String, message: [UInt8]) {}
    func subscribe(_ topic: String) {}
    func unsubscribe(_ topic: String) {}
}
