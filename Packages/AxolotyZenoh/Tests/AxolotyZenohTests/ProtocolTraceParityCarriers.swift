// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import AxolotyProtocol
import AxolotyWire
import Foundation
import AxolotyTestBroker
@testable import AxolotyMQTT
@testable import AxolotyZenoh
@testable import AxolotyProtocolTraceTestSupport

private struct InjectedFrameKey: Hashable, Sendable {
    let route: String
    let payload: [UInt8]

    init(_ frame: RuntimeInboundFrame) {
        switch frame {
        case let .profile(route, payload, _), let .externalIo(route, payload, _):
            self.route = route
            self.payload = payload
        }
    }
}

private final class FrameDeliverySignal: @unchecked Sendable {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private let lock = NSLock()
    private var pending: [InjectedFrameKey: [Waiter]] = [:]
    private var delivered: [InjectedFrameKey: Int] = [:]
    private var timeoutTasks: [UUID: Task<Void, Never>] = [:]

    func wait(for frame: RuntimeInboundFrame, traceID: String, sequence: Int) async throws {
        let key = InjectedFrameKey(frame)
        let waiterID = UUID()
        try await withCheckedThrowingContinuation { continuation in
            var resumeNow = false
            lock.lock()
            if let count = delivered[key], count > 0 {
                delivered[key] = count - 1
                resumeNow = true
            } else {
                pending[key, default: []].append(Waiter(id: waiterID, continuation: continuation))
            }
            lock.unlock()
            if resumeNow { continuation.resume() }
            else {
                let timeoutTask = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(10)) }
                    catch { return }
                    self?.expire(
                        key,
                        waiterID: waiterID,
                        traceID: traceID,
                        sequence: sequence
                    )
                }
                lock.withLock {
                    if pending[key]?.contains(where: { $0.id == waiterID }) == true {
                        timeoutTasks[waiterID] = timeoutTask
                    } else {
                        timeoutTask.cancel()
                    }
                }
            }
        }
    }

    func record(_ frame: RuntimeInboundFrame) {
        let key = InjectedFrameKey(frame)
        let waiter: Waiter?
        let timeoutTask: Task<Void, Never>?
        lock.lock()
        if var waiters = pending[key], !waiters.isEmpty {
            let firstWaiter = waiters.removeFirst()
            waiter = firstWaiter
            pending[key] = waiters
            timeoutTask = timeoutTasks.removeValue(forKey: firstWaiter.id)
        } else {
            delivered[key, default: 0] += 1
            waiter = nil
            timeoutTask = nil
        }
        lock.unlock()
        timeoutTask?.cancel()
        waiter?.continuation.resume()
    }

    private func expire(
        _ key: InjectedFrameKey,
        waiterID: UUID,
        traceID: String,
        sequence: Int
    ) {
        let waiter: Waiter? = lock.withLock {
            guard var waiters = pending[key],
                  let index = waiters.firstIndex(where: { $0.id == waiterID }) else { return nil }
            let expired = waiters.remove(at: index)
            pending[key] = waiters
            timeoutTasks.removeValue(forKey: waiterID)
            return expired
        }
        waiter?.continuation.resume(throwing: TraceReplayError.missingRuntimeReceipt(
            traceID: traceID,
            sequence: sequence
        ))
    }
}

final class MQTTTraceCarrier: RuntimeTraceCarrier, @unchecked Sendable {
    private let binding: MQTTBinding
    private let broker: TestMQTTBroker
    private let signal = FrameDeliverySignal()
    private let lock = NSLock()
    private var injectedTimes: [InjectedFrameKey: UInt32] = [:]
    private var outboundEffectsEnabled = false

    init(binding: MQTTBinding, broker: TestMQTTBroker) {
        self.binding = binding
        self.broker = broker
    }

    func start(receive: @escaping @Sendable (RuntimeInboundFrame) -> Void) async throws {
        try await binding.start { [self] frame in
            let normalized = normalizeTime(frame)
            receive(normalized)
            signal.record(normalized)
        }
    }

    func inject(_ frame: RuntimeInboundFrame, traceID: String, sequence: Int) async throws {
        guard case let .profile(route, payload, nowMS) = frame else {
            throw AxolotyError.invalidArgument(argument: "trace frame", reason: "expected a profile route")
        }
        let key = InjectedFrameKey(frame)
        lock.withLock { injectedTimes[key] = nowMS }
        let waiter = Task { try await signal.wait(for: frame, traceID: traceID, sequence: sequence) }
        broker.injectPublication(topic: route, payload: payload)
        try await waiter.value
    }

    func setFailureHandler(_ handler: @escaping @Sendable (RuntimeTransportFailure) -> Void) async {
        await binding.setFailureHandler(handler)
    }
    func setRecoveryHandler(_ handler: @escaping @Sendable () -> Void) async {
        await binding.setRecoveryHandler(handler)
    }
    func perform(_ effect: RuntimeTransportEffect) async throws {
        if case .publish = effect, !lock.withLock({ outboundEffectsEnabled }) { return }
        try await binding.perform(effect)
    }
    func setOutboundEffectsEnabled(_ enabled: Bool) {
        lock.withLock { outboundEffectsEnabled = enabled }
    }
    func stop() async { await binding.stop() }
    func activateProfileInterest(namespace: String) async throws {
        try await binding.activateProfileInterest(namespace: namespace)
    }
    func deactivateProfileInterest(namespace: String) async throws {
        try await binding.deactivateProfileInterest(namespace: namespace)
    }
    func classifyRoute(_ route: ByteSlice) -> ProtocolRouteClassification {
        binding.classifyRoute(route)
    }

    private func normalizeTime(_ frame: RuntimeInboundFrame) -> RuntimeInboundFrame {
        let key = InjectedFrameKey(frame)
        lock.lock()
        let nowMS = injectedTimes.removeValue(forKey: key) ?? 0
        lock.unlock()
        switch frame {
        case let .profile(route, payload, _): return .profile(route: route, payload: payload, nowMS: nowMS)
        case let .externalIo(route, payload, _): return .externalIo(route: route, payload: payload, nowMS: nowMS)
        }
    }
}

final class ZenohTraceCarrier: RuntimeTraceCarrier, @unchecked Sendable {
    private let binding: ZenohBinding
    private let session: RecordingZenohSession
    private let clock: TraceFrameClock
    private let signal = FrameDeliverySignal()
    private let lock = NSLock()
    private var outboundEffectsEnabled = false

    init(binding: ZenohBinding, session: RecordingZenohSession, clock: TraceFrameClock) {
        self.binding = binding
        self.session = session
        self.clock = clock
    }

    func start(receive: @escaping @Sendable (RuntimeInboundFrame) -> Void) async throws {
        try await binding.start { [signal] frame in
            receive(frame)
            signal.record(frame)
        }
    }

    func inject(_ frame: RuntimeInboundFrame, traceID: String, sequence: Int) async throws {
        guard case let .profile(route, payload, nowMS) = frame else {
            throw AxolotyError.invalidArgument(argument: "trace frame", reason: "expected a profile route")
        }
        clock.set(nowMS)
        let waiter = Task { try await signal.wait(for: frame, traceID: traceID, sequence: sequence) }
        session.enqueuePublication(route: route, payload: payload)
        _ = binding.drainReceiveQueues()
        try await waiter.value
    }

    func setFailureHandler(_ handler: @escaping @Sendable (RuntimeTransportFailure) -> Void) async {
        await binding.setFailureHandler(handler)
    }
    func setRecoveryHandler(_ handler: @escaping @Sendable () -> Void) async {
        await binding.setRecoveryHandler(handler)
    }
    func perform(_ effect: RuntimeTransportEffect) async throws {
        if case .publish = effect, !lock.withLock({ outboundEffectsEnabled }) { return }
        try await binding.perform(effect)
    }
    func setOutboundEffectsEnabled(_ enabled: Bool) {
        lock.withLock { outboundEffectsEnabled = enabled }
    }
    func stop() async { await binding.stop() }
    func activateProfileInterest(namespace: String) async throws {
        try await binding.activateProfileInterest(namespace: namespace)
    }
    func deactivateProfileInterest(namespace: String) async throws {
        try await binding.deactivateProfileInterest(namespace: namespace)
    }
    func classifyRoute(_ route: ByteSlice) -> ProtocolRouteClassification {
        binding.classifyRoute(route)
    }
}

final class TraceFrameClock: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: UInt32 = 0

    var value: UInt32 { lock.withLock { storedValue } }
    func set(_ value: UInt32) { lock.withLock { storedValue = value } }
}
