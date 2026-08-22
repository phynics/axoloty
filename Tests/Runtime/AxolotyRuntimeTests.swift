// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Testing
import Axoloty
import AxolotyProtocol
import AxolotyWire

@Suite("Axoloty runtime")
struct AxolotyRuntimeTests {
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

    @Test("runtime uses the shared processor for an accepted local operation")
    func acceptsLocalOperation() async throws {
        let definition = try makeDefinition()
        let transport = TestTransport()
        let runtime = AxolotyRuntime(definition: definition, transport: transport)
        try await runtime.start()

        let receipt = await runtime.publish(
            RuntimeOperation(
                capability: .ioValue,
                sourceID: .zero,
                payload: [0x7B, 0x7D]
            )
        )
        #expect(receipt == .accepted)
        for _ in 0..<100 {
            if await transport.sentCount() == 1 { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(await transport.sentCount() == 1)
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

    @Test("post-start transport failures terminate the runtime")
    func postStartTransportFailureTerminatesRuntime() async throws {
        let definition = try makeDefinition()
        let transport = TestTransport()
        let runtime = AxolotyRuntime(definition: definition, transport: transport)
        try await runtime.start()

        await transport.fail(TestTransportFailure())
        for _ in 0..<100 {
            if await runtime.state() == .stopped { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(await runtime.state() == .stopped)
        #expect((await runtime.diagnosticsSnapshot()).transportFailures == 1)
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
    private var sent: [OwnedProtocolAction] = []
    private(set) var lifecycle: [String] = []

    func start(receive: @escaping @Sendable (RuntimeInboundFrame) -> Void) async throws {
        self.receive = receive
        lifecycle.append("start")
    }

    func setFailureHandler(_ handler: @escaping @Sendable (Error) -> Void) {
        failure = handler
    }

    func send(_ action: OwnedProtocolAction, namespace: String) async throws {
        sent.append(action)
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

    func fail(_ error: Error) { failure?(error) }
}

private struct TestTransportFailure: Error, Sendable {}
