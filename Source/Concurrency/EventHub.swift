// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import Logging

public enum EventStreamBuffering: Sendable {
    case event
    case state
}

/// A phantom-typed key identifying a stream in ``EventHub``.
///
/// Keys are grouped by a scope prefix and a unique name within that scope.
/// The `Element` parameter is phantom: it is not stored and does not
/// participate in equality or hashing. Its purpose is to link
/// ``EventHub/registerStream(key:buffering:onLast:)`` and
/// ``EventHub/yield(value:to:)`` at the type level so that a wrong-typed
/// yield is a compile error rather than a silent runtime drop.
///
/// Two keys with the same `scope` and `name` but different `Element` types
/// compare equal as hashable keys (they occupy the same hub slot), but the
/// hub traps if a slot is used at two different element types. This makes
/// accidental type mismatches impossible by construction.
///
/// Use a dedicated ``EventKey`` rather than a raw string or ``AnyHashable``
/// literal to prevent accidental collisions with other EventHub consumers
/// that might choose the same textual identifier.
public struct EventKey<Element: Sendable>: Hashable, Sendable {

    /// The scope prefix that groups related keys, e.g. `"communication"`.
    public let scope: String

    /// The unique name of the stream within ``scope``.
    public let name: String

    /// Creates a key with the given scope and name.
    /// - Parameters:
    ///   - scope: The scope prefix that groups related keys.
    ///   - name: The unique name of the stream within `scope`.
    public init(scope: String, name: String) {
        self.scope = scope
        self.name = name
    }

    public static func == (lhs: EventKey, rhs: EventKey) -> Bool {
        lhs.scope == rhs.scope && lhs.name == rhs.name
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(scope)
        hasher.combine(name)
    }
}

/// An element-type-erased view of an ``EventKey`` used for internal hub
/// storage.
///
/// Two keys with the same scope and name but different element types erase
/// to the same `AnyEventKey`, so they share a hub slot. The hub traps if a
/// slot is used at two different element types (see
/// ``EventHub/getOrCreateBroadcaster``).
internal struct AnyEventKey: Hashable, Sendable {
    let scope: String
    let name: String

    init<E: Sendable>(_ key: EventKey<E>) {
        self.scope = key.scope
        self.name = key.name
    }
}

public actor EventHub {

    private var broadcasters: [AnyEventKey: any AnyBroadcaster] = [:]
    private var registrationKeys: [UUID: AnyEventKey] = [:]
    private var lastCallbacks: [AnyEventKey: [UUID: @Sendable () -> Void]] = [:]

    public init() {}

    /// Registers an ``EventStream`` under ``key``, eagerly constructing and
    /// registering its continuation so values yielded after this call are
    /// buffered and delivered to the first iterator.
    ///
    /// - Parameters:
    ///   - key: The typed hub key to route yielded values through. The key's
    ///     element type pins the stream's element type; a wrong-typed
    ///     ``yield(value:to:)`` will not compile.
    ///   - buffering: The buffering strategy (``EventStreamBuffering/event``
    ///     buffers up to 256 oldest values; ``EventStreamBuffering/state``
    ///     keeps only the newest).
    ///   - onLast: Called once when the stream's last continuation terminates
    ///     or ``finish(key:)`` is called for ``key``. If multiple streams are
    ///     registered under the same key, every registration's `onLast`
    ///     callback fires when the last continuation terminates — this is
    ///     load-bearing for MQTT subscription refcounting.
    /// - Returns: An ``EventStream`` whose continuation is already registered.
    public func registerStream<E: Sendable>(
        key: EventKey<E>,
        buffering: EventStreamBuffering,
        onLast: @escaping @Sendable () -> Void
    ) -> EventStream<E> {
        let id = UUID()
        let policy: AsyncStream<E>.Continuation.BufferingPolicy =
            buffering == .event ? .bufferingOldest(256) : .bufferingNewest(1)
        let (asyncStream, continuation) = AsyncStream<E>.makeStream(bufferingPolicy: policy)
        let erased = AnyEventKey(key)

        continuation.onTermination = { _ in
            _Concurrency.Task { [weak self] in
                await self?.handleTermination(id: id)
            }
        }

        let broadcaster = getOrCreateBroadcaster(erased, buffering: buffering, as: E.self)
        broadcaster.attach(continuation, id: id)

        registrationKeys[id] = erased
        lastCallbacks[erased, default: [:]][id] = onLast

        return EventStream<E>(asyncStream: asyncStream, continuation: continuation)
    }

    /// Yields a value to all subscribers of ``key``.
    ///
    /// For `.event` streams the value is delivered to current subscribers
    /// only; for `.state` streams the value is also cached for replay to
    /// late subscribers. If no stream is registered under ``key``, the
    /// value is dropped.
    ///
    /// The value's type must match the key's phantom element type; a
    /// mismatch is a compile-time error.
    public func yield<E: Sendable>(value: E, to key: EventKey<E>) {
        let erased = AnyEventKey(key)
        guard let broadcaster = broadcasters[erased] as? Broadcaster<E> else { return }
        broadcaster.yield(value)
    }

    /// Yields a state value, storing it for replay by new state-stream
    /// subscribers.
    ///
    /// Unlike ``yield(value:to:)``, this stores the value even if no state
    /// stream is currently registered, so that a later subscriber receives
    /// the most recent state as its first element.
    ///
    /// The value's type must match the key's phantom element type; a
    /// mismatch is a compile-time error.
    public func yieldState<E: Sendable>(value: E, to key: EventKey<E>) {
        let erased = AnyEventKey(key)
        let broadcaster = getOrCreateBroadcaster(erased, buffering: .state, as: E.self)
        broadcaster.yieldState(value)
    }

    /// Finishes all streams registered under ``key`` and clears replay state.
    ///
    /// Every registered `onLast` callback for ``key`` fires, preserving
    /// the "fire every registration's onLast" semantics used for MQTT
    /// subscription refcounting.
    public func finish<E: Sendable>(key: EventKey<E>) {
        let erased = AnyEventKey(key)
        guard let broadcaster = broadcasters.removeValue(forKey: erased) else {
            fireAndClearLastCallbacks(for: erased)
            return
        }
        if let callbacks = lastCallbacks[erased] {
            for id in callbacks.keys {
                registrationKeys.removeValue(forKey: id)
            }
        }
        broadcaster.finishAll()
        fireAndClearLastCallbacks(for: erased)
    }

    private func getOrCreateBroadcaster<E: Sendable>(
        _ erased: AnyEventKey,
        buffering: EventStreamBuffering,
        as: E.Type
    ) -> Broadcaster<E> {
        if let existing = broadcasters[erased] {
            guard let typed = existing as? Broadcaster<E> else {
                preconditionFailure("EventHub key \(erased.scope)/\(erased.name) registered at two element types")
            }
            return typed
        }
        let new = Broadcaster<E>(buffering: buffering)
        broadcasters[erased] = new
        return new
    }

    private func handleTermination(id: UUID) {
        guard let erased = registrationKeys.removeValue(forKey: id) else { return }
        guard let broadcaster = broadcasters[erased] else { return }
        let wasLast = broadcaster.removeContinuation(id: id)
        if wasLast {
            broadcasters.removeValue(forKey: erased)
            fireAndClearLastCallbacks(for: erased)
        }
    }

    private func fireAndClearLastCallbacks(for erased: AnyEventKey) {
        guard let callbacks = lastCallbacks.removeValue(forKey: erased) else { return }
        for (_, callback) in callbacks {
            callback()
        }
    }
}

/// Type-erased broadcaster protocol for hub storage.
///
/// The hub stores `any AnyBroadcaster` keyed by ``AnyEventKey``. Type-specific
/// operations (`yield`, `attach`) are reached by downcasting to
/// `Broadcaster<E>`, which is the only concrete conformer.
private protocol AnyBroadcaster: AnyObject, Sendable {
    /// Finishes all continuations and clears replay state.
    func finishAll()
    /// Removes the continuation for `id`. Returns `true` if it was the last
    /// one remaining.
    func removeContinuation(id: UUID) -> Bool
}

/// Per-key fan-out for a typed element.
///
/// Stores all continuations registered under one ``EventKey`` and, for
/// `.state` buffering, the most recently yielded value for late-subscriber
/// replay. Accessed only from within the ``EventHub`` actor, so its mutable
/// state is actor-isolated despite the `@unchecked Sendable` conformance.
private final class Broadcaster<Element: Sendable>: @unchecked Sendable {

    private var continuations: [UUID: AsyncStream<Element>.Continuation] = [:]
    private var lastValue: Element?
    private let buffering: EventStreamBuffering

    init(buffering: EventStreamBuffering) {
        self.buffering = buffering
    }

    func attach(_ continuation: AsyncStream<Element>.Continuation, id: UUID) {
        continuations[id] = continuation
        if buffering == .state, let last = lastValue {
            continuation.yield(last)
        }
    }

    func yield(_ value: Element) {
        if buffering == .state {
            lastValue = value
        }
        for continuation in continuations.values {
            continuation.yield(value)
        }
    }

    func yieldState(_ value: Element) {
        lastValue = value
        for continuation in continuations.values {
            continuation.yield(value)
        }
    }

    func finishAll() {
        for continuation in continuations.values {
            continuation.finish()
        }
        continuations.removeAll()
        lastValue = nil
    }

    func removeContinuation(id: UUID) -> Bool {
        guard continuations.removeValue(forKey: id) != nil else { return false }
        if continuations.isEmpty {
            lastValue = nil
        }
        return continuations.isEmpty
    }
}

extension Broadcaster: AnyBroadcaster {}
