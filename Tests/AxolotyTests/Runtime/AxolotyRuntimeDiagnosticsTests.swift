// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Testing
@testable import Axoloty
import AxolotyObjectModel
import AxolotyProtocol
import AxolotyTestSupport
import AxolotyWire

extension AxolotyRuntimeTests {
    @Test("runtime rejects work before start")
    func rejectsBeforeStart() async throws {
        let definition = try makeDefinition()
        let runtime = AxolotyRuntime(definition: definition, transport: TestTransport())
        let receipt = await runtime.receive(.profile(topic: "coaty/3/test/IOV/00000000-0000-0000-0000-000000000000", payload: [0x7B, 0x7D], nowMS: 0))
        #expect(receipt == .rejected(.notRunning(.stopped)))
    }

    @Test("runtime orders subscription and identity lifecycle around transport")
    func lifecycleOrdering() async throws {
        let identity = try RuntimeIdentity(id: .zero, name: "lifecycle-test")
        let runtimeDefinition = try RuntimeDefinition(
            namespace: "test",
            sourceID: .zero,
            identity: identity,
            capacities: try RuntimeCapacities()
        )
        let definition = try runtimeDefinition.seal()
        let transport = TestTransport()
        let runtime = AxolotyRuntime(definition: definition, transport: transport)
        #expect(await runtime.state() == .initialized)
        try await runtime.start()
        #expect(await runtime.state() == .running)
        #expect(await transport.lifecycle == ["start", "install"])
        let advertisement = try #require(await transport.firstSent())
        #expect(advertisement.routingKey.capability == .advertise)
        #expect(String(decoding: advertisement.payload, as: UTF8.self).contains("coaty.Identity"))

        await runtime.reconnect()
        #expect(await runtime.state() == .running)
        #expect(await transport.lifecycle == [
            "start", "install", "remove", "stop", "start", "install"
        ])

        await runtime.stop()
        #expect(await runtime.state() == .stopped)
        let lifecycle = await transport.lifecycle
        #expect(Array(lifecycle.suffix(2)) == ["remove", "stop"])
        let deadvertisement = try #require(await transport.lastSent())
        #expect(deadvertisement.routingKey.capability == .deadvertise)
        #expect(String(decoding: deadvertisement.payload, as: UTF8.self) == "{\"objectIds\":[\"00000000-0000-0000-0000-000000000000\"]}")
    }

    @Test("startup failure injection preserves terminal cleanup", arguments: SetupFailureStage.allCases)
    func startupFailureInjectionPreservesTerminalCleanup(stage: SetupFailureStage) async throws {
        let transport = TestTransport(failing: stage)
        let identity = try RuntimeIdentity(id: .zero, name: "failure-injection")
        let definition = try RuntimeDefinition(
            namespace: "test",
            sourceID: .zero,
            identity: identity,
            capacities: try RuntimeCapacities()
        ).seal()
        let runtime = AxolotyRuntime(definition: definition, transport: transport)

        do {
            try await runtime.start()
            Issue.record("runtime start unexpectedly succeeded while failing \(stage)")
        } catch let error as AxolotyError {
            guard case let .runtime(code, _) = error else {
                Issue.record("unexpected startup failure: \(error.userFriendlyMessage)")
                return
            }
            #expect(code == .brokerUnavailable)
        }

        for _ in 0..<100 {
            if await runtime.state() == .stopped { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(await runtime.state() == .stopped)
        #expect(await transport.lifecycle == stage.expectedLifecycle)
    }

    @Test("post-start transport failures enter recoverable reconnecting state")
    func postStartTransportFailureEntersReconnect() async throws {
        let definition = try makeDefinition()
        let transport = TestTransport()
        let runtime = AxolotyRuntime(definition: definition, transport: transport)
        try await runtime.start()

        await transport.fail(TestTransportFailure())
        try await waitUntil("runtime to enter reconnecting state") {
            await runtime.state() == .reconnecting
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
        try await waitUntil("runtime to enter reconnecting state") {
            await runtime.state() == .reconnecting
        }
        #expect(await runtime.state() == .reconnecting)
        let receipt = await runtime.publish(.advertise(
            Array(#"{"object":{"objectId":"66666666-6666-4666-8666-666666666666","coreType":"CoatyObject","objectType":"com.coaty.test.WireQueuedFixture","name":"first"}}"#.utf8)
        ))
        #expect(receipt == .accepted)
        #expect(await transport.sentCount() == 0)
        await runtime.reconnect()
        try await waitUntil("queued publications to reach the transport") {
            await transport.sentCount() == 2
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
        try await waitUntil("outbound transport send to start") {
            await transport.sendStarted
        }
        #expect(await transport.sendStarted)

        let stopping = Task { await runtime.stop() }
        defer {
            stopping.cancel()
            Task { await transport.releaseSend() }
        }
        try await waitUntil("transport stop to begin") {
            await transport.didStop
        }
        #expect(await transport.didStop)
        #expect(await runtime.lifecycleState() == .stopping)

        await transport.releaseSend()
        await stopping.value
        #expect(await runtime.lifecycleState() == .stopped)
    }
}

