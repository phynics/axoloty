// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@testable import Axoloty
import Foundation
import Testing

/// Tests that transport-level state and raw MQTT messages are mirrored into
/// the Swift concurrency ``EventHub`` while the legacy Rx subjects remain
/// source-compatible.
@MainActor
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

    /// Discover→Resolve is a request/response flow: `publishDiscover` mints a
    /// correlation id (logged at mint) and only matches a response snapshot
    /// carrying that exact id (logged again at the match, see
    /// `CommunicationManager.log` sites in `CM+Publish.swift`). This proves
    /// the same id that gets logged on the request hop is the one the
    /// response hop matches on -- the mechanism the correlation-id logging
    /// added in #140 relies on. `LogManager`'s handler always writes to
    /// stderr (see its doc comment), so this checks the underlying id
    /// propagation rather than capturing the literal log line.
    @Test
    func discoverPublishAndResolveMatchShareOneCorrelationId() async throws {
        let client = FakeCommunicationClient(delegate: FakeStartable())
        let manager = makeManager(client: client)
        await client.simulateState(.online)

        let stream = await manager.publishDiscover(DiscoverEvent.with(objectTypes: [Log.objectType]))
        var iterator = await stream.makeAsyncIteratorAndWait()

        // `.online` also triggers identity/IoNode advertisements, so filter
        // for the Discover topic rather than assuming publish order.
        try await waitUntil("Discover topic to be published") {
            try client.publishedTopics.contains { try CommunicationTopic($0).eventType == .Discover }
        }
        let publishedTopic = try #require(
            try client.publishedTopics.first { try CommunicationTopic($0).eventType == .Discover }
        )
        let parsedTopic = try CommunicationTopic(publishedTopic)
        let mintedCorrelationId = try #require(parsedTopic.correlationId)

        let resolveSnapshot = ResponseEventSnapshot(
            eventType: CommunicationEventType.Resolve.rawValue,
            sourceId: "responder",
            correlationId: mintedCorrelationId,
            payload: Data("{}".utf8)
        )
        await client.emit(
            resolveSnapshot,
            to: CommunicationEventHubKeys.response(eventType: .Resolve, correlationId: mintedCorrelationId)
        )

        let received = try await nextValue(&iterator, timeout: .milliseconds(500))
        #expect(received.correlationId == mintedCorrelationId)
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
    func sensorObserverAdvertisedSensorStreamDeliversSnapshots() async throws {
        let configuration = Configuration(
            communication: CommunicationOptions(
                mqttClientOptions: MQTTClientOptions(
                    host: "127.0.0.1",
                    port: 1883,
                    shouldTryMDNSDiscovery: false,
                    autoReconnect: false
                ),
                shouldAutoStart: false
            )
        )
        let components = Components(
            controllers: ["sensor-observer": SensorObserverController.self],
            objectTypes: []
        )
        let container = Container.resolve(components: components, configuration: configuration)
        let manager = try #require(container.communicationManager)
        let observer = try #require(
            container.getController(name: "sensor-observer") as? SensorObserverController
        )
        let fakeClient = FakeCommunicationClient(delegate: manager)
        manager.client = fakeClient

        let stream = try await observer.observeAdvertisedSensorsStream()
        var iterator = await stream.makeAsyncIteratorAndWait()
        let snapshot = AdvertiseEventSnapshot(
            sourceId: "source",
            eventTypeFilter: EVENT_TYPE_FILTER_SEPARATOR + SensorThingsTypes.OBJECT_TYPE_SENSOR,
            object: CoatyObjectSnapshot(
                objectId: "sensor",
                coreType: .CoatyObject,
                objectType: SensorThingsTypes.OBJECT_TYPE_SENSOR,
                name: "sensor"
            )
        )
        await fakeClient.emit(
            snapshot,
            to: CommunicationEventHubKeys.advertise(
                eventTypeFilter: EVENT_TYPE_FILTER_SEPARATOR + SensorThingsTypes.OBJECT_TYPE_SENSOR
            )
        )

        #expect(try await nextValue(&iterator, timeout: .milliseconds(500)) == snapshot)
        container.shutdown()
    }

    @Test
    func thingObserverAdvertisedThingStreamDeliversSnapshots() async throws {
        let configuration = Configuration(
            communication: CommunicationOptions(
                mqttClientOptions: MQTTClientOptions(
                    host: "127.0.0.1",
                    port: 1883,
                    shouldTryMDNSDiscovery: false,
                    autoReconnect: false
                ),
                shouldAutoStart: false
            )
        )
        let components = Components(
            controllers: ["thing-observer": ThingObserverController.self],
            objectTypes: []
        )
        let container = Container.resolve(components: components, configuration: configuration)
        let manager = try #require(container.communicationManager)
        let observer = try #require(
            container.getController(name: "thing-observer") as? ThingObserverController
        )
        let fakeClient = FakeCommunicationClient(delegate: manager)
        manager.client = fakeClient

        let stream = try await observer.observeAdvertisedThingsStream()
        var iterator = await stream.makeAsyncIteratorAndWait()
        let snapshot = AdvertiseEventSnapshot(
            sourceId: "source",
            eventTypeFilter: EVENT_TYPE_FILTER_SEPARATOR + SensorThingsTypes.OBJECT_TYPE_THING,
            object: CoatyObjectSnapshot(
                objectId: "thing",
                coreType: .CoatyObject,
                objectType: SensorThingsTypes.OBJECT_TYPE_THING,
                name: "thing"
            )
        )
        await fakeClient.emit(
            snapshot,
            to: CommunicationEventHubKeys.advertise(
                eventTypeFilter: EVENT_TYPE_FILTER_SEPARATOR + SensorThingsTypes.OBJECT_TYPE_THING
            )
        )

        #expect(try await nextValue(&iterator, timeout: .milliseconds(500)) == snapshot)
        container.shutdown()
    }

    @Test
    func sensorObserverChanneledObservationStreamFiltersBySensor() async throws {
        let configuration = Configuration(
            communication: CommunicationOptions(
                mqttClientOptions: MQTTClientOptions(
                    host: "127.0.0.1",
                    port: 1883,
                    shouldTryMDNSDiscovery: false,
                    autoReconnect: false
                ),
                shouldAutoStart: false
            )
        )
        let components = Components(
            controllers: ["sensor-observer": SensorObserverController.self],
            objectTypes: []
        )
        let container = Container.resolve(components: components, configuration: configuration)
        let manager = try #require(container.communicationManager)
        let observer = try #require(
            container.getController(name: "sensor-observer") as? SensorObserverController
        )
        let fakeClient = FakeCommunicationClient(delegate: manager)
        manager.client = fakeClient

        let sensorId = CoatyUUID()
        let stream = try await observer.observeChanneledObservationsStream(
            sensorId: sensorId,
            channelId: "observations"
        )
        let next = _Concurrency.Task { () -> ChannelEventSnapshot? in
            for await snapshot in stream {
                return snapshot
            }
            return nil
        }
        await _Concurrency.Task.yield()

        let unrelated = ChannelEventSnapshot(
            sourceId: "source",
            object: CoatyObjectSnapshot(
                objectId: "unrelated",
                coreType: .CoatyObject,
                objectType: SensorThingsTypes.OBJECT_TYPE_OBSERVATION,
                name: "unrelated",
                parentObjectId: CoatyUUID().string
            ),
            channelId: "observations",
            eventTypeFilter: "observations"
        )
        let matching = ChannelEventSnapshot(
            sourceId: "source",
            object: CoatyObjectSnapshot(
                objectId: "matching",
                coreType: .CoatyObject,
                objectType: SensorThingsTypes.OBJECT_TYPE_OBSERVATION,
                name: "matching",
                parentObjectId: sensorId.string
            ),
            channelId: "observations",
            eventTypeFilter: "observations"
        )
        let key = CommunicationEventHubKeys.channel(channelId: "observations")
        await fakeClient.emit(unrelated, to: key)
        await fakeClient.emit(matching, to: key)

        #expect(await next.value == matching)
        container.shutdown()
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
    func managerReadinessWaitsForSubscriptionAcknowledgements() async {
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
    func communicationStateReplayThroughManagerEventHub() async throws {
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
    func operatingStateReplayThroughManagerEventHub() async throws {
        let manager = makeManager()
        let fakeClient = FakeCommunicationClient(delegate: manager)
        manager.client = fakeClient

        await fakeClient.eventHub.yieldState(
            value: OperatingState.started,
            to: CommunicationEventHubKeys.operatingState
        )

        let stream = await manager.observeOperatingStateStream()
        var iterator = await stream.makeAsyncIteratorAndWait()
        #expect(try await nextValue(&iterator, timeout: .milliseconds(500)) == .started)
    }

    @Test
    func multipleConsumersReceiveRawMQTTMessages() async throws {
        let manager = makeManager()
        let fakeClient = FakeCommunicationClient(delegate: manager)
        manager.client = fakeClient

        let stream: EventStream<RawMQTTMessage> = await manager.observeRawMQTTMessageStream()
        // Raw messages aren't replayed, so each iterator must confirm its
        // event hub registration is attached before we yield, rather than
        // guessing how long that takes with a fixed sleep.
        var iteratorOne = await stream.makeAsyncIteratorAndWait()
        var iteratorTwo = await stream.makeAsyncIteratorAndWait()

        await fakeClient.simulateRawMessage(topic: "external/topic", payload: [0xAB, 0xCD])

        let messageOne = try await nextValue(&iteratorOne, timeout: .milliseconds(500))
        let messageTwo = try await nextValue(&iteratorTwo, timeout: .milliseconds(500))

        #expect(messageOne == RawMQTTMessage(topic: "external/topic", payload: [0xAB, 0xCD]))
        #expect(messageTwo == messageOne)
    }

    @Test
    func mQTTNIOClientMirrorsStateChangesToEventHub() async throws {
        let delegate = FakeStartable()
        let options = MQTTClientOptions(
            host: "127.0.0.1",
            port: 1883,
            shouldTryMDNSDiscovery: false,
            autoReconnect: false
        )
        options.clientId = "test-client"
        let client = MQTTNIOClient(mqttClientOptions: options, delegate: delegate)

        // No settling delay needed: `.state` buffering both caches the latest
        // value and forwards live yields to already-registered continuations,
        // so the order between this call and the iterator registration below
        // doesn't matter — the state reaches the iterator either way.
        client.updateCommunicationState(.online)

        let stream: EventStream<CommunicationState> = await client.eventHub.registerStream(
            key: CommunicationEventHubKeys.communicationState,
            buffering: .state,
            onLast: {}
        )
        var iterator = await stream.makeAsyncIteratorAndWait()

        let state = try await nextValue(&iterator, timeout: .milliseconds(500))
        #expect(state == .online)
    }
}

// MARK: - Helpers

//
// `nextValue` is shared from Tests/Testing/AsyncWaiting.swift.

@MainActor
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
    // mqttClientOptions is always set above, so this can never throw.
    // swiftlint:disable:next force_try
    return try! CommunicationManager(
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
    for _ in 0 ..< 20 {
        if client.commands == expected {
            return
        }
        try await _Concurrency.Task.sleep(for: .milliseconds(25))
    }
    #expect(client.commands == expected)
}

// MARK: - Test seam

private final class FakeStartable: CommunicationClientDelegate {
    func didReceiveStart() {}
}

private final class FakeCommunicationClient: CommunicationClient, @unchecked Sendable {
    let eventHub = EventHub()
    var delegate: CommunicationClientDelegate
    private(set) var commands: [SubscriptionCommand] = []
    private(set) var publishedTopics: [String] = []
    private let subscriptionGate: SubscriptionAckGate?

    init(delegate: CommunicationClientDelegate, subscriptionGate: SubscriptionAckGate? = nil) {
        self.delegate = delegate
        self.subscriptionGate = subscriptionGate
    }

    func simulateState(_ state: CommunicationState) async {
        delegate.didUpdateCommunicationState(state)
        await eventHub.yieldState(
            value: state,
            to: CommunicationEventHubKeys.communicationState
        )
    }

    func simulateRawMessage(topic: String, payload: [UInt8]) async {
        await eventHub.yield(
            value: RawMQTTMessage(topic: topic, payload: payload),
            to: CommunicationEventHubKeys.rawMQTTMessage
        )
    }

    func emit<T: Sendable>(_ snapshot: T, to key: CommunicationEventHubKey) async {
        await eventHub.yield(value: snapshot, to: key)
    }

    func connect(lastWillTopic _: String, lastWillMessage _: String) {}
    func disconnect() {}
    func publish(_ topic: String, message _: String) { publishedTopics.append(topic) }
    func publish(_ topic: String, message _: [UInt8]) { publishedTopics.append(topic) }
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
