// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Testing
@testable import Axoloty
import AxolotyObjectModel
import AxolotyProtocol
import AxolotyTestSupport
import AxolotyWire
import Foundation

extension AxolotyRuntimeTests {
    @Test("run completes when the executor is stopped")
    func runCompletesWhenStopped() async throws {
        let runtime = AxolotyRuntime(definition: try makeDefinition(), transport: TestTransport())
        let running = Task { try await runtime.run() }
        try await waitUntil("runtime to enter running state") {
            await runtime.state() == .running
        }

        await runtime.stop()
        try await withTimeout("run to complete after stop", timeout: .seconds(2)) {
            try await running.value
        }
        #expect(await runtime.state() == .stopped)
    }

    @Test("run cancellation during startup stops the executor")
    func runCancellationDuringStartupStopsExecutor() async throws {
        let transport = BlockingStartTransport()
        let runtime = AxolotyRuntime(definition: try makeDefinition(), transport: transport)
        let running = Task { () -> Bool in
            do {
                try await runtime.run()
                return true
            } catch {
                return false
            }
        }
        try await waitUntil("transport start to begin") {
            await transport.didStart
        }

        running.cancel()
        #expect(try await withTimeout("run cancellation during startup") {
            await running.value
        })
        #expect(await runtime.state() == .stopped)
    }

    @Test("runtime rejects work before start")
    func rejectsBeforeStart() async throws {
        let definition = try makeDefinition()
        let runtime = AxolotyRuntime(definition: definition, transport: TestTransport())
        let receipt = await runtime.receive(.profile(route: "coaty/3/test/IOV/00000000-0000-0000-0000-000000000000", payload: [0x7B, 0x7D], nowMS: 0))
        #expect(receipt == .rejected(.notRunning(.stopped)))
    }

    @Test("runtime orders subscription and identity lifecycle around transport")
    func lifecycleOrdering() async throws {
        let identity = try RuntimeIdentity(id: .zero, name: "lifecycle-test")
        let runtimeDefinition = try RuntimeBuilder(
            sourceID: .zero,
            namespace: "test",
            identity: identity,
            capacities: try RuntimeCapacities()
        )
        let definition = try runtimeDefinition.finish()
        let transport = TestTransport()
        let runtime = AxolotyRuntime(definition: definition, transport: transport)
        #expect(await runtime.state() == .initialized)
        try await runtime.start()
        #expect(await runtime.state() == .running)
        #expect(await transport.lifecycle == ["start", "install"])
        let expectedWill = RuntimeTransportLastWill(
            topic: "coaty/3/test/DAD/00000000-0000-0000-0000-000000000000",
            payload: Array("{\"objectIds\":[\"00000000-0000-0000-0000-000000000000\"]}".utf8)
        )
        #expect(await transport.lastWills == [expectedWill])
        let advertisement = try #require(await transport.firstSent())
        #expect(isAdvertiseRoute(advertisement.route))
        #expect(String(decoding: advertisement.payload, as: UTF8.self).contains("coaty.Identity"))

        await runtime.reconnect()
        #expect(await runtime.state() == .running)
        #expect(await transport.lifecycle == [
            "start", "install", "remove", "stop", "start", "install"
        ])
        #expect(await transport.lastWills == [expectedWill, expectedWill])

        await runtime.stop()
        #expect(await runtime.state() == .stopped)
        let lifecycle = await transport.lifecycle
        #expect(Array(lifecycle.suffix(2)) == ["remove", "stop"])
        let deadvertisement = try #require(await transport.lastSent())
        #expect(isDeadvertiseRoute(deadvertisement.route))
        #expect(String(decoding: deadvertisement.payload, as: UTF8.self) == "{\"objectIds\":[\"00000000-0000-0000-0000-000000000000\"]}")
    }

    @Test("runtime without an identity does not configure a transport last will")
    func lifecycleWithoutIdentityOmitsLastWill() async throws {
        let transport = TestTransport()
        let runtime = AxolotyRuntime(definition: try makeDefinition(), transport: transport)

        try await runtime.start()
        #expect(await transport.lastWills == [nil])
        await runtime.stop()
    }

    @Test("closed runtime reports terminally stopped through modern state")
    func closedRuntimeReportsStoppedState() async throws {
        let runtime = AxolotyRuntime(definition: try makeDefinition(), transport: TestTransport())
        try await runtime.start()

        await runtime.close()

        #expect(await runtime.lifecycleState() == .closed)
        #expect(await runtime.state() == .stopped)
    }

    @Test("startup failure injection preserves terminal cleanup", arguments: SetupFailureStage.allCases)
    func startupFailureInjectionPreservesTerminalCleanup(stage: SetupFailureStage) async throws {
        let transport = TestTransport(failing: stage)
        let identity = try RuntimeIdentity(id: .zero, name: "failure-injection")
        let definition = try RuntimeBuilder(
            sourceID: .zero,
            namespace: "test",
            identity: identity,
            capacities: try RuntimeCapacities()
        ).finish()
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

    @Test("transport failure callbacks receive owned typed values")
    func transportFailureCallbackUsesOwnedValue() async throws {
        final class FailureBox: @unchecked Sendable {
            private let lock = NSLock()
            private var stored: RuntimeTransportFailure?
            func store(_ failure: RuntimeTransportFailure) {
                lock.withLock { stored = failure }
            }
            func current() -> RuntimeTransportFailure? {
                lock.withLock { stored }
            }
        }
        let box = FailureBox()
        let transport = TestTransport()
        await transport.setFailureHandler { failure in
            box.store(failure)
        }

        await transport.fail(AxolotyError.runtime(code: .brokerUnavailable, reason: "typed transport failure"))

        try await waitUntil("typed transport failure arrives") {
            box.current() != nil
        }
        let failure = try #require(box.current())
        #expect(failure.code == .brokerUnavailable)
        #expect(failure.detail == "typed transport failure")
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
