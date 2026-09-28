// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Testing
@testable import Axoloty
import AxolotyObjectModel
import AxolotyProtocol
import AxolotyTestSupport
import AxolotyWire
import Foundation

extension AxolotyRuntimeTests {
    @Test("transport counter surface is bounded and carrier-neutral")
    func transportCounterSurfaceIsNeutral() {
        let counters = RuntimeTransportCounters()
        let names = Mirror(reflecting: counters).children.compactMap(\.label)
        let forbidden = ["mqtt", "zenoh", "broker", "router", "topic", "key-expression"]

        #expect(names.sorted() == [
            "activeExternalSubscriptions", "oversizedSamples", "publishedFrames",
            "receiveDrops", "receivedFrames", "reconnects", "sessionFailures", "sessionOpens",
        ].sorted())
        #expect(!names.contains { name in forbidden.contains { name.localizedCaseInsensitiveContains($0) } })
    }

    @Test("runtime snapshot includes transport counters")
    func runtimeSnapshotIncludesTransportCounters() async throws {
        let transport = TestTransport()
        let sourceID = "00000000-0000-4000-8000-000000000801"
        let actorID = "00000000-0000-4000-8000-000000000802"
        let sourceMetadata: StaticString = "{\"objectId\":\"00000000-0000-4000-8000-000000000801\",\"objectType\":\"coaty.IoSource\",\"name\":\"counter-source\",\"coreType\":\"IoSource\",\"valueType\":\"com.example.Bool\"}"
        let actorMetadata: StaticString = "{\"objectId\":\"00000000-0000-4000-8000-000000000802\",\"objectType\":\"coaty.IoActor\",\"name\":\"counter-actor\",\"coreType\":\"IoActor\",\"valueType\":\"com.example.Bool\"}"
        var builder = try RuntimeBuilder(sourceID: .zero, namespace: "test")
        let source: IoSource<Bool> = try builder.ioSource(
            metadata: Object<IoSourceMetadata>(decoding: ByteSlice(
                bytes: sourceMetadata.utf8Start,
                length: sourceMetadata.utf8CodeUnitCount
            )),
            as: Bool.self,
            externalRoute: try ExternalIoRoute("counter/external")
        )
        _ = try builder.ioActor(
            metadata: Object<IoActorMetadata>(decoding: ByteSlice(
                bytes: actorMetadata.utf8Start,
                length: actorMetadata.utf8CodeUnitCount
            )),
            as: Bool.self
        ) { _, _ in }
        let runtime = AxolotyRuntime(definition: try builder.finish(), transport: transport)

        try await runtime.start()
        let startupPublications = await transport.sentCount()
        #expect(await runtime.publish(.channel(
            identifier: "counter-publication",
            payload: Array(#"{"privateData":{"counter":true}}"#.utf8)
        )) == .accepted)
        try await waitUntil("counter publication to reach the transport") {
            await transport.sentCount() > startupPublications
        }
        await transport.deliver(.profile(
            route: "coaty/3/test/ASC/\(sourceID)",
            payload: Array("{\"ioSourceId\":\"\(sourceID)\",\"ioActorId\":\"\(actorID)\",\"associatingRoute\":\"counter/external\"}".utf8),
            nowMS: 1
        ))
        try await waitUntil("external subscription to activate") {
            try await runtime.io.state(of: source).hasAssociations
        }
        var ignoredPayload: [UInt8] = [1]
        await transport.inject(route: "unrelated/route", payload: &ignoredPayload)
        await transport.rejectOversizedSample()
        let activeSnapshot = await runtime.diagnosticsSnapshot()

        #expect(activeSnapshot.sessionOpens == 1)
        #expect(activeSnapshot.publishedFrames == UInt64(startupPublications + 1))
        #expect(activeSnapshot.receivedFrames == 1)
        #expect(activeSnapshot.receiveDrops == 1)
        #expect(activeSnapshot.oversizedSamples == 1)
        #expect(activeSnapshot.activeExternalSubscriptions == 1)

        await transport.fail(TestTransportFailure())
        try await waitUntil("runtime to enter reconnecting state") {
            await runtime.state() == .reconnecting
        }
        await runtime.reconnect()
        let recoveredSnapshot = await runtime.diagnosticsSnapshot()
        #expect(recoveredSnapshot.sessionFailures == 1)
        #expect(recoveredSnapshot.transportReconnects == 1)
        #expect(recoveredSnapshot.sessionOpens == 2)
        await runtime.stop()
    }

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
        #expect(await transport.lifecycle == ["start", "activate"])
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
            "start", "activate", "deactivate", "stop", "start", "activate"
        ])
        #expect(await transport.lastWills == [expectedWill, expectedWill])

        await runtime.stop()
        #expect(await runtime.state() == .stopped)
        let lifecycle = await transport.lifecycle
        #expect(Array(lifecycle.suffix(2)) == ["deactivate", "stop"])
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

    @Test("closed runtime preserves its terminal state through modern state")
    func closedRuntimeReportsClosedState() async throws {
        let runtime = AxolotyRuntime(definition: try makeDefinition(), transport: TestTransport())
        try await runtime.start()

        await runtime.close()

        #expect(await runtime.lifecycleState() == .closed)
        #expect(await runtime.state() == .closed)
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

    @Test("soft transport recovery resumes queued work without restarting the transport")
    func softTransportRecoveryResumesOfflineOperations() async throws {
        let transport = TestTransport()
        let runtime = AxolotyRuntime(definition: try makeDefinition(), transport: transport)
        try await runtime.start()
        let initialLifecycle = await transport.lifecycle
        let initialStarts = initialLifecycle.filter { $0 == "start" }.count
        let initialStops = initialLifecycle.filter { $0 == "stop" }.count

        await transport.fail(TestTransportFailure())
        try await waitUntil("runtime to enter reconnecting state") {
            await runtime.state() == .reconnecting
        }
        let receipt = await runtime.publish(.advertise(
            Array(#"{"object":{"objectId":"66666666-6666-4666-8666-666666666666","coreType":"CoatyObject","objectType":"com.coaty.test.WireQueuedFixture","name":"soft-recovery"}}"#.utf8)
        ))
        #expect(receipt == .accepted)
        #expect(await transport.sentCount() == 0)

        await transport.recover()
        try await waitUntil("soft recovery to resume and flush queued operations") {
            let state = await runtime.state()
            let sentCount = await transport.sentCount()
            return state == .running && sentCount == 2
        }

        let recoveredLifecycle = await transport.lifecycle
        #expect(recoveredLifecycle.filter { $0 == "start" }.count == initialStarts)
        #expect(recoveredLifecycle.filter { $0 == "stop" }.count == initialStops)
        #expect(await transport.sentCount() == 2)
        await runtime.stop()
    }

    @Test("soft recovery releases active exact external routes on the retained transport")
    func softRecoveryReleasesActiveExternalRoutes() async throws {
        let transport = TestTransport()
        let sourceID = "00000000-0000-4000-8000-000000000811"
        let actorMetadata: StaticString = "{\"objectId\":\"00000000-0000-4000-8000-000000000812\",\"objectType\":\"coaty.IoActor\",\"name\":\"recovery-actor\",\"coreType\":\"IoActor\",\"valueType\":\"com.example.Bool\"}"
        var builder = try RuntimeBuilder(sourceID: .zero, namespace: "test")
        _ = try builder.ioActor(
            metadata: Object<IoActorMetadata>(decoding: ByteSlice(
                bytes: actorMetadata.utf8Start,
                length: actorMetadata.utf8CodeUnitCount
            )),
            as: Bool.self
        ) { _, _ in }
        let runtime = AxolotyRuntime(definition: try builder.finish(), transport: transport)
        try await runtime.start()

        for cycle in 0..<3 {
            let route = "recovery/external/\(cycle)"
            await transport.deliver(.profile(
                route: "coaty/3/test/ASC/\(sourceID)",
                payload: Array("{\"ioSourceId\":\"\(sourceID)\",\"ioActorId\":\"00000000-0000-4000-8000-000000000812\",\"associatingRoute\":\"\(route)\"}".utf8),
                nowMS: 1
            ))
            try await waitUntil("external route \(cycle) to activate") {
                await transport.externalSubscriptions().last == route
            }
            await transport.fail(TestTransportFailure())
            try await waitUntil("runtime to enter reconnecting state") {
                await runtime.state() == .reconnecting
            }
            await transport.recover()
            try await waitUntil("soft recovery to release the route and resume") {
                let released = await transport.externalUnsubscriptions().last == route
                let state = await runtime.state()
                return released && state == .running
            }
            #expect(await runtime.diagnosticsSnapshot().activeExternalSubscriptions == 0)
        }
        #expect(await transport.externalSubscriptions().count == 3)
        #expect(await transport.externalUnsubscriptions().count == 3)
        #expect(await transport.lifecycle.filter { $0 == "stop" }.isEmpty)
        await runtime.stop()
    }

    @Test("reconnect drains offline publications after replay frees dispatch capacity")
    func reconnectDrainsOfflinePublicationsAfterReplayFreesCapacity() async throws {
        let definition = try RuntimeBuilder(
            sourceID: .zero,
            namespace: "test",
            capacities: try RuntimeCapacities(dispatch: 1)
        ).finish()
        let transport = TestTransport()
        let runtime = AxolotyRuntime(definition: definition, transport: transport)
        try await runtime.start()
        await transport.failNextPublication()

        let firstPayload = Array(#"{"privateData":{"publication":1}}"#.utf8)
        #expect(await runtime.publish(.channel(identifier: "first", payload: firstPayload)) == .accepted)
        try await waitUntil("failed publication to enter reconnecting state") {
            await runtime.state() == .reconnecting
        }

        let secondPayload = Array(#"{"privateData":{"publication":2}}"#.utf8)
        #expect(await runtime.publish(.channel(identifier: "second", payload: secondPayload)) == .accepted)
        await runtime.reconnect()

        try await waitUntil("replay and offline publication to be delivered") {
            await transport.deliveredMessages().count == 2
        }
        #expect(await transport.deliveredMessages().map(\.payload) == [firstPayload, secondPayload])
        await runtime.stop()
    }

    @Test("soft recovery drains offline publications after replay frees dispatch capacity")
    func softRecoveryDrainsOfflinePublicationsAfterReplayFreesCapacity() async throws {
        let definition = try RuntimeBuilder(
            sourceID: .zero,
            namespace: "test",
            capacities: try RuntimeCapacities(dispatch: 1)
        ).finish()
        let transport = TestTransport()
        let runtime = AxolotyRuntime(definition: definition, transport: transport)
        try await runtime.start()
        await transport.failNextPublication()

        let firstPayload = Array(#"{"privateData":{"publication":1}}"#.utf8)
        #expect(await runtime.publish(.channel(identifier: "first", payload: firstPayload)) == .accepted)
        try await waitUntil("failed publication to enter reconnecting state") {
            await runtime.state() == .reconnecting
        }

        let secondPayload = Array(#"{"privateData":{"publication":2}}"#.utf8)
        #expect(await runtime.publish(.channel(identifier: "second", payload: secondPayload)) == .accepted)
        await transport.recover()

        try await waitUntil("soft recovery replay and offline publication to be delivered") {
            let state = await runtime.state()
            let deliveredCount = await transport.deliveredMessages().count
            return state == .running && deliveredCount == 2
        }
        #expect(await transport.deliveredMessages().map(\.payload) == [firstPayload, secondPayload])
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

    @Test("runtime shutdown shields transport cleanup from caller cancellation")
    func shutdownShieldsTransportCleanup() async throws {
        let identity = try RuntimeIdentity(id: .zero, name: "shield-stop")
        let definition = try RuntimeBuilder(
            sourceID: .zero,
            namespace: "test",
            identity: identity,
            capacities: try RuntimeCapacities()
        ).finish()
        let transport = TestTransport()
        let runtime = AxolotyRuntime(definition: definition, transport: transport)
        try await runtime.start()

        let stopping = Task { await runtime.stop() }
        stopping.cancel()
        await stopping.value

        #expect(await runtime.state() == .stopped)
        #expect(await transport.stopObservedCancellation == false)
        #expect(Array((await transport.lifecycle).suffix(2)) == ["deactivate", "stop"])
        let deadvertisement = try #require(await transport.lastSent())
        #expect(isDeadvertiseRoute(deadvertisement.route))
    }

    @Test("cancellation after a transport failure still runs shutdown cleanup")
    func transportFailureCancellationStillCleansUp() async throws {
        let identity = try RuntimeIdentity(id: .zero, name: "failure-cancel")
        let definition = try RuntimeBuilder(
            sourceID: .zero,
            namespace: "test",
            identity: identity,
            capacities: try RuntimeCapacities()
        ).finish()
        let transport = TestTransport()
        let runtime = AxolotyRuntime(definition: definition, transport: transport)
        let running = Task { try await runtime.run() }
        try await waitUntil("runtime to start before transport failure") {
            await runtime.state() == .running
        }

        await transport.fail(TestTransportFailure())
        try await waitUntil("runtime to enter reconnecting after transport failure") {
            await runtime.state() == .reconnecting
        }

        running.cancel()
        do {
            try await running.value
        } catch {
            Issue.record("run propagated cancellation after performing its shutdown: \(error)")
        }

        #expect(await runtime.state() == .stopped)
        #expect(await transport.stopObservedCancellation == false)
        #expect(Array((await transport.lifecycle).suffix(2)) == ["deactivate", "stop"])
    }
}
