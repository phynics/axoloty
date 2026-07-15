// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import Logging

public enum EventStreamBuffering: Sendable {
    case event
    case state
}

public actor EventHub {

    private var continuations: [AnyHashable: [UUID: AnySendableContinuation]] = [:]
    private var streamInfo: [UUID: StreamRegistration] = [:]
    private var lastValues: [AnyHashable: Any] = [:]
    private var bufferingPolicy: [AnyHashable: EventStreamBuffering] = [:]
    private var registrationKeys: [UUID: AnyHashable] = [:]
    private var onFirstCallbacks: [AnyHashable: @Sendable () -> Void] = [:]
    private var onLastCallbacks: [AnyHashable: @Sendable () -> Void] = [:]

    private let log = LogManager.log

    public init() {}

    private struct StreamRegistration {
        let key: AnyHashable
        let buffering: EventStreamBuffering
        let onFirst: @Sendable () -> Void
        let onLast: @Sendable () -> Void
    }

    public func registerStream<Element: Sendable>(
        key: AnyHashable,
        buffering: EventStreamBuffering,
        onFirst: @escaping @Sendable () -> Void,
        onLast: @escaping @Sendable () -> Void
    ) -> EventStream<Element> {
        let id = UUID()
        streamInfo[id] = StreamRegistration(key: key, buffering: buffering, onFirst: onFirst, onLast: onLast)
        bufferingPolicy[key] = buffering
        return EventStream<Element>(hub: self, streamId: id, buffering: buffering)
    }

    public func registerContinuation(
        _ continuation: AnySendableContinuation,
        id: UUID,
        key: AnyHashable,
        buffering: EventStreamBuffering,
        onFirst: @escaping @Sendable () -> Void,
        onLast: @escaping @Sendable () -> Void
    ) {
        self.bufferingPolicy[key] = buffering
        registrationKeys[id] = key
        onFirstCallbacks[key] = onFirst
        onLastCallbacks[key] = onLast

        let wasEmpty = (continuations[key]?.isEmpty ?? true)
        if wasEmpty {
            onFirst()
        }

        continuation.setTerminationHandler { [weak self] in
            _Concurrency.Task { [weak self] in
                await self?.handleTermination(id: id)
            }
        }

        if buffering == .state, let last = lastValues[key] {
            continuation.yield(last)
        }

        continuations[key, default: [:]][id] = continuation
    }

    nonisolated func registerIteratorContinuation(
        _ continuation: AnySendableContinuation,
        streamId: UUID
    ) {
        _Concurrency.Task { [self] in
            await _registerIteratorContinuation(
                continuation: continuation,
                streamId: streamId
            )
        }
    }

    private func _registerIteratorContinuation(
        continuation: AnySendableContinuation,
        streamId: UUID
    ) {
        guard let info = streamInfo[streamId] else { return }
        let continuationId = UUID()
        registerContinuation(
            continuation,
            id: continuationId,
            key: info.key,
            buffering: info.buffering,
            onFirst: info.onFirst,
            onLast: info.onLast
        )
    }

    public func yield<Element: Sendable>(value: Element, to key: AnyHashable) {
        _yield(value: value, key: key)
    }

    /// Yields a state value, storing it for replay by new state-stream subscribers.
    ///
    /// Unlike ``yield(value:to:)``, this stores the value even if no state stream
    /// is currently registered, so that a later subscriber receives the most recent
    /// state as its first element.
    public func yieldState<Element: Sendable>(value: Element, to key: AnyHashable) {
        _yieldState(value: value, key: key)
    }

    private func _yield(value: Any, key: AnyHashable) {
        if bufferingPolicy[key] == .state {
            lastValues[key] = value
        }
        guard let keyContinuations = continuations[key] else { return }
        for (_, continuation) in keyContinuations {
            continuation.yield(value)
        }
    }

    private func _yieldState(value: Any, key: AnyHashable) {
        lastValues[key] = value
        guard let keyContinuations = continuations[key] else { return }
        for (_, continuation) in keyContinuations {
            continuation.yield(value)
        }
    }

    public func finish(key: AnyHashable) {
        _finish(key: key)
    }

    private func _finish(key: AnyHashable) {
        guard let keyContinuations = continuations.removeValue(forKey: key) else { return }
        for (id, continuation) in keyContinuations {
            registrationKeys.removeValue(forKey: id)
            continuation.finish()
        }
        lastValues.removeValue(forKey: key)
        bufferingPolicy.removeValue(forKey: key)
        onLastCallbacks.removeValue(forKey: key)?()
        onFirstCallbacks.removeValue(forKey: key)
    }

    private func handleTermination(id: UUID) {
        guard let key = registrationKeys.removeValue(forKey: id),
              var keyContinuations = continuations[key],
              keyContinuations.removeValue(forKey: id) != nil else { return }
        if keyContinuations.isEmpty {
            continuations.removeValue(forKey: key)
            bufferingPolicy.removeValue(forKey: key)
            onLastCallbacks.removeValue(forKey: key)?()
            onFirstCallbacks.removeValue(forKey: key)
        } else {
            continuations[key] = keyContinuations
        }
    }
}

public final class AnySendableContinuation: @unchecked Sendable {
    private let _yield: @Sendable (Any) -> Void
    private let _finish: @Sendable () -> Void
    private let _handlerRef: MutableBox<(() -> Void)?>

    public init<Element: Sendable>(_ continuation: AsyncStream<Element>.Continuation) {
        let box = Box(continuation)
        let handlerRef = MutableBox<(() -> Void)?>(nil)
        _handlerRef = handlerRef
        _yield = { value in
            guard let typed = value as? Element else { return }
            _ = box.continuation.yield(typed)
        }
        _finish = { box.continuation.finish() }
        box.continuation.onTermination = { _ in
            handlerRef.value?()
        }
    }

    public func yield(_ value: Any) {
        _yield(value)
    }

    public func finish() {
        _finish()
    }

    public func setTerminationHandler(_ handler: @escaping () -> Void) {
        _handlerRef.value = handler
    }
}

private final class Box<Element: Sendable>: @unchecked Sendable {
    let continuation: AsyncStream<Element>.Continuation
    init(_ c: AsyncStream<Element>.Continuation) { continuation = c }
}

private final class MutableBox<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}
