// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Testing
@testable import Axoloty

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
