// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import Logging

public enum EventStreamBuffering: Sendable {
    case event
    case state
}

public actor EventHub {

    private var continuations: [AnyHashable: [UUID: AnySendableContinuation]] = [:]
    private var lastValues: [AnyHashable: Any] = [:]
    private var bufferingPolicy: [AnyHashable: EventStreamBuffering] = [:]
    private var registrationKeys: [UUID: AnyHashable] = [:]
    private var lastCallbacks: [AnyHashable: [UUID: @Sendable () -> Void]] = [:]

    public init() {}

    /// Registers an ``EventStream`` under ``key``, eagerly constructing and
    /// registering its continuation so values yielded after this call are
    /// buffered and delivered to the first iterator.
    ///
    /// - Parameters:
    ///   - key: The hub key to route yielded values through.
    ///   - buffering: The buffering strategy (``EventStreamBuffering/event``
    ///     buffers up to 256 oldest values; ``EventStreamBuffering/state``
    ///     keeps only the newest).
    ///   - onLast: Called once when the stream's last continuation terminates
    ///     or ``finish(key:)`` is called for ``key``.
    /// - Returns: An ``EventStream`` whose continuation is already registered.
    public func registerStream<Element: Sendable>(
        key: AnyHashable,
        buffering: EventStreamBuffering,
        onLast: @escaping @Sendable () -> Void
    ) -> EventStream<Element> {
        let id = UUID()
        let policy: AsyncStream<Element>.Continuation.BufferingPolicy =
            buffering == .event ? .bufferingOldest(256) : .bufferingNewest(1)
        let (asyncStream, continuation) = AsyncStream<Element>.makeStream(bufferingPolicy: policy)
        let erased = AnySendableContinuation(continuation)

        bufferingPolicy[key] = buffering
        if lastCallbacks[key]?[id] == nil {
            lastCallbacks[key, default: [:]][id] = onLast
        }
        registerContinuation(erased, id: id, key: key, buffering: buffering, onLast: onLast)

        return EventStream<Element>(asyncStream: asyncStream, continuation: erased)
    }

    public func registerContinuation(
        _ continuation: AnySendableContinuation,
        id: UUID,
        key: AnyHashable,
        buffering: EventStreamBuffering,
        onLast: @escaping @Sendable () -> Void
    ) {
        self.bufferingPolicy[key] = buffering
        registrationKeys[id] = key

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
        fireAndClearLastCallbacks(for: key)
    }

    private func handleTermination(id: UUID) {
        guard let key = registrationKeys.removeValue(forKey: id),
              var keyContinuations = continuations[key],
              keyContinuations.removeValue(forKey: id) != nil else { return }
        if keyContinuations.isEmpty {
            continuations.removeValue(forKey: key)
            bufferingPolicy.removeValue(forKey: key)
            fireAndClearLastCallbacks(for: key)
        } else {
            continuations[key] = keyContinuations
        }
    }

    private func fireAndClearLastCallbacks(for key: AnyHashable) {
        guard let callbacks = lastCallbacks.removeValue(forKey: key) else { return }
        for (_, callback) in callbacks {
            callback()
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
