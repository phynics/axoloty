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
    private var sent: [OwnedProtocolPublication] = []
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

    func perform(_ effect: RuntimeTransportEffect, namespace: String) async throws {
        guard case .publish(let publication) = effect else { return }
        sent.append(publication)
        if failureStage == .advertisement, publication.routingKey.capability == .advertise {
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
    func firstSent() -> OwnedProtocolPublication? { sent.first }
    func lastSent() -> OwnedProtocolPublication? { sent.last }

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

    func perform(_ effect: RuntimeTransportEffect, namespace: String) async throws {
        guard case .publish = effect else { return }
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
