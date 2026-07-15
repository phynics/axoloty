// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import RxSwift
import Testing
@testable import Axoloty

/// Tests the async ``EventStream`` based Advertise observation API while keeping
/// the legacy Rx APIs untouched.
@Suite
struct AdvertiseEventStreamTests {

    @Test
    func testCoreTypeFilterReceivesMatchingAdvertise() async throws {
        let (manager, fakeClient) = try await makeOnlineManager()
        let stream = await manager.observeAdvertiseStream(withCoreType: .Identity)

        let snapshot = try await receiveOne(
            stream,
            after: { await fakeClient.simulateAdvertise(topic: identityTopic(), payload: identityPayload()) }
        )

        #expect(snapshot.object.objectType == "coaty.Identity")
        #expect(snapshot.object.coreType == .Identity)
        #expect(snapshot.sourceId == sourceId)
        #expect(snapshot.eventTypeFilter == "Identity")
    }

    @Test
    func testObjectTypeFilterReceivesOnlyMatchingObjectType() async throws {
        let (manager, fakeClient) = try await makeOnlineManager()
        let stream = try await manager.observeAdvertiseStream(withObjectType: "coaty.User")

        var iterator = stream.makeAsyncIterator()
        try? await _Concurrency.Task.sleep(for: .milliseconds(50))

        await fakeClient.simulateAdvertise(topic: userTopic(), payload: userPayload())
        await fakeClient.simulateAdvertise(topic: identityTopic(), payload: identityPayload())

        let snapshot = try await nextValue(&iterator, timeout: .milliseconds(500))
        #expect(snapshot.object.objectType == "coaty.User")

        await #expect(throws: TimeoutError.self) {
            var iterator = stream.makeAsyncIterator()
            try? await _Concurrency.Task.sleep(for: .milliseconds(50))
            _ = try await nextValue(&iterator, timeout: .milliseconds(100))
        }
    }

    @Test
    func testMalformedAdvertisePayloadIsDropped() async throws {
        let (manager, fakeClient) = try await makeOnlineManager()
        let stream = await manager.observeAdvertiseStream(withCoreType: .CoatyObject)

        let snapshot = try await receiveOne(
            stream,
            after: {
                await fakeClient.simulateAdvertise(topic: coatyObjectTopic(), payload: "{}")
                await fakeClient.simulateAdvertise(topic: coatyObjectTopic(), payload: coatyObjectPayload())
            }
        )

        #expect(snapshot.object.objectType == "coaty.CoatyObject")
    }

    @Test
    func testStreamDoesNotReplayHistoricalMessages() async throws {
        let (manager, fakeClient) = try await makeOnlineManager()
        await fakeClient.simulateAdvertise(topic: identityTopic(), payload: identityPayload())

        let stream = await manager.observeAdvertiseStream(withCoreType: .Identity)

        await #expect(throws: TimeoutError.self) {
            try await receiveOne(stream, after: {})
        }

        let snapshot = try await receiveOne(
            stream,
            after: { await fakeClient.simulateAdvertise(topic: identityTopic(), payload: identityPayload()) }
        )
        #expect(snapshot.object.objectType == "coaty.Identity")
    }

    @Test
    func testMultipleConsumersReceiveSameSnapshot() async throws {
        let (manager, fakeClient) = try await makeOnlineManager()
        let stream = await manager.observeAdvertiseStream(withCoreType: .Identity)

        var iteratorOne = stream.makeAsyncIterator()
        var iteratorTwo = stream.makeAsyncIterator()
        try? await _Concurrency.Task.sleep(for: .milliseconds(50))

        await fakeClient.simulateAdvertise(topic: identityTopic(), payload: identityPayload())

        let one = try await nextValue(&iteratorOne, timeout: .milliseconds(500))
        let two = try await nextValue(&iteratorTwo, timeout: .milliseconds(500))

        #expect(one == two)
    }

    @Test
    func testStreamUnsubscribeAndReuse() async throws {
        let (manager, fakeClient) = try await makeOnlineManager()
        let subscribeTopic = CommunicationTopic.createTopicStringByLevelsForSubscribe(
            eventType: .Advertise,
            eventTypeFilter: CoreType.Identity.rawValue,
            namespace: "-"
        )

        let first = try await receiveOne(
            await manager.observeAdvertiseStream(withCoreType: .Identity),
            after: { await fakeClient.simulateAdvertise(topic: identityTopic(), payload: identityPayload()) }
        )
        #expect(first.object.objectType == "coaty.Identity")

        try? await _Concurrency.Task.sleep(for: .milliseconds(50))
        #expect(fakeClient.unsubscribedTopics.contains(subscribeTopic))

        let second = try await receiveOne(
            await manager.observeAdvertiseStream(withCoreType: .Identity),
            after: { await fakeClient.simulateAdvertise(topic: identityTopic(), payload: identityPayload()) }
        )
        #expect(second.object.objectType == "coaty.Identity")
        #expect(fakeClient.subscribedTopics.filter { $0 == subscribeTopic }.count == 2)
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

private func receiveOne<T: Sendable>(
    _ stream: EventStream<T>,
    after action: () async -> Void
) async throws -> T {
    var iterator = stream.makeAsyncIterator()
    try? await _Concurrency.Task.sleep(for: .milliseconds(50))
    await action()
    return try await nextValue(&iterator, timeout: .milliseconds(500))
}

private func makeOnlineManager() async throws -> (CommunicationManager, FakeCommunicationClient) {
    let manager = makeManager()
    let fakeClient = FakeCommunicationClient(delegate: manager)
    manager.client = fakeClient
    await fakeClient.simulateState(.online)
    return (manager, fakeClient)
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

private let sourceId = "550e8400-e29b-41d4-a716-446655440001"

private func identityTopic() -> String {
    "coaty/1/-/ADV:Identity/\(sourceId)"
}

private func userTopic() -> String {
    "coaty/1/-/ADV:User/\(sourceId)"
}

private func coatyObjectTopic() -> String {
    "coaty/1/-/ADV:CoatyObject/\(sourceId)"
}

private func identityPayload() -> String {
    """
    {"object":{"objectId":"550e8400-e29b-41d4-a716-446655440002","coreType":"Identity","objectType":"coaty.Identity","name":"Test Identity"}}
    """
}

private func userPayload() -> String {
    """
    {"object":{"objectId":"550e8400-e29b-41d4-a716-446655440003","coreType":"User","objectType":"coaty.User","name":"Test User"}}
    """
}

private func coatyObjectPayload() -> String {
    """
    {"object":{"objectId":"550e8400-e29b-41d4-a716-446655440004","coreType":"CoatyObject","objectType":"coaty.CoatyObject","name":"Test Object"}}
    """
}

// MARK: - Test seam

private final class FakeCommunicationClient: CommunicationClient, @unchecked Sendable {

    let rawMQTTMessages = PublishSubject<(String, [UInt8])>()
    let ioValueMessages = PublishSubject<(String, [UInt8])>()
    let messages = PublishSubject<(CommunicationTopic, String)>()
    let communicationState = BehaviorSubject<CommunicationState>(value: .offline)
    let eventHub = EventHub()
    var delegate: Startable

    var subscribedTopics: [String] = []
    var unsubscribedTopics: [String] = []

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

    func simulateAdvertise(topic: String, payload: String) async {
        guard let parsedTopic = try? CommunicationTopic(topic) else {
            return
        }
        messages.onNext((parsedTopic, payload))

        let parsed = ParsedMQTTMessage(topic: parsedTopic, payload: payload)
        await eventHub.yield(
            value: parsed,
            to: CommunicationEventHubKeys.parsedMQTTMessage
        )

        if let snapshot = AdvertiseEventSnapshot(parsedMQTTMessage: parsed) {
            let baseKey = CommunicationEventHubKeys.advertise(
                eventTypeFilter: parsed.eventTypeFilter ?? ""
            )
            await eventHub.yield(value: snapshot, to: baseKey)

            if let coreType = CoreType.getCoreType(forObjectType: snapshot.object.objectType),
               parsed.eventTypeFilter == coreType.rawValue {
                let objectKey = CommunicationEventHubKeys.advertise(
                    eventTypeFilter: coreType.rawValue,
                    objectTypeFilter: snapshot.object.objectType
                )
                await eventHub.yield(value: snapshot, to: objectKey)
            }
        }
    }

    func connect(lastWillTopic: String, lastWillMessage: String) {}
    func disconnect() {}
    func publish(_ topic: String, message: String) {}
    func publish(_ topic: String, message: [UInt8]) {}

    func subscribe(_ topic: String) {
        subscribedTopics.append(topic)
    }

    func unsubscribe(_ topic: String) {
        unsubscribedTopics.append(topic)
    }
}
