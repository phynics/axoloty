// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
@_spi(AxolotyRuntimeAdapter) import AxolotyProtocol
import Foundation
import Testing

/// A host test fixture that exposes transport observations without exposing
/// carrier implementation details to the shared contract assertions.
public protocol RuntimeTransportContractFixture: Sendable {
    /// The transport under test.
    var transport: any AxolotyRuntimeTransport { get }

    /// Starts or restarts the transport and installs the receive callback.
    func start(receive: @escaping @Sendable (RuntimeInboundFrame) -> Void) async throws
    /// Returns routes observed as profile-interest subscriptions.
    func profileSubscriptions() async -> [String]
    /// Returns routes observed as profile-interest unsubscriptions.
    func profileUnsubscriptions() async -> [String]
    /// Returns exact external routes activated by the runtime.
    func externalSubscriptions() async -> [String]
    /// Returns exact external routes deactivated by the runtime.
    func externalUnsubscriptions() async -> [String]
    /// Returns outbound messages observed by the fixture.
    func publications() async -> [RuntimeOutboundMessage]
    /// Injects one inbound frame, then mutates the fixture's source bytes.
    ///
    /// - Parameters:
    ///   - route: Exact inbound route.
    ///   - payload: Source storage changed after the injection call.
    func inject(route: String, payload: inout [UInt8]) async
    /// Drains any explicitly queued inbound work without waiting for a timer.
    func drainInbound() async
    /// Causes the transport to invoke its installed failure callback.
    func reportFailure() async
    /// Returns the number of starts completed by the fixture.
    func startCount() async -> Int
}

/// Runs the transport behavior contract against one carrier-neutral fixture.
///
/// Call this from a Swift Testing test in each adapter package. The fixture
/// owns carrier selection, while these assertions cover only the runtime port.
///
/// - Parameter fixture: An initialized fixture for one transport adapter.
/// - Throws: The transport's startup or operation error.
public func runRuntimeTransportContract(
    using fixture: any RuntimeTransportContractFixture
) async throws {
    let received = ContractFrameRecorder()
    let failures = ContractFailureRecorder()
    let diagnostics = RuntimeTransportDiagnostics()
    await fixture.transport.setDiagnostics(diagnostics)
    await fixture.transport.setFailureHandler { failures.append($0) }

    try await fixture.start { received.append($0) }
    let initialStartCount = await fixture.startCount()
    #expect(initialStartCount == 1)

    let namespace = "contract-node"
    try await fixture.transport.activateProfileInterest(namespace: namespace)
    let initialProfileSubscriptions = await fixture.profileSubscriptions()
    #expect(initialProfileSubscriptions == [
        "coaty/3/\(namespace)/*/*",
        "coaty/3/\(namespace)/*/*/*",
    ])

    let externalRoute = "contract/external/value"
    let transition = OwnedExternalRouteTransition(sourceID: .zero, actorID: .zero, route: Array(externalRoute.utf8))
    try await fixture.transport.perform(.externalRouteActivated(transition))
    let activatedExternalRoutes = await fixture.externalSubscriptions()
    #expect(activatedExternalRoutes == [externalRoute])
    #expect(diagnostics.snapshot().activeExternalSubscriptions == 1)

    let outbound = RuntimeOutboundMessage(route: "coaty/3/\(namespace)/ADV/source", payload: [1, 2, 3])
    try await fixture.transport.perform(.publish(outbound))
    let publications = await fixture.publications()
    #expect(publications == [outbound])

    let profileRoute = "coaty/3/\(namespace)/IOV/00000000-0000-4000-8000-000000000001"
    var profilePayload = [UInt8(4), 5, 6]
    await fixture.inject(route: profileRoute, payload: &profilePayload)
    var externalPayload = [UInt8(7), 8, 9]
    await fixture.inject(route: externalRoute, payload: &externalPayload)
    #expect(profilePayload == [0, 0, 0])
    #expect(externalPayload == [0, 0, 0])
    await fixture.drainInbound()
    let delivered = received.snapshot()
    #expect(delivered.count == 2)
    #expect(delivered.first.map { isFrame($0, route: profileRoute, payload: [4, 5, 6], profile: true) } == true)
    #expect(delivered.last.map { isFrame($0, route: externalRoute, payload: [7, 8, 9], profile: false) } == true)

    try await fixture.transport.perform(.externalRouteDeactivated(transition))
    let deactivatedExternalRoutes = await fixture.externalUnsubscriptions()
    #expect(deactivatedExternalRoutes == [externalRoute])
    #expect(diagnostics.snapshot().activeExternalSubscriptions == 0)
    let frameCountAfterDeactivation = received.snapshot().count
    var latePayload = [UInt8(10)]
    await fixture.inject(route: externalRoute, payload: &latePayload)
    await fixture.drainInbound()
    #expect(received.snapshot().count == frameCountAfterDeactivation)

    await fixture.reportFailure()
    #expect(failures.snapshot().count == 1)
    #expect(failures.snapshot().first?.code == .brokerUnavailable)
    #expect(diagnostics.snapshot().sessionFailures == 1)

    let profileUnsubscriptionsBeforeStop = await fixture.profileUnsubscriptions()
    await fixture.transport.stop()
    let profileUnsubscriptionsAfterStop = await fixture.profileUnsubscriptions()
    #expect(profileUnsubscriptionsAfterStop == profileUnsubscriptionsBeforeStop)
    try await fixture.start { received.append($0) }
    let restartCount = await fixture.startCount()
    #expect(restartCount == 2)
    #expect(diagnostics.snapshot().sessionOpens == 2)
    #expect(diagnostics.snapshot().reconnects == 1)
    try await fixture.transport.activateProfileInterest(namespace: namespace)
    let subscriptionsAfterRestart = await fixture.profileSubscriptions()
    #expect(subscriptionsAfterRestart.suffix(2).elementsEqual([
        "coaty/3/\(namespace)/*/*",
        "coaty/3/\(namespace)/*/*/*",
    ]))
    await fixture.transport.stop()
}

private func isFrame(_ frame: RuntimeInboundFrame, route: String, payload: [UInt8], profile: Bool) -> Bool {
    switch frame {
    case let .profile(actualRoute, actualPayload, _):
        profile && actualRoute == route && actualPayload == payload
    case let .externalIo(actualRoute, actualPayload, _):
        !profile && actualRoute == route && actualPayload == payload
    }
}

private final class ContractFrameRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [RuntimeInboundFrame] = []

    func append(_ frame: RuntimeInboundFrame) {
        lock.lock()
        frames.append(frame)
        lock.unlock()
    }

    func snapshot() -> [RuntimeInboundFrame] {
        lock.lock()
        defer { lock.unlock() }
        return frames
    }
}

private final class ContractFailureRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var failures: [RuntimeTransportFailure] = []

    func append(_ failure: RuntimeTransportFailure) {
        lock.lock()
        failures.append(failure)
        lock.unlock()
    }

    func snapshot() -> [RuntimeTransportFailure] {
        lock.lock()
        defer { lock.unlock() }
        return failures
    }
}
