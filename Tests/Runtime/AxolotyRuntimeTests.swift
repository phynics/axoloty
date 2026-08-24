// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Testing
@testable import Axoloty
import AxolotyProtocol
import AxolotyWire

@Suite("Axoloty runtime")
struct AxolotyRuntimeTests {
    @Test("MQTT topics preserve the complete UUID")
    func mqttUUIDFormattingPreservesAllBytes() throws {
        let id = try #require(UUID16(parsing: "44444444-4444-4444-8444-444444444444"))
        #expect(MQTTBinding.uuidString(id) == "44444444-4444-4444-8444-444444444444")
    }

    @Test("identity startup advertisement uses the canonical core-type filter")
    func identityStartupTopicIsFiltered() throws {
        let id = try #require(UUID16(parsing: "44444444-4444-4444-8444-444444444444"))
        let key = try ProtocolRoutingKey(capability: .advertise, sourceID: id)
        #expect(MQTTBinding.topic(
            for: key,
            namespace: "test",
            eventTypeFilter: Array("Identity".utf8)
        ) == "coaty/3/test/ADV:Identity/44444444-4444-4444-8444-444444444444")
    }

    @Test("builder seals typed event streams and responders")
    func builderSealsModernContracts() throws {
        let identity = try RuntimeIdentity(id: .zero, name: "inspector")
        var builder = try RuntimeDefinition.Builder(identity: identity, namespace: "building-a")
        _ = try builder.events(
            matching: .family(.advertise),
            buffering: .coalesceLatest
        )
        _ = try builder.respond(
            to: .call(operation: "device.read"),
            maximumConcurrentInvocations: 1
        ) { _ in .noResponse }
        let sealed = try builder.finish()
        #expect(sealed.identity == identity)
        #expect(sealed.handlerCount == 1)
    }

    @Test("definition seals a finite handler set")
    func definitionSealsHandlers() throws {
        let capacities = try RuntimeCapacities(handlers: 1)
        var definition = try RuntimeDefinition(
            namespace: "test",
            sourceID: .zero,
            capacities: capacities
        )
        _ = try definition.register(capability: .ioValue) { _ in .noResponse }
        let sealed = try definition.seal()
        #expect(sealed.capacities.handlers == 1)
        #expect(sealed.handlerCount == 1)
    }

    @Test("definition rejects MQTT-invalid namespace bytes")
    func rejectsInvalidNamespaceBytes() throws {
        let identity = try RuntimeIdentity(id: .zero, name: "namespace-test")
        #expect(throws: AxolotyError.self) {
            _ = try RuntimeDefinition.Builder(identity: identity, namespace: "building\0a")
        }
    }

    @Test("definition bounds event-stream registration")
    func definitionBoundsEventStreams() throws {
        let capacities = try RuntimeCapacities(eventStreams: 1)
        var definition = try RuntimeDefinition(
            namespace: "test",
            sourceID: .zero,
            capacities: capacities
        )
        _ = try definition.registerEvents(
            matching: .family(.advertise),
            buffering: .failAfterDrop(capacity: 1)
        )
        do {
            _ = try definition.registerEvents(
                matching: .family(.deadvertise),
                buffering: .coalesceLatest
            )
            Issue.record("event-stream registration exceeded its configured capacity")
        } catch let error as AxolotyError {
            guard case let .runtime(code, reason) = error else {
                Issue.record("unexpected error: \(error.userFriendlyMessage)")
                return
            }
            #expect(code == .capacityExceeded)
            #expect(reason == "runtime event-stream capacity is full")
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("runtime rejects work before start")
    func rejectsBeforeStart() async throws {
        let definition = try makeDefinition()
        let runtime = AxolotyRuntime(definition: definition, transport: TestTransport())
        let receipt = await runtime.receive(RuntimeInboundFrame(topic: "coaty/3/test/IOV/00000000-0000-0000-0000-000000000000", payload: [0x7B, 0x7D]))
        #expect(receipt == .rejected(.notRunning(.stopped)))
    }

    @Test("runtime uses the shared processor for an accepted local publication")
    func acceptsLocalOperation() async throws {
        let definition = try makeDefinition()
        let transport = TestTransport()
        let runtime = AxolotyRuntime(definition: definition, transport: transport)
        try await runtime.start()

        let receipt = await runtime.publish(.channel(
            identifier: "accepted-local-publication",
            payload: Array(#"{"privateData":{"accepted":true}}"#.utf8)
        ))
        #expect(receipt == .accepted)
        for _ in 0..<100 {
            if await transport.sentCount() == 1 { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(await transport.sentCount() == 1)
        await runtime.stop()
    }

    @Test("Call operation names remain topic filters on outbound actions")
    func callOperationNameReachesTransportAction() async throws {
        let definition = try makeDefinition()
        let transport = TestTransport()
        let runtime = AxolotyRuntime(definition: definition, transport: transport)
        try await runtime.start()

        let correlation = try #require(UUID16(parsing: "55555555-5555-4555-8555-555555555555"))
        let receipt = await runtime.request(.call(
            correlationID: correlation,
            operation: "wire-fixture-operation",
            payload: Array(#"{"parameters":{"operand":7}}"#.utf8),
            timeoutMS: 1_000
        ))
        #expect(receipt == .accepted)
        for _ in 0..<100 {
            if await transport.sentCount() == 1 { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        let action = try #require(await transport.lastSent())
        guard case .profile(let filter, _) = action.target else {
            Issue.record("Call publication did not use the profile target")
            return
        }
        #expect(filter == Array("wire-fixture-operation".utf8))
        await runtime.stop()
    }

    @Test("Channel identifiers remain typed topic filters on outbound actions")
    func channelIdentifierReachesTransportAction() async throws {
        let definition = try makeDefinition()
        let transport = TestTransport()
        let runtime = AxolotyRuntime(definition: definition, transport: transport)
        try await runtime.start()

        let receipt = await runtime.publish(.channel(
            identifier: "wire-fixture-channel",
            payload: Array(#"{"privateData":{"sequence":7}}"#.utf8)
        ))
        #expect(receipt == .accepted)
        for _ in 0..<100 {
            if await transport.sentCount() == 1 { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        let action = try #require(await transport.lastSent())
        guard case .profile(let filter, let kind) = action.target else {
            Issue.record("Channel publication did not use the profile target")
            return
        }
        #expect(filter == Array("wire-fixture-channel".utf8))
        #expect(kind == .direct)
        await runtime.stop()
    }

    @Test("dispatch reservation rejects a complete multi-action publication atomically")
    func multiActionDispatchReservationIsAtomic() async throws {
        let definition = try RuntimeDefinition(
            namespace: "test",
            sourceID: .zero,
            capacities: try RuntimeCapacities(dispatch: 1)
        ).seal()
        let transport = TestTransport()
        let runtime = AxolotyRuntime(definition: definition, transport: transport)
        try await runtime.start()

        let payload = Array(#"{"object":{"objectId":"66666666-6666-4666-8666-666666666666","coreType":"CoatyObject","objectType":"com.coaty.test.WireQueuedFixture","name":"first"}}"#.utf8)
        #expect(await runtime.publish(.advertise(payload)) == .rejected(.capacityExceeded))
        try await Task.sleep(for: .milliseconds(20))
        #expect(await transport.sentCount() == 0)
        await runtime.stop()
    }

    @Test("wire publication variants emit one logical runtime event")
    func advertiseVariantsDoNotDuplicateRuntimeEvents() async throws {
        let identity = try RuntimeIdentity(id: .zero, name: "semantic-event-test")
        var builder = try RuntimeDefinition.Builder(
            identity: identity,
            namespace: "test",
            limits: try RuntimeCapacities(dispatch: 2)
        )
        _ = try builder.events(
            matching: .family(.advertise),
            buffering: .fail(capacity: 1)
        )
        let transport = TestTransport()
        let runtime = AxolotyRuntime(definition: try builder.finish(), transport: transport)
        try await runtime.start()

        let payload = Array(#"{"object":{"objectId":"77777777-7777-4777-8777-777777777777","coreType":"CoatyObject","objectType":"com.coaty.test.WireFixture","name":"wire-fixture"}}"#.utf8)
        #expect(await runtime.publish(.advertise(payload)) == .accepted)
        for _ in 0..<100 {
            if await transport.sentCount() == 2 { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(await transport.sentCount() == 2)
        #expect(await runtime.state() == .running)
        await runtime.stop()
    }

    @Test("Channel requires a typed identifier")
    func channelRejectsMissingIdentifier() async throws {
        let runtime = AxolotyRuntime(definition: try makeDefinition(), transport: TestTransport())
        try await runtime.start()
        #expect(await runtime.publish(RuntimeOperation(
            capability: .channel,
            sourceID: .zero,
            payload: Array("{}".utf8)
        )) == .rejected(.invalidOperationName))
        await runtime.stop()
    }

    @Test("default request deadlines use the monotonic runtime clock")
    func defaultRequestUsesMonotonicClock() async throws {
        let definition = try makeDefinition()
        let runtime = AxolotyRuntime(definition: definition, transport: TestTransport())
        try await runtime.start()
        let correlation = try #require(UUID16(parsing: "57575757-5757-4575-8575-575757575757"))
        #expect(await runtime.request(.discover(
            correlationID: correlation,
            payload: Array("{}".utf8),
            timeoutMS: 1
        )) == .accepted)
        #expect(await runtime.expire(nowMS: 1) == false)
        await runtime.stop()
    }

    @Test("unlimited Discover correlations remain active until canceled")
    func unlimitedDiscoverCanBeCanceled() async throws {
        let definition = try makeDefinition()
        let runtime = AxolotyRuntime(definition: definition, transport: TestTransport())
        try await runtime.start()
        let correlation = try #require(UUID16(parsing: "58585858-5858-4585-8585-585858585858"))
        #expect(await runtime.request(.discover(
            correlationID: correlation,
            payload: Array("{}".utf8),
            timeoutMS: nil
        )) == .accepted)
        #expect(await runtime.cancel(correlationID: correlation))
        await runtime.stop()
    }

    @Test("invalid Call operation names are rejected before publication")
    func rejectsInvalidCallOperationNames() async throws {
        let definition = try makeDefinition()
        let transport = TestTransport()
        let runtime = AxolotyRuntime(definition: definition, transport: transport)
        try await runtime.start()

        let correlation = try #require(UUID16(parsing: "56565656-5656-4565-8565-565656565656"))
        let invalidNames = [
            "",
            "invalid/operation",
            "invalid\0operation",
            String(repeating: "x", count: RuntimeOperationValidation.maximumUTF8Bytes + 1)
        ]
        for operation in invalidNames {
            let receipt = await runtime.request(.call(
                correlationID: correlation,
                operation: operation,
                payload: Array(#"{"parameters":{"operand":7}}"#.utf8),
                timeoutMS: 1_000
            ))
            #expect(receipt == .rejected(.invalidOperationName))
        }
        #expect(await transport.sentCount() == 0)
        await runtime.stop()
    }

    @Test("Call responders reject MQTT-invalid operation names")
    func rejectsInvalidResponderOperationNames() throws {
        let identity = try RuntimeIdentity(id: .zero, name: "invalid-operation-test")
        var builder = try RuntimeDefinition.Builder(identity: identity, namespace: "test")
        do {
            _ = try builder.respond(to: .call(operation: "invalid\0operation")) { _ in .noResponse }
            Issue.record("the responder accepted an operation name containing NUL")
        } catch let error as AxolotyError {
            guard case let .invalidArgument(argument, _) = error else {
                Issue.record("unexpected error: \(error.userFriendlyMessage)")
                return
            }
            #expect(argument == "operation")
        }
    }

    @Test("non-Call handlers reject operation filters")
    func rejectsNonCallOperationFilters() throws {
        let identity = try RuntimeIdentity(id: .zero, name: "non-call-operation-test")
        var builder = try RuntimeDefinition.Builder(identity: identity, namespace: "test")
        do {
            _ = try builder.respond(to: .advertise, operation: "not-a-call") { _ in .noResponse }
            Issue.record("the non-Call handler accepted an operation filter")
        } catch let error as AxolotyError {
            guard case let .invalidArgument(argument, _) = error else {
                Issue.record("unexpected error: \(error.userFriendlyMessage)")
                return
            }
            #expect(argument == "operation")
        }
    }

    @Test("advertise selectors match the payload object type")
    func advertiseSelectorMatchesPayloadObjectType() async throws {
        let identity = try RuntimeIdentity(id: .zero, name: "selector-test")
        var builder = try RuntimeDefinition.Builder(identity: identity, namespace: "test")
        let stream = try builder.events(
            matching: .advertise(objectType: "com.coaty.test.WireFixture"),
            buffering: .dropOldest(capacity: 2)
        )
        let runtime = AxolotyRuntime(
            definition: try builder.finish(),
            transport: TestTransport()
        )
        try await runtime.start()

        var iterator = stream.makeAsyncIterator()
        let receipt = await runtime.receive(RuntimeInboundFrame(
            topic: "coaty/3/test/ADV:CoatyObject/22222222-2222-4222-8222-222222222222",
            payload: Array(#"{"object":{"objectId":"11111111-1111-4111-8111-111111111111","coreType":"CoatyObject","objectType":"com.coaty.test.WireFixture","name":"wire-fixture"}}"#.utf8)
        ))
        #expect(receipt == .accepted)
        let event = try #require(await iterator.next())
        #expect(event.context.sourceID == UUID16(parsing: "22222222-2222-4222-8222-222222222222"))
        #expect(String(decoding: event.value, as: UTF8.self).contains("com.coaty.test.WireFixture"))
        await runtime.stop()
    }

    @Test("runtime orders subscription and identity lifecycle around transport")
    func lifecycleOrdering() async throws {
        let definition = try makeDefinition()
        let transport = TestTransport()
        let runtime = AxolotyRuntime(definition: definition, transport: transport)
        #expect(await runtime.state() == .initialized)
        try await runtime.start()
        #expect(await runtime.state() == .running)
        #expect(await transport.lifecycle == ["start", "install", "advertise"])

        await runtime.reconnect()
        #expect(await runtime.state() == .running)
        #expect(await transport.lifecycle == [
            "start", "install", "advertise", "remove", "stop", "start", "install", "advertise"
        ])

        await runtime.stop()
        #expect(await runtime.state() == .stopped)
        let lifecycle = await transport.lifecycle
        #expect(Array(lifecycle.suffix(3)) == ["deadvertise", "remove", "stop"])
    }

    @Test("post-start transport failures enter recoverable reconnecting state")
    func postStartTransportFailureEntersReconnect() async throws {
        let definition = try makeDefinition()
        let transport = TestTransport()
        let runtime = AxolotyRuntime(definition: definition, transport: transport)
        try await runtime.start()

        await transport.fail(TestTransportFailure())
        for _ in 0..<100 {
            if await runtime.state() == .reconnecting { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(await runtime.state() == .reconnecting)
        #expect((await runtime.diagnosticsSnapshot()).transportFailures == 1)
        await runtime.stop()
    }

    @Test("runtime queues bounded one-way publications across reconnect")
    func queuesOfflineOneWayPublication() async throws {
        let definition = try makeDefinition()
        let transport = TestTransport()
        let runtime = AxolotyRuntime(definition: definition, transport: transport)
        try await runtime.start()
        await transport.fail(TestTransportFailure())
        for _ in 0..<100 {
            if await runtime.state() == .reconnecting { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(await runtime.state() == .reconnecting)
        let receipt = await runtime.publish(RuntimeOperation.advertise(
            sourceID: .zero,
            payload: Array(#"{"object":{"objectId":"66666666-6666-4666-8666-666666666666","coreType":"CoatyObject","objectType":"com.coaty.test.WireQueuedFixture","name":"first"}}"#.utf8)
        ))
        #expect(receipt == .accepted)
        #expect(await transport.sentCount() == 0)
        await runtime.reconnect()
        for _ in 0..<100 {
            if await transport.sentCount() == 2 { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(await runtime.state() == .running)
        #expect(await transport.sentCount() == 2)
        await runtime.stop()
    }

    @Test("runtime stop waits for an in-flight transport send")
    func stopDrainsOutboundPump() async throws {
        let definition = try makeDefinition()
        let transport = DrainingTransport()
        let runtime = AxolotyRuntime(definition: definition, transport: transport)
        try await runtime.start()
        #expect(await runtime.publish(.channel(
            identifier: "drain-publication",
            payload: Array(#"{"privateData":{"drain":true}}"#.utf8)
        )) == .accepted)
        for _ in 0..<100 {
            if await transport.sendStarted { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(await transport.sendStarted)

        let stopping = Task { await runtime.stop() }
        for _ in 0..<100 {
            if await transport.didStop { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(await transport.didStop)
        #expect(await runtime.lifecycleState() == .stopping)
        try await Task.sleep(for: .milliseconds(20))
        #expect(await runtime.lifecycleState() == .stopping)

        await transport.releaseSend()
        await stopping.value
        #expect(await runtime.lifecycleState() == .stopped)
    }

    private func makeDefinition() throws -> SealedRuntimeDefinition {
        let definition = try RuntimeDefinition(
            namespace: "test",
            sourceID: .zero,
            capacities: try RuntimeCapacities()
        )
        return try definition.seal()
    }
}

private actor TestTransport: AxolotyRuntimeTransport {
    private var receive: (@Sendable (RuntimeInboundFrame) -> Void)?
    private var failure: (@Sendable (Error) -> Void)?
    private var sent: [OwnedProtocolPublication] = []
    private(set) var lifecycle: [String] = []

    func start(receive: @escaping @Sendable (RuntimeInboundFrame) -> Void) async throws {
        self.receive = receive
        lifecycle.append("start")
    }

    func setFailureHandler(_ handler: @escaping @Sendable (Error) -> Void) {
        failure = handler
    }

    func send(_ publication: OwnedProtocolPublication, namespace: String) async throws {
        sent.append(publication)
    }

    func stop() async {
        receive = nil
        lifecycle.append("stop")
    }

    func installSubscriptions(namespace: String) async throws { lifecycle.append("install") }
    func removeSubscriptions(namespace: String) async throws { lifecycle.append("remove") }
    func advertise(identity: RuntimeIdentity?, namespace: String) async throws { lifecycle.append("advertise") }
    func deadvertise(identity: RuntimeIdentity?, namespace: String) async throws { lifecycle.append("deadvertise") }

    func sentCount() -> Int { sent.count }
    func lastSent() -> OwnedProtocolPublication? { sent.last }

    func fail(_ error: Error) { failure?(error) }
}

private struct TestTransportFailure: Error, Sendable {}

private actor DrainingTransport: AxolotyRuntimeTransport {
    private(set) var sendStarted = false
    private(set) var didStop = false
    private var released = false

    func start(receive: @escaping @Sendable (RuntimeInboundFrame) -> Void) async throws {}
    func setFailureHandler(_ handler: @escaping @Sendable (Error) -> Void) {}

    func send(_ publication: OwnedProtocolPublication, namespace: String) async throws {
        sendStarted = true
        while !released {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    func stop() async { didStop = true }
    func installSubscriptions(namespace: String) async throws {}
    func removeSubscriptions(namespace: String) async throws {}
    func advertise(identity: RuntimeIdentity?, namespace: String) async throws {}
    func deadvertise(identity: RuntimeIdentity?, namespace: String) async throws {}

    func releaseSend() { released = true }
}
