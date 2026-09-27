// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Testing
@testable import Axoloty
import AxolotyObjectModel
import AxolotyProtocol
import AxolotyTransportContractTestSupport
import AxolotyTestSupport
import AxolotyWire

func makeDefinition() throws -> RuntimeDefinition {
    let builder = try RuntimeBuilder(
        sourceID: .zero,
        namespace: "test",
        capacities: try RuntimeCapacities()
    )
    return try builder.finish()
}
enum SetupFailureStage: String, CaseIterable, Sendable {
    case start
    case subscriptions
    case advertisement

    var expectedLifecycle: [String] {
        switch self {
        case .start:
            return ["start", "deactivate", "stop"]
        case .subscriptions:
            return ["start", "activate", "deactivate", "stop"]
        case .advertisement:
            return ["start", "activate", "deactivate", "stop"]
        }
    }
}

actor TestTransport: AxolotyRuntimeTransport, RuntimeTransportContractFixture {
    nonisolated var transport: any AxolotyRuntimeTransport { self }
    private var receive: (@Sendable (RuntimeInboundFrame) -> Void)?
    private var failure: (@Sendable (RuntimeTransportFailure) -> Void)?
    private var recovery: (@Sendable () -> Void)?
    private var transportDiagnostics: RuntimeTransportDiagnostics?
    private var sent: [RuntimeOutboundMessage] = []
    private var delivered: [RuntimeOutboundMessage] = []
    private(set) var lifecycle: [String] = []
    private(set) var contractProfileSubscriptions: [String] = []
    private(set) var contractProfileUnsubscriptions: [String] = []
    private(set) var contractExternalSubscriptions: [String] = []
    private(set) var contractExternalUnsubscriptions: [String] = []
    private(set) var lastWills: [RuntimeTransportLastWill?] = []
    private(set) var stopObservedCancellation = false
    private let failureStage: SetupFailureStage?
    private var shouldFailNextPublication = false
    private var shouldBlockNextStart = false
    private var isWaitingForStart = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var contractActiveNamespace: String?
    private var contractExternalRoutes: Set<String> = []
    private var contractStartCount = 0

    init(failing failureStage: SetupFailureStage? = nil) {
        self.failureStage = failureStage
    }

    func start(receive: @escaping @Sendable (RuntimeInboundFrame) -> Void) async throws {
        self.receive = receive
        contractStartCount += 1
        lifecycle.append("start")
        if failureStage == .start {
            transportDiagnostics?.recordSessionFailure()
            throw TestTransportFailure()
        }
        if contractStartCount > 1 { transportDiagnostics?.recordReconnect() }
        transportDiagnostics?.recordSessionOpen()
        guard shouldBlockNextStart else { return }
        shouldBlockNextStart = false
        await withCheckedContinuation { continuation in
            isWaitingForStart = true
            startWaiter = continuation
        }
        isWaitingForStart = false
    }

    func start(
        receive: @escaping @Sendable (RuntimeInboundFrame) -> Void,
        lastWill: RuntimeTransportLastWill?
    ) async throws {
        lastWills.append(lastWill)
        try await start(receive: receive)
    }

    func setFailureHandler(_ handler: @escaping @Sendable (RuntimeTransportFailure) -> Void) async {
        failure = handler
    }

    func setRecoveryHandler(_ handler: @escaping @Sendable () -> Void) async {
        recovery = handler
    }

    func setDiagnostics(_ diagnostics: RuntimeTransportDiagnostics) async {
        transportDiagnostics = diagnostics
    }

    func perform(_ effect: RuntimeTransportEffect) async throws {
        switch effect {
        case .publish(let message):
            sent.append(message)
            if shouldFailNextPublication {
                shouldFailNextPublication = false
                throw TestTransportFailure()
            }
            if failureStage == .advertisement, isAdvertiseRoute(message.route) {
                throw TestTransportFailure()
            }
            delivered.append(message)
            transportDiagnostics?.recordPublishedFrame()
        case .externalRouteActivated(let transition):
            let route = String(decoding: transition.route, as: UTF8.self)
            contractExternalRoutes.insert(route)
            transportDiagnostics?.setActiveExternalSubscriptions(UInt64(contractExternalRoutes.count))
            contractExternalSubscriptions.append(route)
        case .externalRouteDeactivated(let transition):
            let route = String(decoding: transition.route, as: UTF8.self)
            contractExternalRoutes.remove(route)
            transportDiagnostics?.setActiveExternalSubscriptions(UInt64(contractExternalRoutes.count))
            contractExternalUnsubscriptions.append(route)
        }
    }

    func stop() async {
        stopObservedCancellation = Task.isCancelled
        receive = nil
        lifecycle.append("stop")
    }

    func activateProfileInterest(namespace: String) async throws {
        lifecycle.append("activate")
        contractActiveNamespace = namespace
        contractProfileSubscriptions.append(contentsOf: [
            "coaty/3/\(namespace)/*/*",
            "coaty/3/\(namespace)/*/*/*",
        ])
        if failureStage == .subscriptions { throw TestTransportFailure() }
    }
    func deactivateProfileInterest(namespace: String) async throws {
        lifecycle.append("deactivate")
        contractProfileUnsubscriptions.append(contentsOf: [
            "coaty/3/\(namespace)/*/*",
            "coaty/3/\(namespace)/*/*/*",
        ])
        contractActiveNamespace = nil
    }

    nonisolated func classifyRoute(_ route: ByteSlice) -> ProtocolRouteClassification {
        let prefix: [UInt8] = [0x63, 0x6F, 0x61, 0x74, 0x79, 0x2F]
        let isCoatyRoute = route.length >= prefix.count
            && prefix.indices.allSatisfy { route.byte(at: $0) == prefix[$0] }
        return isCoatyRoute ? .coaty : .external
    }

    func profileSubscriptions() async -> [String] { contractProfileSubscriptions }
    func profileUnsubscriptions() async -> [String] { contractProfileUnsubscriptions }
    func externalSubscriptions() async -> [String] { contractExternalSubscriptions }
    func externalUnsubscriptions() async -> [String] { contractExternalUnsubscriptions }
    func publications() async -> [RuntimeOutboundMessage] { delivered }
    func startCount() async -> Int { contractStartCount }

    func inject(route: String, payload: inout [UInt8]) async {
        if route.hasPrefix("coaty/3/\(contractActiveNamespace ?? "<inactive>")/") {
            transportDiagnostics?.recordReceivedFrame()
            receive?(.profile(route: route, payload: payload, nowMS: 0))
        } else if contractExternalRoutes.contains(route) {
            transportDiagnostics?.recordReceivedFrame()
            receive?(.externalIo(route: route, payload: payload, nowMS: 0))
        } else {
            transportDiagnostics?.recordReceiveDrop()
        }
        payload = Array(repeating: 0, count: payload.count)
    }

    func drainInbound() async {}

    func reportFailure() async {
        transportDiagnostics?.recordSessionFailure()
        failure?(RuntimeTransportFailure(code: .brokerUnavailable, detail: "contract failure"))
    }

    func sentCount() -> Int { sent.count }
    func firstSent() -> RuntimeOutboundMessage? { sent.first }
    func lastSent() -> RuntimeOutboundMessage? { sent.last }
    func deliveredMessages() -> [RuntimeOutboundMessage] { delivered }

    func failNextPublication() { shouldFailNextPublication = true }
    func blockNextStart() { shouldBlockNextStart = true }
    func waitingForStart() -> Bool { isWaitingForStart }
    func releaseStart() {
        startWaiter?.resume()
        startWaiter = nil
    }

    /// Simulates a wire frame arriving on the currently installed transport
    /// callback, exactly as a real transport implementation would invoke it.
    func deliver(_ frame: RuntimeInboundFrame) {
        transportDiagnostics?.recordReceivedFrame()
        receive?(frame)
    }

    func rejectOversizedSample() {
        transportDiagnostics?.recordOversizedSample()
    }

    func fail(_ error: Error) {
        transportDiagnostics?.recordSessionFailure()
        let wrapped = error as? AxolotyError ?? AxolotyError.caught(error)
        let code: AxolotyError.RuntimeErrorCode
        if case let .runtime(runtimeCode, _) = wrapped {
            code = runtimeCode
        } else {
            code = .brokerUnavailable
        }
        failure?(RuntimeTransportFailure(code: code, detail: wrapped.userFriendlyMessage))
    }

    func recover() { recovery?() }
}

struct TestTransportFailure: Error, Sendable {}

actor BlockingStartTransport: AxolotyRuntimeTransport {
    private(set) var didStart = false
    private var didStop = false
    private var startWaiter: CheckedContinuation<Void, Never>?

    func start(receive: @escaping @Sendable (RuntimeInboundFrame) -> Void) async throws {
        didStart = true
        await withCheckedContinuation { continuation in
            if didStop {
                continuation.resume()
            } else {
                startWaiter = continuation
            }
        }
    }

    func perform(_ effect: RuntimeTransportEffect) async throws {}

    func stop() async {
        didStop = true
        startWaiter?.resume()
        startWaiter = nil
    }
}

actor DrainingTransport: AxolotyRuntimeTransport {
    private(set) var sendStarted = false
    private(set) var didStop = false
    private var released = false
    private var sendWaiter: CheckedContinuation<Void, Never>?

    func start(receive: @escaping @Sendable (RuntimeInboundFrame) -> Void) async throws {}
    func setFailureHandler(_ handler: @escaping @Sendable (RuntimeTransportFailure) -> Void) async {}

    func perform(_ effect: RuntimeTransportEffect) async throws {
        switch effect {
        case .publish: break
        default: return
        }
        sendStarted = true
        guard !released else { return }
        await withCheckedContinuation { continuation in
            if released {
                continuation.resume()
            } else {
                sendWaiter = continuation
            }
        }
    }

    func stop() async { didStop = true }
    func activateProfileInterest(namespace: String) async throws {}
    func deactivateProfileInterest(namespace: String) async throws {}

    func releaseSend() {
        released = true
        sendWaiter?.resume()
        sendWaiter = nil
    }
}

enum RuntimeTestTimeout: Error {
    case waitingForAdvertiseEvent
}

final class RuntimeTestIteratorBox: @unchecked Sendable {
    private var iterator: AsyncStream<RuntimeEventValue>.Iterator

    init(_ iterator: AsyncStream<RuntimeEventValue>.Iterator) {
        self.iterator = iterator
    }

    func next() async -> RuntimeEventValue? {
        await iterator.next()
    }
}

final class RuntimeTestDiagnosticIteratorBox: @unchecked Sendable {
    private var iterator: AsyncStream<RuntimeDiagnostic>.Iterator

    init(_ iterator: AsyncStream<RuntimeDiagnostic>.Iterator) {
        self.iterator = iterator
    }

    func next() async -> RuntimeDiagnostic? {
        await iterator.next()
    }
}

/// Whether a resolved route publishes a Coaty Advertise event.
///
/// Transports now receive finished routes rather than routing keys, so tests
/// that previously matched `routingKey.capability` match the wire event type
/// segment instead. A Coaty route is `coaty/3/<namespace>/<event>/<source>`,
/// and the Advertise event type is `ADV`, optionally filtered as `ADV:Type`
/// or `ADV::coaty.Type`.
func isAdvertiseRoute(_ route: String) -> Bool {
    let segments = route.split(separator: "/", omittingEmptySubsequences: false)
    guard segments.count >= 4 else { return false }
    return segments[3] == "ADV" || segments[3].hasPrefix("ADV:")
}

/// Whether a resolved route publishes a Coaty Deadvertise event.
func isDeadvertiseRoute(_ route: String) -> Bool {
    let segments = route.split(separator: "/", omittingEmptySubsequences: false)
    guard segments.count >= 4 else { return false }
    return segments[3] == "DAD" || segments[3].hasPrefix("DAD:")
}

/// The event-type code of a resolved Coaty route, without any filter suffix.
func routeEventType(_ route: String) -> String {
    let segments = route.split(separator: "/", omittingEmptySubsequences: false)
    guard segments.count >= 4 else { return "" }
    return String(segments[3].split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)[0])
}
