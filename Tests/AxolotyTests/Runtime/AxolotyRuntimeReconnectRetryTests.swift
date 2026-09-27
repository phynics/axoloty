// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Testing
@testable import Axoloty
import AxolotyTestSupport

/// A transport whose `start(receive:)` fails a fixed number of times after the
/// first successful start, standing in for a broker that has restarted but is
/// not yet accepting connections.
actor RestartingBrokerTransport: AxolotyRuntimeTransport {
    private var startCount = 0
    private let failedReconnects: Int

    init(failedReconnects: Int) {
        self.failedReconnects = failedReconnects
    }

    func start(receive: @escaping @Sendable (RuntimeInboundFrame) -> Void) async throws {
        startCount += 1
        // The first start brings the runtime up; the next `failedReconnects`
        // starts are reconnect attempts that lose the race against a broker
        // still coming back.
        if startCount > 1, startCount <= failedReconnects + 1 {
            throw TestTransportFailure()
        }
    }

    func perform(_ effect: RuntimeTransportEffect) async throws {}
    func stop() async {}

    func startAttempts() -> Int { startCount }
}

extension AxolotyRuntimeTests {
    @Test("soft recovery drains pumps before replacing them during an explicit reconnect")
    func softRecoveryRacingExplicitReconnectDrainsExistingPumps() async throws {
        let transport = TestTransport()
        let runtime = AxolotyRuntime(definition: try makeDefinition(), transport: transport)
        try await runtime.start()
        await transport.failNextPublication()

        #expect(await runtime.publish(.channel(
            identifier: "retained-effect",
            payload: Array(#"{"privateData":{"retained":true}}"#.utf8)
        )) == .accepted)
        try await waitUntil("failed outbound effect to enter reconnecting state") {
            await runtime.state() == .reconnecting
        }
        let retainedAttempt = try #require(await transport.lastSent())
        #expect(await transport.deliveredMessages().isEmpty)

        #expect(await runtime.publish(.advertise(
            Array(#"{"object":{"objectId":"66666666-6666-4666-8666-666666666666","coreType":"CoatyObject","objectType":"com.coaty.test.WireQueuedFixture","name":"race-recovery"}}"#.utf8)
        )) == .accepted)

        await transport.blockNextStart()
        let explicitReconnect = Task { await runtime.reconnect() }
        try await waitUntil("explicit reconnect transport start to block") {
            await transport.waitingForStart()
        }

        // A fresh loss/recovery notification lands while explicit reconnect's
        // ingress and outbound pumps are installed and its start is suspended.
        await transport.fail(TestTransportFailure())
        await transport.recover()
        try await waitUntil("soft recovery to replay retained and offline effects") {
            let state = await runtime.state()
            let delivered = await transport.deliveredMessages()
            return state == .running && delivered.count == 3
        }

        let recoveredMessages = await transport.deliveredMessages()
        #expect(recoveredMessages.filter { $0 == retainedAttempt }.count == 1)
        #expect(recoveredMessages.filter { isAdvertiseRoute($0.route) }.count == 2)

        // A single post-recovery receive must be consumed once by the new
        // bounded ingress pump, with the superseded pump fully drained.
        await transport.deliver(.profile(route: "bad//route", payload: [1], nowMS: 1))
        try await waitUntil("one post-recovery frame to reach the runtime") {
            (await runtime.diagnosticsSnapshot()).malformedFrames == 1
        }
        await transport.releaseStart()
        await explicitReconnect.value
        try await Task.sleep(for: .milliseconds(20))

        #expect(await runtime.state() == .running)
        #expect(await runtime.diagnosticsSnapshot().malformedFrames == 1)
        #expect(await runtime.diagnosticsSnapshot().dispatchSaturation == 0)
        #expect((await transport.lifecycle).filter { $0 == "start" }.count == 2)
        #expect((await transport.lifecycle).filter { $0 == "stop" }.count == 1)
        #expect(await transport.deliveredMessages().count == 3)
        await runtime.stop()
    }

    @Test("a reconnect that cannot reach the broker stays retryable instead of ending the runtime")
    func failedReconnectRemainsRetryable() async throws {
        let transport = RestartingBrokerTransport(failedReconnects: 1)
        let runtime = AxolotyRuntime(definition: try makeDefinition(), transport: transport)
        try await runtime.start()
        #expect(await runtime.state() == .running)

        // The broker is not accepting connections yet, so this attempt fails.
        await runtime.reconnect()
        let afterFailure = await runtime.state()
        // Recovery must stay recoverable. Failing the runtime here -- what
        // `failRuntime` did -- tore the instance down on the first missed
        // attempt and made every later `reconnect()` a no-op, so assert the
        // terminal states explicitly rather than only the expected one.
        #expect(afterFailure == .reconnecting)
        #expect(afterFailure != .failed)
        #expect(afterFailure != .stopped)

        // The caller owns retry; the runtime must still be able to honour it.
        await runtime.reconnect()
        #expect(await runtime.state() == .running)
        #expect(await transport.startAttempts() == 3)

        await runtime.stop()
    }

    @Test("a failed reconnect reports the attempt without a terminal failure")
    func failedReconnectReportsDiagnostic() async throws {
        let transport = RestartingBrokerTransport(failedReconnects: 1)
        let runtime = AxolotyRuntime(definition: try makeDefinition(), transport: transport)
        try await runtime.start()
        let before = await runtime.diagnosticsSnapshot().transportFailures

        await runtime.reconnect()

        let after = await runtime.diagnosticsSnapshot().transportFailures
        #expect(after > before)
        #expect(await runtime.state() == .reconnecting)

        await runtime.stop()
    }
}
