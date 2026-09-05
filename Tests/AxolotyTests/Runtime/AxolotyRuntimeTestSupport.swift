// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Testing
@testable import Axoloty
import AxolotyObjectModel
import AxolotyProtocol
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
            return ["start", "remove", "stop"]
        case .subscriptions:
            return ["start", "install", "remove", "stop"]
        case .advertisement:
            return ["start", "install", "remove", "stop"]
        }
    }
}

actor TestTransport: AxolotyRuntimeTransport {
    private var receive: (@Sendable (RuntimeInboundFrame) -> Void)?
    private var failure: (@Sendable (Error) -> Void)?
    private var sent: [RuntimeOutboundMessage] = []
    private(set) var lifecycle: [String] = []
    private let failureStage: SetupFailureStage?

    init(failing failureStage: SetupFailureStage? = nil) {
        self.failureStage = failureStage
    }

    func start(receive: @escaping @Sendable (RuntimeInboundFrame) -> Void) async throws {
        self.receive = receive
        lifecycle.append("start")
        if failureStage == .start { throw TestTransportFailure() }
    }

    func setFailureHandler(_ handler: @escaping @Sendable (Error) -> Void) {
        failure = handler
    }

    func perform(_ effect: RuntimeTransportEffect) async throws {
        let message: RuntimeOutboundMessage
        switch effect {
        case .publish(let value): message = value
        default: return
        }
        sent.append(message)
        if failureStage == .advertisement, isAdvertiseRoute(message.route) {
            throw TestTransportFailure()
        }
    }

    func stop() async {
        receive = nil
        lifecycle.append("stop")
    }

    func installSubscriptions(namespace: String) async throws {
        lifecycle.append("install")
        if failureStage == .subscriptions { throw TestTransportFailure() }
    }
    func removeSubscriptions(namespace: String) async throws { lifecycle.append("remove") }

    func sentCount() -> Int { sent.count }
    func firstSent() -> RuntimeOutboundMessage? { sent.first }
    func lastSent() -> RuntimeOutboundMessage? { sent.last }

    /// Simulates a wire frame arriving on the currently installed transport
    /// callback, exactly as a real transport implementation would invoke it.
    func deliver(_ frame: RuntimeInboundFrame) {
        receive?(frame)
    }

    func fail(_ error: Error) { failure?(error) }
}

struct TestTransportFailure: Error, Sendable {}

actor DrainingTransport: AxolotyRuntimeTransport {
    private(set) var sendStarted = false
    private(set) var didStop = false
    private var released = false
    private var sendWaiter: CheckedContinuation<Void, Never>?

    func start(receive: @escaping @Sendable (RuntimeInboundFrame) -> Void) async throws {}
    func setFailureHandler(_ handler: @escaping @Sendable (Error) -> Void) {}

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
    func installSubscriptions(namespace: String) async throws {}
    func removeSubscriptions(namespace: String) async throws {}

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
