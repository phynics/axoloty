// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@testable import Axoloty
import Foundation
import Testing
import AxolotyWire

/// Tests that transport-level state and raw MQTT messages are mirrored into
/// the Swift concurrency ``Broadcast`` while the legacy Rx subjects remain
/// source-compatible.
@MainActor
struct BroadcastTransportTests {
    @Test
    func advertiseStreamAcquiresTopicAndDeliversSnapshot() async throws {
        let client = FakeCommunicationClient(delegate: FakeStartable())
        let manager = makeManager(client: client)
        let stream = await manager.observeAdvertiseStream(withCoreType: .Log)
        var iterator = stream.makeAsyncIterator()
        let topic = TopicBuilder.subscribeTopic(
            eventType: .advertise,
            eventTypeFilter: CoreType.Log.rawValue,
            namespace: manager.namespace
        )

        try await bringOnline(manager, client: client)
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
        await client.emitAdvertise(snapshot, filter: CoreType.Log.rawValue)

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

    /// Validates the symmetric release half of the coordinator-owned
    /// subscription lifecycle (#172): dropping the last subscriber of an
    /// Advertise stream must fire `Broadcast`'s `onLast`, which calls
    /// `coordinator.release(topic:)`, which emits `.unsubscribe`.
    ///
    /// The acquire half (`onFirst` → `coordinator.acquire` → `.subscribe`) is
    /// covered by `advertiseStreamAcquiresTopicAndDeliversSnapshot`. This test
    /// restores the release-path coverage deleted in `010df9c` and proves the
    /// coordinator teardown path works without the `@unchecked Sendable`
    /// `AdvertiseStreamLifecycleBridge` that was removed.
    @Test
    func advertiseStreamReleasesTopicWhenLastSubscriberDrops() async throws {
        let client = FakeCommunicationClient(delegate: FakeStartable())
        let manager = makeManager(client: client)
        let topic = TopicBuilder.subscribeTopic(
            eventType: .advertise,
            eventTypeFilter: CoreType.Log.rawValue,
            namespace: manager.namespace
        )

        let stream = await manager.observeAdvertiseStream(withCoreType: .Log)
        let iterator = stream.makeAsyncIterator()
        try await bringOnline(manager, client: client)
        try await waitForCommands(on: client, expecting: [.subscribe(topic)])

        // Cancelling the consuming task terminates its iterator, which fires
        // `Broadcast`'s `onTermination`. That spawns an unstructured `Task`
        // running `removeSubscriber` → `onLast` → `coordinator.release` →
        // `client.unsubscribe`, so the command arrives asynchronously and must
        // be polled for rather than asserted synchronously.
        let holder = AsyncStreamBox(iterator)
        let consumer = Task {
            while await holder.iterator.next() != nil {}
        }
        consumer.cancel()
        _ = await consumer.value

        try await waitUntil("advertise topic to be released after last subscriber drops") {
            client.commands.contains { cmd in
                if case .unsubscribe(let released) = cmd { return released == topic }
                return false
            }
        }
    }

    /// Restores `testStreamUnsubscribeAndReuse` from the suite deleted in
    /// `010df9c`: after the release cycle resets the coordinator's refcount to
    /// zero, re-subscribing must re-acquire the topic and deliver fresh
    /// snapshots. This proves acquire/release can cycle multiple times over the
    /// `Broadcast`'s lifetime (started resets to false on `onLast`, so
    /// `onFirst` fires again on the next subscriber).
    @Test
    func advertiseStreamResubscribesAndDeliversAfterRelease() async throws {
        let client = FakeCommunicationClient(delegate: FakeStartable())
        let manager = makeManager(client: client)
        let topic = TopicBuilder.subscribeTopic(
            eventType: .advertise,
            eventTypeFilter: CoreType.Log.rawValue,
            namespace: manager.namespace
        )

        await client.simulateState(.online)

        // First cycle: acquire, then release by cancelling the consumer.
        let firstStream = await manager.observeAdvertiseStream(withCoreType: .Log)
        let firstHolder = AsyncStreamBox(firstStream.makeAsyncIterator())
        let firstConsumer = Task {
            while await firstHolder.iterator.next() != nil {}
        }
        try await waitForCommands(on: client, expecting: [.subscribe(topic)])
        firstConsumer.cancel()
        _ = await firstConsumer.value
        try await waitUntil("first cycle to release the advertise topic") {
            client.commands.contains { cmd in
                if case .unsubscribe(let released) = cmd { return released == topic }
                return false
            }
        }

        // Second cycle: re-acquire, then deliver and receive a fresh snapshot.
        let secondStream = await manager.observeAdvertiseStream(withCoreType: .Log)
        var secondIterator = secondStream.makeAsyncIterator()
        try await waitUntil("advertise topic to be re-acquired") {
            client.commands.filter { cmd in
                if case .subscribe(let subscribed) = cmd { return subscribed == topic }
                return false
            }.count == 2
        }

        let snapshot = AdvertiseEventSnapshot(
            sourceId: "source",
            eventTypeFilter: CoreType.Log.rawValue,
            object: CoatyObjectSnapshot(
                objectId: "object",
                coreType: .Log,
                objectType: Log.objectType,
                name: "log-again"
            )
        )
        await client.emitAdvertise(snapshot, filter: CoreType.Log.rawValue)
        #expect(try await nextValue(&secondIterator, timeout: .milliseconds(500)) == snapshot)
    }

    @Test
    func deadvertiseStreamAcquiresTopicAndDeliversSnapshot() async throws {
        let client = FakeCommunicationClient(delegate: FakeStartable())
        let manager = makeManager(client: client)
        let stream = await manager.observeDeadvertiseStream()
        var iterator = stream.makeAsyncIterator()
        let topic = TopicBuilder.subscribeTopic(
            eventType: .deadvertise,
            namespace: manager.namespace
        )

        await client.simulateState(.online)
        try await waitForCommands(on: client, expecting: [.subscribe(topic)])

        let snapshot = DeadvertiseEventSnapshot(
            sourceId: "source",
            objectIds: ["object"]
        )
        await client.emitDeadvertise(snapshot)

        #expect(try await nextValue(&iterator, timeout: .milliseconds(500)) == snapshot)
    }

    @Test
    func discoverStreamAcquiresTopicAndDeliversSnapshot() async throws {
        let client = FakeCommunicationClient(delegate: FakeStartable())
        let manager = makeManager(client: client)
        let stream = await manager.observeDiscoverStream()
        var iterator = stream.makeAsyncIterator()
        let topic = TopicBuilder.subscribeTopic(
            eventType: .discover,
            namespace: manager.namespace
        )

        await client.simulateState(.online)
        try await waitForCommands(on: client, expecting: [.subscribe(topic)])

        let snapshot = DiscoverEventSnapshot(
            sourceId: "source",
            objectTypes: [Log.objectType]
        )
        await client.emitDiscover(snapshot)

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
        var iterator = stream.makeAsyncIterator()

        // `.online` also triggers identity/IoNode advertisements, so filter
        // for the Discover topic rather than assuming publish order.
        try await waitUntil("Discover topic to be published") {
            client.publishedTopics.contains { topicEventType($0) == .discover }
        }
        let publishedTopic = try #require(
            client.publishedTopics.first { topicEventType($0) == .discover }
        )
        let mintedCorrelationId = try #require(topicCorrelationId(publishedTopic))

        let resolveSnapshot = ResponseEventSnapshot(
            eventType: WireEventType.resolve.rawValue,
            sourceId: "responder",
            correlationId: mintedCorrelationId,
            payload: "{}"
        )
        await client.emitResponse(resolveSnapshot, eventType: .resolve, correlationId: mintedCorrelationId)

        let received = try await nextValue(&iterator, timeout: .milliseconds(500))
        #expect(received.correlationId == mintedCorrelationId)
    }

    /// Verifies the acquire-before-publish ordering for the response path:
    /// `onFirst` (which calls `coordinator.acquire` → `client.subscribe`)
    /// is awaited inside `Broadcast.subscribe()` before
    /// `publishWithResponse` sends the request. So the response topic's
    /// SUBSCRIBE command must be issued. The stream must be kept alive
    /// to prevent `onLast` from firing and unsubscribing before we check.
    @Test
    func responseStreamAcquiresTopicBeforePublish() async throws {
        let client = FakeCommunicationClient(delegate: FakeStartable())
        let manager = makeManager(client: client)
        await client.simulateState(.online)

        // Store the stream to prevent onLast from firing during the test.
        let stream = await manager.publishDiscover(DiscoverEvent.with(objectTypes: [Log.objectType]))

        // Wait for the Discover publish to appear — this implies
        // setOnline has completed and desired topics have been activated.
        try await waitUntil("Discover topic to be published") {
            client.publishedTopics.contains { topicEventType($0) == .discover }
        }

        // The response topic (Resolve with correlation ID) should have been
        // subscribed via onFirst — which is awaited inside subscribe()
        // before publishWithResponse publishes the request.
        let responseSubscribed = client.commands.contains { cmd in
            if case .subscribe(let topic) = cmd {
                return topic.contains("/RSV/")
            }
            return false
        }
        #expect(responseSubscribed, "Response topic should be subscribed before request is published")

        // Keep the stream alive so onLast doesn't fire and unsubscribe.
        _ = stream
    }

    @Test
    func queryStreamAcquiresTopicAndDeliversSnapshot() async throws {
        let client = FakeCommunicationClient(delegate: FakeStartable())
        let manager = makeManager(client: client)
        let stream = await manager.observeQueryStream()
        var iterator = stream.makeAsyncIterator()
        let topic = TopicBuilder.subscribeTopic(
            eventType: .query,
            namespace: manager.namespace
        )

        await client.simulateState(.online)
        try await waitForCommands(on: client, expecting: [.subscribe(topic)])

        let snapshot = QueryEventSnapshot(
            sourceId: "source",
            correlationId: "corr-1",
            objectTypes: [Log.objectType]
        )
        await client.emitQuery(snapshot)

        #expect(try await nextValue(&iterator, timeout: .milliseconds(500)) == snapshot)
    }

    @Test
    func callStreamAcquiresTopicAndDeliversSnapshot() async throws {
        let client = FakeCommunicationClient(delegate: FakeStartable())
        let manager = makeManager(client: client)
        let stream = try await manager.observeCallStream(operation: "doThing")
        var iterator = stream.makeAsyncIterator()
        let topic = TopicBuilder.subscribeTopic(
            eventType: .call,
            eventTypeFilter: "doThing",
            namespace: manager.namespace
        )

        await client.simulateState(.online)
        try await waitForCommands(on: client, expecting: [.subscribe(topic)])

        let snapshot = CallEventSnapshot(
            sourceId: "source",
            correlationId: "corr-1",
            operation: "doThing"
        )
        await client.emitCall(snapshot, operation: "doThing")

        #expect(try await nextValue(&iterator, timeout: .milliseconds(500)) == snapshot)
    }

    @Test
    func callStreamRejectsInvalidOperation() async {
        let client = FakeCommunicationClient(delegate: FakeStartable())
        let manager = makeManager(client: client)

        do {
            _ = try await manager.observeCallStream(operation: "invalid/operation")
            Issue.record("Expected invalid operation to be rejected")
        } catch {
            // Expected validation error.
        }
    }

    @Test
    func updateStreamAcquiresTopicAndDeliversSnapshot() async throws {
        let client = FakeCommunicationClient(delegate: FakeStartable())
        let manager = makeManager(client: client)
        let stream = await manager.observeUpdateStream(withCoreType: .Log)
        var iterator = stream.makeAsyncIterator()
        let topic = TopicBuilder.subscribeTopic(
            eventType: .update,
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
        await client.emitUpdate(snapshot, filter: CoreType.Log.rawValue)

        #expect(try await nextValue(&iterator, timeout: .milliseconds(500)) == snapshot)
    }

    @Test
    func channelStreamAcquiresTopicAndDeliversSnapshot() async throws {
        let client = FakeCommunicationClient(delegate: FakeStartable())
        let manager = makeManager(client: client)
        let stream = try await manager.observeChannelStream(channelId: "test-channel")
        var iterator = stream.makeAsyncIterator()
        let topic = TopicBuilder.subscribeTopic(
            eventType: .channel,
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
        await client.emitChannel(snapshot, channelId: "test-channel")

        #expect(try await nextValue(&iterator, timeout: .milliseconds(500)) == snapshot)
    }

    @Test
    func ioValueStreamDeliversRawSnapshot() async throws {
        let client = FakeCommunicationClient(delegate: FakeStartable())
        let manager = makeManager(client: client)
        let stream = await manager.observeIoValueStream()
        var iterator = stream.makeAsyncIterator()
        let snapshot = IoValueEventSnapshot(topic: "coaty/1/ns/source/IOV", payload: [1, 2, 3])
        await client.emitIoValue(snapshot)
        #expect(try await nextValue(&iterator, timeout: .milliseconds(500)) == snapshot)
    }

    @Test
    func ioStateStreamReplaysInitialState() async throws {
        let client = FakeCommunicationClient(delegate: FakeStartable())
        let manager = makeManager(client: client)
        let source = IoSource(valueType: "Temperature")
        let stream = await manager.observeIoStateStream(ioPoint: source)
        var iterator = stream.makeAsyncIterator()
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
        let container = try Container.resolve(components: components, configuration: configuration)
        let manager = try #require(container.communicationManager)
        let observer = try #require(
            container.getController(name: "sensor-observer") as? SensorObserverController
        )
        let fakeClient = FakeCommunicationClient(delegate: manager)
        manager.client = fakeClient
        fakeClient.setStreams(manager.streams)

        let stream = try await observer.observeAdvertisedSensorsStream()
        var iterator = stream.makeAsyncIterator()
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
        await fakeClient.emitAdvertise(
            snapshot,
            filter: EVENT_TYPE_FILTER_SEPARATOR + SensorThingsTypes.OBJECT_TYPE_SENSOR
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
        let container = try Container.resolve(components: components, configuration: configuration)
        let manager = try #require(container.communicationManager)
        let observer = try #require(
            container.getController(name: "thing-observer") as? ThingObserverController
        )
        let fakeClient = FakeCommunicationClient(delegate: manager)
        manager.client = fakeClient
        fakeClient.setStreams(manager.streams)

        let stream = try await observer.observeAdvertisedThingsStream()
        var iterator = stream.makeAsyncIterator()
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
        await fakeClient.emitAdvertise(
            snapshot,
            filter: EVENT_TYPE_FILTER_SEPARATOR + SensorThingsTypes.OBJECT_TYPE_THING
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
        let container = try Container.resolve(components: components, configuration: configuration)
        let manager = try #require(container.communicationManager)
        let observer = try #require(
            container.getController(name: "sensor-observer") as? SensorObserverController
        )
        let fakeClient = FakeCommunicationClient(delegate: manager)
        manager.client = fakeClient
        fakeClient.setStreams(manager.streams)

        let sensorId = CoatyUUID()
        let stream = try await observer.observeChanneledObservationsStream(
            sensorId: sensorId,
            channelId: "observations"
        )
        let next = Task { () -> ChannelEventSnapshot? in
            for await snapshot in stream {
                return snapshot
            }
            return nil
        }
        await Task.yield()

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
        await fakeClient.emitChannel(unrelated, channelId: "observations")
        await fakeClient.emitChannel(matching, channelId: "observations")

        #expect(await next.value == matching)
        container.shutdown()
    }

    @Test
    func managerReplaysDesiredTopicsOnceAfterOnline() async throws {
        let client = FakeCommunicationClient(delegate: FakeStartable())
        let manager = makeManager(client: client)

        await manager.subscriptionCoordinator.acquire(topic: "coaty/test/#")
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
        await manager.subscriptionCoordinator.acquire(topic: "coaty/test/#")

        let ready = CompletionFlag()
        let startup = Task {
            try? await manager.startAndWaitUntilReady()
            await ready.mark()
        }

        await client.simulateState(.online)
        await gate.waitUntilStarted()
        await Task.yield()
        #expect(await ready.value == false)

        await gate.open()
        await startup.value
        #expect(await ready.value)
    }

    @Test
    func communicationStateReplayThroughBroadcast() async throws {
        let manager = makeManager()
        let fakeClient = FakeCommunicationClient(delegate: manager)
        manager.client = fakeClient
        fakeClient.setStreams(manager.streams)

        await fakeClient.simulateState(.online)

        let stream: AsyncStream<CommunicationState> = await manager.observeCommunicationStateStream()
        var iterator = stream.makeAsyncIterator()

        let state = try await nextValue(&iterator, timeout: .milliseconds(500))
        #expect(state == .online)
    }

    @Test
    func communicationStateStreamSeedsInitialStateBeforeTransitions() async throws {
        let manager = makeManager()
        let fakeClient = FakeCommunicationClient(delegate: manager)
        manager.client = fakeClient
        fakeClient.setStreams(manager.streams)

        let stream = await manager.observeCommunicationStateStream()
        var iterator = stream.makeAsyncIterator()

        #expect(try await nextValue(&iterator, timeout: .milliseconds(500)) == .offline)

        await fakeClient.simulateState(.online)
        #expect(try await nextValue(&iterator, timeout: .milliseconds(500)) == .online)
    }

    @Test
    func operatingStateReplayThroughBroadcast() async throws {
        let manager = makeManager()
        let fakeClient = FakeCommunicationClient(delegate: manager)
        manager.client = fakeClient
        fakeClient.setStreams(manager.streams)

        await fakeClient.emitOperatingState(.started)

        let stream = await manager.observeOperatingStateStream()
        var iterator = stream.makeAsyncIterator()
        #expect(try await nextValue(&iterator, timeout: .milliseconds(500)) == .started)
    }

    @Test
    func operatingStateStreamSeedsInitialStateBeforeTransitions() async throws {
        let manager = makeManager()
        let fakeClient = FakeCommunicationClient(delegate: manager)
        manager.client = fakeClient
        fakeClient.setStreams(manager.streams)

        let stream = await manager.observeOperatingStateStream()
        var iterator = stream.makeAsyncIterator()

        #expect(try await nextValue(&iterator, timeout: .milliseconds(500)) == .stopped)

        await fakeClient.emitOperatingState(.started)
        #expect(try await nextValue(&iterator, timeout: .milliseconds(500)) == .started)
    }

    @Test
    func multipleConsumersReceiveRawMQTTMessages() async throws {
        let manager = makeManager()
        let fakeClient = FakeCommunicationClient(delegate: manager)
        manager.client = fakeClient
        fakeClient.setStreams(manager.streams)

        let stream1: AsyncStream<RawMQTTMessage> = await manager.observeRawMQTTMessageStream()
        let stream2: AsyncStream<RawMQTTMessage> = await manager.observeRawMQTTMessageStream()
        var iteratorOne = stream1.makeAsyncIterator()
        var iteratorTwo = stream2.makeAsyncIterator()

        await fakeClient.simulateRawMessage(topic: "external/topic", payload: [0xAB, 0xCD])

        let messageOne = try await nextValue(&iteratorOne, timeout: .milliseconds(500))
        let messageTwo = try await nextValue(&iteratorTwo, timeout: .milliseconds(500))

        #expect(messageOne == RawMQTTMessage(topic: "external/topic", payload: [0xAB, 0xCD]))
        #expect(messageTwo == messageOne)
    }

    @Test
    func rawMQTTMessageDelegateDoesNotDuplicateDeliver() async throws {
        // The transport's delivery queue path is the sole source of raw
        // messages on the broadcast stream. The delegate callback must not
        // re-send — before #238 it delivered each message twice.
        let manager = makeManager()
        let fakeClient = FakeCommunicationClient(delegate: manager)
        manager.client = fakeClient
        fakeClient.setStreams(manager.streams)

        let stream: AsyncStream<RawMQTTMessage> = await manager.observeRawMQTTMessageStream()
        var iterator = stream.makeAsyncIterator()

        manager.didReceiveRawMQTTMessage(topic: "external/topic", payload: [0xAB, 0xCD])

        do {
            _ = try await nextValue(&iterator, timeout: .milliseconds(300))
            Issue.record("delegate re-sent a raw message (expected no delivery)")
        } catch {
            // expected: the delegate must not deliver
        }
    }

    @Test
    func ioValueDelegateDoesNotDuplicateDeliver() async throws {
        // The transport's delivery queue path is the sole source of
        // IoValue snapshots. The delegate callback must not re-send — before
        // #238 it delivered each value twice.
        let manager = makeManager()
        let fakeClient = FakeCommunicationClient(delegate: manager)
        manager.client = fakeClient
        fakeClient.setStreams(manager.streams)

        let stream = await manager.observeIoValueStream()
        var iterator = stream.makeAsyncIterator()

        manager.didReceiveIoValue(topic: "coaty/1/ns/source/IOV", payload: [1, 2, 3])

        do {
            _ = try await nextValue(&iterator, timeout: .milliseconds(300))
            Issue.record("delegate re-sent an IoValue (expected no delivery)")
        } catch {
            // expected: the delegate must not deliver
        }
    }

    @Test
    func mQTTNIOClientMirrorsStateChangesToBroadcast() async throws {
        let delegate = FakeStartable()
        let options = MQTTClientOptions(
            host: "127.0.0.1",
            port: 1883,
            shouldTryMDNSDiscovery: false,
            autoReconnect: false
        )
        options.clientId = "test-client"
        let client = try MQTTNIOClient(mqttClientOptions: options, delegate: delegate)
        client.streams = makeTestStreams()

        // No settling delay needed: `.state` buffering both caches the latest
        // value and forwards live yields to already-registered continuations,
        // so the order between this call and the iterator registration below
        // doesn't matter — the state reaches the iterator either way.
        client.updateCommunicationState(.online)

        let streams = try #require(client.streams)
        let stream: AsyncStream<CommunicationState> = await streams.communicationState.subscribe()
        var iterator = stream.makeAsyncIterator()

        let state = try await nextValue(&iterator, timeout: .milliseconds(500))
        #expect(state == .online)
    }

    @Test
    func unaryCallReturnsFirstResponseAndReleasesObservation() async throws {
        let client = FakeCommunicationClient(delegate: FakeStartable())
        let manager = makeManager(client: client)
        await client.simulateState(.online)
        let call = Task {
            try await manager.call(operation: "calculate", parameters: #"{"value":41}"#, timeout: .seconds(1))
        }
        let correlationId = try await waitForPublishedCorrelation(on: client)

        await client.emitResponse(
            try unaryResponse(ReturnEvent.with(result: "42", executionInfo: #"{"provider":"primary"}"#), correlationId: correlationId),
            eventType: .returnEvent,
            correlationId: correlationId
        )
        let result = try await call.value

        #expect(result == UnaryCallResult(result: "42", executionInfo: #"{"provider":"primary"}"#, sourceId: "provider"))
        try await waitForCommandCount(on: client, count: 2)
        #expect(client.commands.last == .unsubscribe(responseTopic(correlationId)))

        // Genuine duplicate and late publishes have no owner after success.
        await client.emitResponse(
            try unaryResponse(ReturnEvent.with(result: "99", executionInfo: nil), correlationId: correlationId),
            eventType: .returnEvent,
            correlationId: correlationId
        )
        #expect(client.commands.count == 2)
    }

    @Test
    func unaryCallMapsRemoteErrorAndMalformedReturn() async throws {
        let client = FakeCommunicationClient(delegate: FakeStartable())
        let manager = makeManager(client: client)
        await client.simulateState(.online)
        let remoteCall = Task {
            try await manager.call(operation: "fail", timeout: .seconds(1))
        }
        let remoteCorrelation = try await waitForPublishedCorrelation(on: client)
        await client.emitResponse(
            try unaryResponse(
                ReturnEvent.with(error: ReturnError(code: -32602, message: "Invalid params"), executionInfo: nil),
                correlationId: remoteCorrelation
            ),
            eventType: .returnEvent,
            correlationId: remoteCorrelation
        )
        do {
            _ = try await remoteCall.value
            Issue.record("Expected the remote error to fail the unary call")
        } catch let error as RemoteCallFailure {
            #expect(error == RemoteCallFailure(code: -32602, message: "Invalid params"))
            #expect(error.userFriendlyMessage == "Remote call failed (-32602): Invalid params")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        let malformedCall = Task {
            try await manager.call(operation: "malformed", timeout: .seconds(1))
        }
        let malformedCorrelation = try await waitForPublishedCorrelation(on: client, publicationCount: 2)
        await client.emitResponse(
            ResponseEventSnapshot(
                eventType: "RTN", sourceId: "provider", correlationId: malformedCorrelation,
                payload: #"{"result":1,"error":{"code":7,"message":"both"}}"#
            ),
            eventType: .returnEvent,
            correlationId: malformedCorrelation
        )
        do {
            _ = try await malformedCall.value
            Issue.record("Expected the malformed Return to fail the unary call")
        } catch let AxolotyError.decodingFailure(type, reason, payload) {
            #expect(type == "ReturnEvent")
            #expect(reason == "The correlated Return must contain exactly one of result or error")
            #expect(payload != nil)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func unaryCallTimesOutAndCallerCancellationIsStructured() async throws {
        let timeoutClient = FakeCommunicationClient(delegate: FakeStartable())
        let timeoutManager = makeManager(client: timeoutClient)
        try await bringOnline(timeoutManager, client: timeoutClient)
        do {
            _ = try await timeoutManager.call(operation: "slow", timeout: .milliseconds(25))
            Issue.record("Expected unary call timeout")
        } catch let AxolotyError.runtime(code, message) {
            #expect(code == .timedOut)
            #expect(message == "The unary call timed out")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        let cancelClient = FakeCommunicationClient(delegate: FakeStartable())
        let cancelManager = makeManager(client: cancelClient)
        try await bringOnline(cancelManager, client: cancelClient)
        let pending = Task {
            try await cancelManager.call(operation: "cancel", timeout: .seconds(5))
        }
        _ = try await waitForPublishedCorrelation(on: cancelClient)
        pending.cancel()
        do {
            _ = try await pending.value
            Issue.record("Expected caller cancellation")
        } catch let AxolotyError.runtime(code, message) {
            #expect(code == .cancelled)
            #expect(message == "The unary call was cancelled")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func unaryCallPublishesContextAfterResponseSubscriptionIsInstalled() async throws {
        let client = FakeCommunicationClient(delegate: FakeStartable())
        let manager = makeManager(client: client)
        try await bringOnline(manager, client: client)
        let context = ObjectFilter(condition: ObjectFilterCondition(
            property: ObjectFilterProperty("name"),
            expression: .equals("provider-b")
        ))
        let call = Task {
            try await manager.call(operation: "route", context: context, timeout: .seconds(1))
        }
        let correlationId = try await waitForPublishedCorrelation(on: client)

        let subscribeIndex = try #require(client.actions.firstIndex(of: "subscribe:\(responseTopic(correlationId))"))
        let publishIndex = try #require(client.actions.firstIndex {
            $0.contains("/CLL:route/") && $0.hasSuffix("/\(correlationId)")
        })
        #expect(subscribeIndex < publishIndex)
        let payload = try #require(client.publishedMessages.last { $0.topic.contains("/CLL:route/") }?.message)
        let decoded = try JSONDecoder().decode(CallEvent.self, from: Data(payload.utf8))
        #expect(decoded.data.filter?.condition?.property.objectFilterProperty == "name")

        await client.emitResponse(
            try unaryResponse(ReturnEvent.with(result: #""provider-b""#, executionInfo: nil), correlationId: correlationId),
            eventType: .returnEvent,
            correlationId: correlationId
        )
        #expect(try await call.value.result == #""provider-b""#)
    }

    @Test
    func callHandlerFiltersContextAndPublishesOneCorrelatedResult() async throws {
        let client = FakeCommunicationClient(delegate: FakeStartable())
        let manager = makeManager(client: client)
        try await bringOnline(manager, client: client)
        let invocations = LockedCounter()
        let registration = try await manager.registerCallHandler(
            operation: "provide",
            context: manager.identity
        ) { request in
            invocations.increment()
            return .success(result: request.parameters ?? "null", executionInfo: #"{"provider":"test"}"#)
        }
        defer { registration.cancel() }

        let matchingFilter = ObjectFilter(condition: ObjectFilterCondition(
            property: ObjectFilterProperty("name"),
            expression: .equals(FilterOperand(manager.identity.name))
        ))
        let filterData = try JSONEncoder().encode(matchingFilter)
        let filter = String(decoding: filterData, as: UTF8.self)
        let request = CallEventSnapshot(
            sourceId: "caller",
            correlationId: "correlation-1",
            operation: "provide",
            parameters: #"{"value":41}"#,
            filter: filter
        )
        await client.emitCall(request, operation: "provide")
        await client.emitCall(request, operation: "provide")

        let publication = try await waitForReturnPublication(on: client)
        #expect(publication.topic.hasSuffix("/correlation-1"))
        let event = try JSONDecoder().decode(ReturnEvent.self, from: Data(publication.message.utf8))
        #expect(event.data.result == #"{"value":41}"#)
        #expect(event.data.executionInfo == #"{"provider":"test"}"#)
        #expect(invocations.value == 1)

        let nonmatchingFilter = ObjectFilter(condition: ObjectFilterCondition(
            property: ObjectFilterProperty("name"),
            expression: .equals("someone-else")
        ))
        let nonmatchingData = try JSONEncoder().encode(nonmatchingFilter)
        await client.emitCall(
            CallEventSnapshot(
                correlationId: "correlation-2",
                operation: "provide",
                filter: String(decoding: nonmatchingData, as: UTF8.self)
            ),
            operation: "provide"
        )
        try await Task.sleep(for: .milliseconds(50))
        #expect(returnPublications(on: client).count == 1)
        #expect(invocations.value == 1)
    }

    @Test
    func callHandlerMapsFailuresAndMalformedRequestsDeterministically() async throws {
        let client = FakeCommunicationClient(delegate: FakeStartable())
        let manager = makeManager(client: client)
        try await bringOnline(manager, client: client)
        let registration = try await manager.registerCallHandler(operation: "fail") { request in
            if request.parameters == #"{"throw":true}"# {
                throw AxolotyError.runtime(code: .notRegistered, reason: "Provider dependency is unavailable")
            }
            return .failure(code: 7, message: "Rejected", executionInfo: nil)
        }
        defer { registration.cancel() }

        await client.emitCall(
            CallEventSnapshot(correlationId: "structured", operation: "fail"),
            operation: "fail"
        )
        let structured = try await waitForReturnPublication(on: client, count: 1)
        let structuredEvent = try JSONDecoder().decode(ReturnEvent.self, from: Data(structured.message.utf8))
        #expect(structuredEvent.data.error?.code == 7)
        #expect(structuredEvent.data.error?.message == "Rejected")

        await client.emitCall(
            CallEventSnapshot(correlationId: "thrown", operation: "fail", parameters: #"{"throw":true}"#),
            operation: "fail"
        )
        let thrown = try await waitForReturnPublication(on: client, count: 2)
        let thrownEvent = try JSONDecoder().decode(ReturnEvent.self, from: Data(thrown.message.utf8))
        #expect(thrownEvent.data.error?.code == -32000)
        #expect(thrownEvent.data.error?.message == "Provider dependency is unavailable")

        await client.emitCall(
            CallEventSnapshot(correlationId: "malformed", operation: "fail", filter: "{"),
            operation: "fail"
        )
        let malformed = try await waitForReturnPublication(on: client, count: 3)
        let malformedEvent = try JSONDecoder().decode(ReturnEvent.self, from: Data(malformed.message.utf8))
        #expect(malformedEvent.data.error?.code == -32602)
        #expect(malformedEvent.data.error?.message == "Malformed context filter")

        await client.emitCall(
            CallEventSnapshot(correlationId: "malformed-parameters", operation: "fail", parameters: "{"),
            operation: "fail"
        )
        let malformedParameters = try await waitForReturnPublication(on: client, count: 4)
        let malformedParametersEvent = try JSONDecoder().decode(
            ReturnEvent.self,
            from: Data(malformedParameters.message.utf8)
        )
        #expect(malformedParametersEvent.data.error?.code == -32602)
        #expect(malformedParametersEvent.data.error?.message == "Malformed Call parameters")

        await client.emitCall(CallEventSnapshot(operation: "fail"), operation: "fail")
        try await Task.sleep(for: .milliseconds(50))
        #expect(returnPublications(on: client).count == 4)
    }

    @Test
    func callHandlerCancellationShutdownAndOfflineCompletionPreventPublication() async throws {
        let client = FakeCommunicationClient(delegate: FakeStartable())
        let manager = makeManager(client: client)
        try await bringOnline(manager, client: client)
        let cancellations = LockedCounter()
        let registration = try await manager.registerCallHandler(operation: "slow") { _ in
            do {
                try await Task.sleep(for: .seconds(5))
            } catch {
                cancellations.increment()
                throw error
            }
            return .success(result: "true")
        }
        await client.emitCall(
            CallEventSnapshot(correlationId: "cancelled", operation: "slow"),
            operation: "slow"
        )
        try await Task.sleep(for: .milliseconds(25))
        registration.cancel()
        try await Task.sleep(for: .milliseconds(25))
        #expect(cancellations.value == 1)
        #expect(returnPublications(on: client).isEmpty)

        let offlineRegistration = try await manager.registerCallHandler(operation: "offline") { _ in
            try await Task.sleep(for: .milliseconds(30))
            return .success(result: "true")
        }
        await client.emitCall(
            CallEventSnapshot(correlationId: "offline", operation: "offline"),
            operation: "offline"
        )
        await client.simulateState(.offline)
        try await Task.sleep(for: .milliseconds(75))
        #expect(returnPublications(on: client).isEmpty)

        manager.stop()
        #expect(offlineRegistration.isCancelled)
    }

    @Test
    func publishCallStillDeliversMultipleResponses() async throws {
        let client = FakeCommunicationClient(delegate: FakeStartable())
        let manager = makeManager(client: client)
        try await bringOnline(manager, client: client)
        let stream = await manager.publishCall(try CallEvent.with(operation: "stream", parameters: nil))
        let correlationId = try await waitForPublishedCorrelation(on: client)
        var iterator = stream.makeAsyncIterator()
        let first = try unaryResponse(ReturnEvent.with(result: "1", executionInfo: nil), correlationId: correlationId)
        let second = try unaryResponse(ReturnEvent.with(result: "2", executionInfo: nil), correlationId: correlationId)
        await client.emitResponse(first, eventType: .returnEvent, correlationId: correlationId)
        await client.emitResponse(second, eventType: .returnEvent, correlationId: correlationId)
        #expect(try await nextValue(&iterator, timeout: .milliseconds(500)) == first)
        #expect(try await nextValue(&iterator, timeout: .milliseconds(500)) == second)
    }
}

// MARK: - Helpers

//
// `nextValue` is shared from Tests/Testing/AsyncWaiting.swift.

@MainActor
func makeManager(client: CommunicationClient? = nil) -> CommunicationManager {
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

@MainActor
func waitForCommands(
    on client: FakeCommunicationClient,
    expecting expected: [SubscriptionCommand]
) async throws {
    for _ in 0 ..< 20 {
        if client.commands == expected {
            return
        }
        try await Task.sleep(for: .milliseconds(25))
    }
    #expect(client.commands == expected)
}

@MainActor
func bringOnline(_ manager: CommunicationManager, client: FakeCommunicationClient) async throws {
    await client.simulateState(.online)
    for _ in 0 ..< 40 {
        if manager.communicationState == .online { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw AxolotyError.runtime(code: .timedOut, reason: "Test manager did not become online")
}

@MainActor
func waitForPublishedCorrelation(
    on client: FakeCommunicationClient,
    publicationCount: Int = 1
) async throws -> String {
    for _ in 0 ..< 40 {
        let calls = client.publishedMessages.filter {
            $0.topic.split(separator: "/").dropFirst(3).first?.hasPrefix("CLL") == true
        }
        if calls.count >= publicationCount,
           let topic = calls.last?.topic,
           let correlationId = topic.split(separator: "/").last {
            return String(correlationId)
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw AxolotyError.runtime(
        code: .timedOut,
        reason: "Test Call publication was not observed; topics: \(client.publishedTopics)"
    )
}

@MainActor
func waitForCommandCount(on client: FakeCommunicationClient, count: Int) async throws {
    for _ in 0 ..< 40 {
        if client.commands.count >= count { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw AxolotyError.runtime(code: .timedOut, reason: "Test subscription command was not observed")
}

func returnPublications(on client: FakeCommunicationClient) -> [(topic: String, message: String)] {
    client.publishedMessages.filter {
        $0.topic.split(separator: "/").dropFirst(3).first == "RTN"
    }
}

@MainActor
func waitForReturnPublication(
    on client: FakeCommunicationClient,
    count: Int = 1
) async throws -> (topic: String, message: String) {
    for _ in 0 ..< 40 {
        let publications = returnPublications(on: client)
        if publications.count >= count, let publication = publications.last {
            return publication
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw AxolotyError.runtime(code: .timedOut, reason: "Test Return publication was not observed")
}

func responseTopic(_ correlationId: String) -> String {
    TopicBuilder.subscribeTopic(eventType: .returnEvent, namespace: DEFAULT_NAMESPACE, correlationId: correlationId)
}

func unaryResponse(_ event: ReturnEvent, correlationId: String) throws -> ResponseEventSnapshot {
    ResponseEventSnapshot(
        eventType: "RTN",
        sourceId: "provider",
        correlationId: correlationId,
        payload: String(decoding: try HostWireAdapter.encodeEvent(event), as: UTF8.self)
    )
}

// MARK: - Test seam

final class FakeStartable: CommunicationClientDelegate {
    func didReceiveStart() {}
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int { lock.withLock { storage } }

    func increment() {
        lock.withLock { storage += 1 }
    }
}

final class FakeCommunicationClient: CommunicationClient {
    var streams: CommunicationStreams!
    func setStreams(_ streams: CommunicationStreams) { self.streams = streams }
    var delegate: CommunicationClientDelegate
    // `commands`/`publishedTopics` are mutated from the dispatcher's drain
    // thread (subscribe/unsubscribe/publish) and polled from the test thread
    // (`waitForCommands`); guard both with a lock so TSan sees the
    // happens-before, not an unsynchronized access race.
    private let stateLock = NSLock()
    private var _commands: [SubscriptionCommand] = []
    private var _publishedTopics: [String] = []
    private var _publishedMessages: [(topic: String, message: String)] = []
    private var _actions: [String] = []
    var commands: [SubscriptionCommand] { stateLock.withLock { _commands } }
    var publishedTopics: [String] { stateLock.withLock { _publishedTopics } }
    var publishedMessages: [(topic: String, message: String)] { stateLock.withLock { _publishedMessages } }
    var actions: [String] { stateLock.withLock { _actions } }
    private let subscriptionGate: SubscriptionAckGate?

    init(delegate: CommunicationClientDelegate, subscriptionGate: SubscriptionAckGate? = nil) {
        self.delegate = delegate
        self.subscriptionGate = subscriptionGate
    }

    @MainActor func simulateState(_ state: CommunicationState) async {
        delegate.didUpdateCommunicationState(state)
        await streams.communicationState.sendState(state)
    }

    @MainActor func simulateRawMessage(topic: String, payload: [UInt8]) async {
        await streams.rawMQTTMessages.send(RawMQTTMessage(topic: topic, payload: payload))
    }

    @MainActor func emitAdvertise(_ snapshot: AdvertiseEventSnapshot, filter: String, objectType: String? = nil) async {
        await streams.advertiseFamily.send(snapshot, for: AdvertiseKey(eventTypeFilter: filter, objectTypeFilter: objectType))
        await streams.advertiseAll.send(snapshot)
    }
    @MainActor func emitDeadvertise(_ snapshot: DeadvertiseEventSnapshot) async {
        await streams.deadvertise.send(snapshot)
    }
    @MainActor func emitDiscover(_ snapshot: DiscoverEventSnapshot) async {
        await streams.discover.send(snapshot)
    }
    @MainActor func emitQuery(_ snapshot: QueryEventSnapshot) async {
        await streams.query.send(snapshot)
    }
    @MainActor func emitCall(_ snapshot: CallEventSnapshot, operation: String) async {
        await streams.callFamily.send(snapshot, for: operation)
    }
    @MainActor func emitUpdate(_ snapshot: UpdateEventSnapshot, filter: String) async {
        await streams.updateFamily.send(snapshot, for: filter)
    }
    @MainActor func emitChannel(_ snapshot: ChannelEventSnapshot, channelId: String) async {
        await streams.channelFamily.send(snapshot, for: channelId)
    }
    @MainActor func emitIoValue(_ snapshot: IoValueEventSnapshot) async {
        await streams.ioValues.send(snapshot)
    }
    @MainActor func emitResponse(_ snapshot: ResponseEventSnapshot, eventType: WireEventType, correlationId: String) async {
        await streams.responseFamily.send(snapshot, for: ResponseKey(eventType: eventType, correlationId: correlationId))
    }
    @MainActor func emitOperatingState(_ state: OperatingState) async {
        await streams.operatingState.sendState(state)
    }

    func connect(lastWillTopic _: String, lastWillMessage _: String) {}
    func disconnect() {}
    func publish(_ topic: String, message: String) {
        stateLock.withLock {
            _publishedTopics.append(topic)
            _publishedMessages.append((topic, message))
            _actions.append("publish:\(topic)")
        }
    }
    func publish(_ topic: String, message: [UInt8]) {
        stateLock.withLock {
            _publishedTopics.append(topic)
            if let string = String(bytes: message, encoding: .utf8) {
                _publishedMessages.append((topic, string))
            }
            _actions.append("publish:\(topic)")
        }
    }
    @MainActor func publishAndWait(_ topic: String, message: [UInt8]) async throws {
        publish(topic, message: message)
    }
    @MainActor func subscribe(_ topic: String) async throws {
        stateLock.withLock {
            _commands.append(.subscribe(topic))
            _actions.append("subscribe:\(topic)")
        }
        if let subscriptionGate {
            await subscriptionGate.markStarted()
            await subscriptionGate.waitUntilOpen()
        }
    }

    @MainActor func unsubscribe(_ topic: String) async throws {
        stateLock.withLock {
            _commands.append(.unsubscribe(topic))
            _actions.append("unsubscribe:\(topic)")
        }
    }
}

private func makeTestStreams() -> CommunicationStreams {
    CommunicationStreams(
        communicationState: Broadcast(mode: .state),
        operatingState: Broadcast(mode: .state),
        rawMQTTMessages: Broadcast(mode: .event),
        parsedMQTTMessages: Broadcast(mode: .event),
        ioValues: Broadcast(mode: .event),
        ioStateFamily: BroadcastFamily(mode: .state),
        associateFamily: BroadcastFamily(mode: .event),
        advertiseFamily: BroadcastFamily(mode: .event),
        advertiseAll: Broadcast(mode: .event),
        deadvertise: Broadcast(mode: .event),
        discover: Broadcast(mode: .event),
        query: Broadcast(mode: .event),
        callFamily: BroadcastFamily(mode: .event),
        updateFamily: BroadcastFamily(mode: .event),
        channelFamily: BroadcastFamily(mode: .event),
        responseFamily: BroadcastFamily(mode: .event)
    )
}

actor SubscriptionAckGate {
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

/// Parses the event type from a published topic string via ``TopicView``.
func topicEventType(_ topic: String) -> WireEventType? {
    let bytes = Array(topic.utf8)
    return bytes.withUnsafeBufferPointer { buf in
        TopicView(topicBytes: buf.baseAddress!, length: buf.count).eventType
    }
}

/// Parses the correlation-id level from a published topic string via ``TopicView``.
func topicCorrelationId(_ topic: String) -> String? {
    let bytes = Array(topic.utf8)
    return bytes.withUnsafeBufferPointer { buf in
        TopicView(topicBytes: buf.baseAddress!, length: buf.count).correlationIdLevel?.asString()
    }
}

// MARK: - Namespace-wide Advertise stream tests

@MainActor
@Suite
struct NamespaceAdvertiseStreamTests {

    @Test
    func namespaceWideStreamAcquiresWildcardTopic() async throws {
        let client = FakeCommunicationClient(delegate: FakeStartable())
        let manager = makeManager(client: client)
        let expectedTopic = TopicBuilder.subscribeAllOneWayTopics(namespace: manager.namespace)

        let stream = await manager.observeAdvertiseStream()
        let iterator = stream.makeAsyncIterator()
        await client.simulateState(.online)
        try await waitForCommands(on: client, expecting: [.subscribe(expectedTopic)])

        let holder = AsyncStreamBox(iterator)
        let consumer = Task { while await holder.iterator.next() != nil {} }
        consumer.cancel()
        _ = await consumer.value

        try await waitUntil("advertise-all topic to be released") {
            client.commands.contains { cmd in
                if case .unsubscribe(let released) = cmd { return released == expectedTopic }
                return false
            }
        }
    }

    @Test
    func namespaceWideStreamReceivesCoreTypeAdvertise() async throws {
        let client = FakeCommunicationClient(delegate: FakeStartable())
        let manager = makeManager(client: client)
        let stream = await manager.observeAdvertiseStream()
        var iterator = stream.makeAsyncIterator()
        await client.simulateState(.online)

        let snapshot = AdvertiseEventSnapshot(
            sourceId: "source-1",
            eventTypeFilter: CoreType.Log.rawValue,
            object: CoatyObjectSnapshot(
                objectId: "obj-1",
                coreType: .Log,
                objectType: Log.objectType,
                name: "log-object"
            )
        )
        await client.emitAdvertise(snapshot, filter: CoreType.Log.rawValue)

        #expect(try await nextValue(&iterator, timeout: .milliseconds(500)) == snapshot)
    }

    @Test
    func namespaceWideStreamReceivesCustomObjectTypeAdvertise() async throws {
        let client = FakeCommunicationClient(delegate: FakeStartable())
        let manager = makeManager(client: client)
        let stream = await manager.observeAdvertiseStream()
        var iterator = stream.makeAsyncIterator()
        await client.simulateState(.online)

        let customObjectType = "com.example.CustomSensor"
        let snapshot = AdvertiseEventSnapshot(
            sourceId: "source-2",
            eventTypeFilter: ":" + customObjectType,
            object: CoatyObjectSnapshot(
                objectId: "obj-2",
                coreType: .Identity,
                objectType: customObjectType,
                name: "custom-sensor"
            )
        )
        await client.emitAdvertise(snapshot, filter: ":" + customObjectType)

        #expect(try await nextValue(&iterator, timeout: .milliseconds(500)) == snapshot)
    }

    @Test
    func namespaceWideStreamAndCoreTypeStreamBothReceiveSameEvent() async throws {
        let client = FakeCommunicationClient(delegate: FakeStartable())
        let manager = makeManager(client: client)
        let allStream = await manager.observeAdvertiseStream()
        let coreStream = await manager.observeAdvertiseStream(withCoreType: .Log)
        var allIterator = allStream.makeAsyncIterator()
        var coreIterator = coreStream.makeAsyncIterator()
        await client.simulateState(.online)

        let snapshot = AdvertiseEventSnapshot(
            sourceId: "source-3",
            eventTypeFilter: CoreType.Log.rawValue,
            object: CoatyObjectSnapshot(
                objectId: "obj-3",
                coreType: .Log,
                objectType: Log.objectType,
                name: "dual-recv"
            )
        )
        await client.emitAdvertise(snapshot, filter: CoreType.Log.rawValue)

        #expect(try await nextValue(&allIterator, timeout: .milliseconds(500)) == snapshot)
        #expect(try await nextValue(&coreIterator, timeout: .milliseconds(500)) == snapshot)
    }

    @Test
    func namespaceWideStreamUsesCorrectNamespaceInTopic() async throws {
        let client = FakeCommunicationClient(delegate: FakeStartable())
        let mqttOptions = MQTTClientOptions(
            host: "127.0.0.1",
            port: 1883,
            shouldTryMDNSDiscovery: false,
            autoReconnect: false
        )
        let communicationOptions = CommunicationOptions(
            namespace: "test-ns-42",
            shouldEnableCrossNamespacing: false,
            mqttClientOptions: mqttOptions,
            shouldAutoStart: false
        )
        let manager = try! CommunicationManager(
            identity: Identity(name: "NS-Test"),
            communicationOptions: communicationOptions,
            commonOptions: nil,
            client: client
        )

        let expectedTopic = TopicBuilder.subscribeAllOneWayTopics(namespace: "test-ns-42")

        let stream = await manager.observeAdvertiseStream()
        _ = stream.makeAsyncIterator()
        await client.simulateState(.online)
        try await waitForCommands(on: client, expecting: [.subscribe(expectedTopic)])
    }
}
