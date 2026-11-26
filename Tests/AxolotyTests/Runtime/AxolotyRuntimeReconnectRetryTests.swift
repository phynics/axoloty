// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Testing
@testable import Axoloty
import AxolotyTestSupport

/// A transport whose `start(receive:)` fails a fixed number of times after the
/// first successful start, standing in for a broker that has restarted but is
/// not yet accepting connections.
actor RestartingBrokerTransport: AxolotyRuntimeTransport {
    nonisolated var capabilities: RuntimeTransportCapabilities { [] }
    private var startCount = 0
    private let failedReconnects: Int

    init(failedReconnects: Int) {
        self.failedReconnects = failedReconnects
    }

    func start(
        receive: @escaping @Sendable (RuntimeInboundFrame) -> Void,
        lastWill: RuntimeTransportLastWill?
    ) async throws(AxolotyError) {
        _ = (receive, lastWill)
        startCount += 1
        // The first start brings the runtime up; the next `failedReconnects`
        // starts are reconnect attempts that lose the race against a broker
        // still coming back.
        if startCount > 1, startCount <= failedReconnects + 1 {
            throw AxolotyError.network(error: TestTransportFailure(), reason: "test reconnect failed")
        }
    }

    func setFailureHandler(_ handler: @escaping @Sendable (RuntimeTransportFailure) -> Void) async { _ = handler }
    func perform(_ effect: RuntimeTransportEffect) async throws(AxolotyError) { _ = effect }
    func stop() async {}

    func startAttempts() -> Int { startCount }
}

/// A transport that suspends the first reconnect deactivation so a test can
/// stop the runtime while a reconnect is waiting to call `start()` again.
actor BlockingDeactivationTransport: AxolotyRuntimeTransport {
    nonisolated var capabilities: RuntimeTransportCapabilities { [] }
    private var startCount = 0
    private var stopCount = 0
    private var shouldBlockNextDeactivation = false
    private var deactivationWaiters: [CheckedContinuation<Void, Never>] = []
    private var blockedDeactivation: CheckedContinuation<Void, Never>?

    func blockNextDeactivation() { shouldBlockNextDeactivation = true }

    func start(
        receive: @escaping @Sendable (RuntimeInboundFrame) -> Void,
        lastWill: RuntimeTransportLastWill?
    ) async throws(AxolotyError) {
        _ = (receive, lastWill)
        startCount += 1
    }

    func setFailureHandler(_ handler: @escaping @Sendable (RuntimeTransportFailure) -> Void) async { _ = handler }
    func setRecoveryHandler(_ handler: @escaping @Sendable () -> Void) async { _ = handler }
    func perform(_ effect: RuntimeTransportEffect) async throws(AxolotyError) { _ = effect }

    func stop() async {
        stopCount += 1
    }

    func activateProfileInterest(namespace: String) async throws(AxolotyError) { _ = namespace }

    func deactivateProfileInterest(namespace: String) async throws(AxolotyError) {
        _ = namespace
        guard shouldBlockNextDeactivation else { return }
        shouldBlockNextDeactivation = false
        await withCheckedContinuation { continuation in
            blockedDeactivation = continuation
            let waiters = deactivationWaiters
            deactivationWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
    }

    func waitForBlockedDeactivation() async {
        if blockedDeactivation != nil { return }
        await withCheckedContinuation { continuation in
            if blockedDeactivation != nil {
                continuation.resume()
            } else {
                deactivationWaiters.append(continuation)
            }
        }
    }

    func releaseDeactivation() {
        blockedDeactivation?.resume()
        blockedDeactivation = nil
    }

    func startAttempts() -> Int { startCount }
    func stopAttempts() -> Int { stopCount }
}

/// A transport that suspends recovery-callback installation so a test can stop
/// the runtime before the initial start reaches `transport.start()`.
actor BlockingStartInstallTransport: AxolotyRuntimeTransport {
    nonisolated var capabilities: RuntimeTransportCapabilities { [] }
    private var startCount = 0
    private var stopCount = 0
    private var shouldBlockRecoveryInstall = false
    private var installWaiters: [CheckedContinuation<Void, Never>] = []
    private var blockedInstall: CheckedContinuation<Void, Never>?

    func blockNextRecoveryInstall() { shouldBlockRecoveryInstall = true }

    func start(
        receive: @escaping @Sendable (RuntimeInboundFrame) -> Void,
        lastWill: RuntimeTransportLastWill?
    ) async throws(AxolotyError) {
        _ = (receive, lastWill)
        startCount += 1
    }

    func setFailureHandler(_ handler: @escaping @Sendable (RuntimeTransportFailure) -> Void) async { _ = handler }

    func setRecoveryHandler(_ handler: @escaping @Sendable () -> Void) async {
        _ = handler
        guard shouldBlockRecoveryInstall else { return }
        shouldBlockRecoveryInstall = false
        await withCheckedContinuation { continuation in
            blockedInstall = continuation
            let waiters = installWaiters
            installWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
    }

    func perform(_ effect: RuntimeTransportEffect) async throws(AxolotyError) { _ = effect }

    func stop() async {
        stopCount += 1
    }

    func activateProfileInterest(namespace: String) async throws(AxolotyError) { _ = namespace }
    func deactivateProfileInterest(namespace: String) async throws(AxolotyError) { _ = namespace }

    func waitForBlockedInstall() async {
        if blockedInstall != nil { return }
        await withCheckedContinuation { continuation in
            if blockedInstall != nil {
                continuation.resume()
            } else {
                installWaiters.append(continuation)
            }
        }
    }

    func releaseInstall() {
        blockedInstall?.resume()
        blockedInstall = nil
    }

    func startAttempts() -> Int { startCount }
    func stopAttempts() -> Int { stopCount }
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

    @Test("a cancelled reconnect closes the transport it opened and stays retryable")
    func cancelledReconnectClosesTransportAndStaysRetryable() async throws {
        let transport = TestTransport()
        let runtime = AxolotyRuntime(definition: try makeDefinition(), transport: transport)
        try await runtime.start()

        await transport.blockNextStart()
        let attempt = Task { await runtime.reconnect() }
        try await waitUntil("reconnect transport start to block") {
            await transport.waitingForStart()
        }
        attempt.cancel()
        await transport.releaseStart()
        await attempt.value

        // A cancelled attempt must not leave the connection it opened running,
        // and it must not complete the recovery.
        #expect(await runtime.state() == .reconnecting)
        #expect((await transport.lifecycle).filter { $0 == "start" }.count == 2)
        #expect((await transport.lifecycle).filter { $0 == "stop" }.count == 2)

        // The caller can retry the same runtime after cancelling.
        await runtime.reconnect()
        #expect(await runtime.state() == .running)
        #expect((await transport.lifecycle).filter { $0 == "start" }.count == 3)
        await runtime.stop()
    }

    @Test("a stop during initial start never opens a connection")
    func stopDuringInitialStartPreventsConnection() async throws {
        let transport = BlockingStartInstallTransport()
        let runtime = AxolotyRuntime(definition: try makeDefinition(), transport: transport)
        await transport.blockNextRecoveryInstall()

        let start = Task { () -> Bool in
            do {
                try await runtime.start()
                return false
            } catch {
                return true
            }
        }
        try await waitUntil("start callback installation to block") {
            await transport.waitForBlockedInstall()
            return true
        }

        await runtime.stop()
        #expect(await runtime.state() == .stopped)

        await transport.releaseInstall()
        #expect(await start.value)
        #expect(await transport.startAttempts() == 0)
        #expect(await transport.stopAttempts() == 1)
    }

    @Test("a reconnect suspended before start never opens a connection after stop")
    func stopBeforeReconnectStartPreventsNewConnection() async throws {
        let transport = BlockingDeactivationTransport()
        let runtime = AxolotyRuntime(definition: try makeDefinition(), transport: transport)
        try await runtime.start()

        await transport.blockNextDeactivation()
        let attempt = Task { await runtime.reconnect() }
        try await waitUntil("reconnect deactivation to block") {
            await transport.waitForBlockedDeactivation()
            return true
        }

        // Stop completes while the reconnect is suspended before its start.
        await runtime.stop()
        #expect(await runtime.state() == .stopped)

        await transport.releaseDeactivation()
        await attempt.value

        // The stopped host must not get a new connection from the old attempt.
        #expect(await transport.startAttempts() == 1)
        #expect(await transport.stopAttempts() == 1)
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
