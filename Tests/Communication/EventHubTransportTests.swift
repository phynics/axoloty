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
    func advertiseStreamAcquiresTopicAndDeliversSnapshot() async throws {
        let client = FakeCommunicationClient(delegate: FakeStartable())
        let manager = makeManager(client: client)
        let stream = await manager.observeAdvertiseStream(withCoreType: .Log)
        var iterator = stream.makeAsyncIterator()
        let topic = CommunicationTopic.createTopicStringByLevelsForSubscribe(
            eventType: .Advertise,
            eventTypeFilter: CoreType.Log.rawValue,
            namespace: manager.namespace
        )

        await client.simulateState(.online)
        try await waitForCommands(on: client, expecting: [.subscribe(topic)])

        let snapshot = AdvertiseEventSnapshot(
            sourceId: "source",
            eventTypeFilter: CoreType.Log.rawValue,
            object: CoatyObjectSnapshot(
                objectId: "object",
                coreType: .Log,
                objectType: Log.objectType,
                name: "log"
            )
        )
        await client.emit(snapshot, to: CommunicationEventHubKeys.advertise(
            eventTypeFilter: CoreType.Log.rawValue
        ))

        #expect(try await nextValue(&iterator, timeout: .milliseconds(500)) == snapshot)
    }

    @Test
    func advertiseObjectStreamRejectsInvalidObjectType() async {
        let client = FakeCommunicationClient(delegate: FakeStartable())
        let manager = makeManager(client: client)

        do {
            _ = try await manager.observeAdvertiseStream(withObjectType: "invalid/type")
            Issue.record("Expected invalid object type to be rejected")
        } catch {
            // Expected validation error.
        }
    }

    @Test
    func deadvertiseStreamAcquiresTopicAndDeliversSnapshot() async throws {
        let client = FakeCommunicationClient(delegate: FakeStartable())
        let manager = makeManager(client: client)
        let stream = await manager.observeDeadvertiseStream()
        var iterator = await stream.makeAsyncIteratorAndWait()
        let topic = CommunicationTopic.createTopicStringByLevelsForSubscribe(
            eventType: .Deadvertise,
            namespace: manager.namespace
        )

        await client.simulateState(.online)
        try await waitForCommands(on: client, expecting: [.subscribe(topic)])

        let snapshot = DeadvertiseEventSnapshot(
            sourceId: "source",
            objectIds: ["object"]
        )
        await client.emit(snapshot, to: CommunicationEventHubKeys.deadvertise)

        #expect(try await nextValue(&iterator, timeout: .milliseconds(500)) == snapshot)
    }

    @Test
    func discoverStreamAcquiresTopicAndDeliversSnapshot() async throws {
        let client = FakeCommunicationClient(delegate: FakeStartable())
        let manager = makeManager(client: client)
        let stream = await manager.observeDiscoverStream()
        var iterator = await stream.makeAsyncIteratorAndWait()
        let topic = CommunicationTopic.createTopicStringByLevelsForSubscribe(
            eventType: .Discover,
            namespace: manager.namespace
        )

        await client.simulateState(.online)
        try await waitForCommands(on: client, expecting: [.subscribe(topic)])

        let snapshot = DiscoverEventSnapshot(
            sourceId: "source",
            objectTypes: [Log.objectType]
        )
        await client.emit(snapshot, to: CommunicationEventHubKeys.discover)

        #expect(try await nextValue(&iterator, timeout: .milliseconds(500)) == snapshot)
    }

    @Test
    func updateStreamAcquiresTopicAndDeliversSnapshot() async throws {
        let client = FakeCommunicationClient(delegate: FakeStartable())
        let manager = makeManager(client: client)
        let stream = await manager.observeUpdateStream(withCoreType: .Log)
        var iterator = await stream.makeAsyncIteratorAndWait()
        let topic = CommunicationTopic.createTopicStringByLevelsForSubscribe(
            eventType: .Update,
            eventTypeFilter: CoreType.Log.rawValue,
            namespace: manager.namespace
        )

        await client.simulateState(.online)
        try await waitForCommands(on: client, expecting: [.subscribe(topic)])

        let snapshot = UpdateEventSnapshot(
            sourceId: "source",
            eventTypeFilter: CoreType.Log.rawValue,
            object: CoatyObjectSnapshot(
                objectId: "object",
                coreType: .Log,
                objectType: Log.objectType,
                name: "changed"
            )
        )
        await client.emit(snapshot, to: CommunicationEventHubKeys.update(eventTypeFilter: CoreType.Log.rawValue))

        #expect(try await nextValue(&iterator, timeout: .milliseconds(500)) == snapshot)
    }

    @Test
    func channelStreamAcquiresTopicAndDeliversSnapshot() async throws {
        let client = FakeCommunicationClient(delegate: FakeStartable())
        let manager = makeManager(client: client)
        let stream = try await manager.observeChannelStream(channelId: "test-channel")
        var iterator = await stream.makeAsyncIteratorAndWait()
        let topic = CommunicationTopic.createTopicStringByLevelsForSubscribe(
            eventType: .Channel,
            eventTypeFilter: "test-channel",
            namespace: manager.namespace
        )

        await client.simulateState(.online)
        try await waitForCommands(on: client, expecting: [.subscribe(topic)])

        let snapshot = ChannelEventSnapshot(
            sourceId: "source",
            object: CoatyObjectSnapshot(
                objectId: "object",
                coreType: .Log,
                objectType: Log.objectType,
                name: "broadcast"
            ),
            channelId: "test-channel",
            eventTypeFilter: "test-channel"
        )
        await client.emit(snapshot, to: CommunicationEventHubKeys.channel(channelId: "test-channel"))

        #expect(try await nextValue(&iterator, timeout: .milliseconds(500)) == snapshot)
    }

    @Test
    func ioValueStreamDeliversRawSnapshot() async throws {
        let client = FakeCommunicationClient(delegate: FakeStartable())
        let manager = makeManager(client: client)
        let stream = await manager.observeIoValueStream()
        var iterator = await stream.makeAsyncIteratorAndWait()
        let snapshot = IoValueEventSnapshot(topic: "coaty/1/ns/source/IOV", payload: [1, 2, 3])
        await client.emit(snapshot, to: CommunicationEventHubKeys.ioValue)
        #expect(try await nextValue(&iterator, timeout: .milliseconds(500)) == snapshot)
    }

    @Test
    func ioStateStreamReplaysInitialState() async throws {
        let client = FakeCommunicationClient(delegate: FakeStartable())
        let manager = makeManager(client: client)
        let source = IoSource(valueType: "Temperature")
        let stream = await manager.observeIoStateStream(ioPoint: source)
        var iterator = await stream.makeAsyncIteratorAndWait()
        let state = try await nextValue(&iterator, timeout: .milliseconds(500))
        #expect(state.ioPointId == source.objectId.string)
        #expect(state.hasAssociations == false)
    }

    @Test
    func managerReplaysDesiredTopicsOnceAfterOnline() async throws {
        let client = FakeCommunicationClient(delegate: FakeStartable())
        let manager = makeManager(client: client)

        await manager.acquireSubscription(topic: "coaty/test/#")
        #expect(client.commands == [])

        await client.simulateState(.online)
        try await waitForCommands(
            on: client,
            expecting: [.subscribe("coaty/test/#")]
        )
    }

    @Test
    func managerReadinessWaitsForSubscriptionAcknowledgements() async throws {
        let gate = SubscriptionAckGate()
        let client = FakeCommunicationClient(delegate: FakeStartable(), subscriptionGate: gate)
        let manager = makeManager(client: client)
        await manager.acquireSubscription(topic: "coaty/test/#")

        let ready = CompletionFlag()
        let startup = _Concurrency.Task {
            try? await manager.startAndWaitUntilReady()
            await ready.mark()
        }

        await client.simulateState(.online)
        await gate.waitUntilStarted()
        await _Concurrency.Task.yield()
        #expect(await ready.value == false)

        await gate.open()
        await startup.value
        #expect(await ready.value)
    }

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

private func makeManager(client: CommunicationClient? = nil) -> CommunicationManager {
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
        commonOptions: nil,
        client: client
    )
}

private func waitForCommands(
    on client: FakeCommunicationClient,
    expecting expected: [SubscriptionCommand]
) async throws {
    for _ in 0..<20 {
        if client.commands == expected {
            return
        }
        try await _Concurrency.Task.sleep(for: .milliseconds(25))
    }
    #expect(client.commands == expected)
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
    private(set) var commands: [SubscriptionCommand] = []
    private let subscriptionGate: SubscriptionAckGate?

    init(delegate: Startable, subscriptionGate: SubscriptionAckGate? = nil) {
        self.delegate = delegate
        self.subscriptionGate = subscriptionGate
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

    func emit<T: Sendable>(_ snapshot: T, to key: CommunicationEventHubKey) async {
        await eventHub.yield(value: snapshot, to: key)
    }

    func connect(lastWillTopic: String, lastWillMessage: String) {}
    func disconnect() {}
    func publish(_ topic: String, message: String) {}
    func publish(_ topic: String, message: [UInt8]) {}
    func subscribe(_ topic: String) async throws {
        commands.append(.subscribe(topic))
        if let subscriptionGate {
            await subscriptionGate.markStarted()
            await subscriptionGate.waitUntilOpen()
        }
    }

    func unsubscribe(_ topic: String) async throws {
        commands.append(.unsubscribe(topic))
    }
}

private actor SubscriptionAckGate {
    private var started = false
    private var released = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func markStarted() {
        started = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
    }

    func waitUntilStarted() async {
        if started {
            return
        }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func waitUntilOpen() async {
        if released {
            return
        }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func open() {
        released = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}

private actor CompletionFlag {
    private(set) var value = false

    func mark() {
        value = true
    }
}
