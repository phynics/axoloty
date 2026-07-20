// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// Buffering mode for a ``Broadcast`` stream.
///
/// Replaces the former ``EventStreamBuffering`` (deleted with ``EventHub``).
/// ``BroadcastMode/event`` buffers up to 256 oldest values and does not
/// replay to late subscribers. ``BroadcastMode/state`` keeps only the newest
/// value and replays it to late subscribers as their first element.
internal enum BroadcastMode: Sendable {
    case event
    case state
}

/// A typed multicast primitive for fan-out of `Sendable` values to
/// multiple `AsyncStream` consumers.
///
/// `Broadcast` replaces the per-key machinery of the former `EventHub`.
/// Each instance owns its own set of subscriber continuations and, for
/// `.state` mode, the most recently sent value for late-subscriber
/// replay.
///
/// `onFirst` fires when the first subscriber attaches (subscriber count
/// goes from 0 to 1). `onLast` fires when the last subscriber's
/// continuation terminates (count goes from 1 to 0). These hooks drive
/// MQTT subscription refcounting: `onFirst` acquires the topic,
/// `onLast` releases it. Both can fire multiple times over the
/// `Broadcast`'s lifetime if all subscribers leave and new ones later
/// attach.
///
/// The continuation is registered eagerly inside ``subscribe()``
/// before the method returns, so values sent between `subscribe()` and
/// the first `next()` call are buffered and delivered — no registration
/// race.
///
/// - Note: `Broadcast` is an `actor`; all operations are serialized.
///   Producers call ``send(_:)`` or ``sendState(_:)``; consumers call
///   ``subscribe()`` to obtain an `AsyncStream<Element>`.
internal actor Broadcast<Element: Sendable> {

    private let mode: BroadcastMode
    private let onFirst: (@Sendable () async -> Void)?
    private let onLast: (@Sendable () async -> Void)?

    private var subscribers: [UUID: AsyncStream<Element>.Continuation] = [:]
    private var lastValue: Element?
    private var started = false

    init(
        mode: BroadcastMode,
        onFirst: (@Sendable () async -> Void)? = nil,
        onLast: (@Sendable () async -> Void)? = nil
    ) {
        self.mode = mode
        self.onFirst = onFirst
        self.onLast = onLast
    }

    /// Registers a new subscriber and returns its `AsyncStream`.
    ///
    /// The continuation is registered eagerly before this method returns,
    /// so values sent between `subscribe()` and the first `next()` call
    /// are buffered and delivered. For `.state` mode, the most recently
    /// sent value (if any) is replayed as the first element.
    func subscribe() -> AsyncStream<Element> {
        let id = UUID()
        let policy: AsyncStream<Element>.Continuation.BufferingPolicy =
            mode == .event ? .bufferingOldest(256) : .bufferingNewest(1)
        let (stream, continuation) = AsyncStream<Element>.makeStream(bufferingPolicy: policy)

        subscribers[id] = continuation

        if mode == .state, let last = lastValue {
            continuation.yield(last)
        }

        continuation.onTermination = { [weak self] _ in
            _Concurrency.Task { [weak self] in
                await self?.removeSubscriber(id)
            }
        }

        if !started {
            started = true
            if let onFirst {
                _Concurrency.Task { await onFirst() }
            }
        }

        return stream
    }

    /// Sends a value to all current subscribers.
    ///
    /// For `.state` mode, the value is cached for replay to future
    /// subscribers. If no subscriber is attached, the value is dropped
    /// (`.event`) or cached only (`.state`).
    func send(_ value: Element) {
        if mode == .state {
            lastValue = value
        }
        for (_, continuation) in subscribers {
            continuation.yield(value)
        }
    }

    /// Sends a state value, caching it for replay even if no subscriber
    /// is currently attached.
    ///
    /// Unlike ``send(_:)``, this always updates `lastValue`, so a
    /// subscriber that later calls ``subscribe()`` receives this value
    /// as its first element.
    func sendState(_ value: Element) {
        lastValue = value
        for (_, continuation) in subscribers {
            continuation.yield(value)
        }
    }

    /// Finishes all subscriber continuations and clears replay state.
    ///
    /// If `onLast` is set and the `Broadcast` was started, `onLast`
    /// fires to release any associated MQTT subscription.
    func finish() {
        for (_, continuation) in subscribers {
            continuation.finish()
        }
        subscribers.removeAll()
        lastValue = nil
        if started {
            started = false
            if let onLast {
                _Concurrency.Task { await onLast() }
            }
        }
    }

    private func removeSubscriber(_ id: UUID) {
        guard subscribers.removeValue(forKey: id) != nil else { return }
        if subscribers.isEmpty && started {
            started = false
            if let onLast {
                _Concurrency.Task { await onLast() }
            }
        }
    }
}

/// A typed registry of ``Broadcast`` instances keyed by a `Hashable`
/// key, for parameterized streams (e.g. per-filter, per-channel,
/// per-correlation-id).
///
/// `BroadcastFamily` manages the lifecycle of per-key `Broadcast`
/// instances. When the first subscriber for a key attaches,
/// `onFirst(key)` fires (e.g. to acquire the MQTT topic). When the
/// last subscriber for that key leaves, `onLast(key)` fires (e.g. to
/// release the MQTT topic).
///
/// `Broadcast` instances are **not evicted** when their subscriber
/// count drops to zero. This avoids a race where `onLast` fires
/// asynchronously and a new subscriber attaches to the same `Broadcast`
/// before eviction runs — the new subscriber would be orphaned if the
/// `Broadcast` were removed. Instead, `Broadcast` instances persist in
/// the family's dictionary for the lifetime of the family. This is
/// acceptable because the number of distinct keys is bounded by the
/// communication protocol's event-type/filter/channel taxonomy.
internal actor BroadcastFamily<Key: Hashable & Sendable, Element: Sendable> {

    private let mode: BroadcastMode
    private let makeOnFirst: (@Sendable (Key) async -> Void)?
    private let makeOnLast: (@Sendable (Key) async -> Void)?
    private var broadcasts: [Key: Broadcast<Element>] = [:]

    init(
        mode: BroadcastMode,
        onFirst: (@Sendable (Key) async -> Void)? = nil,
        onLast: (@Sendable (Key) async -> Void)? = nil
    ) {
        self.mode = mode
        self.makeOnFirst = onFirst
        self.makeOnLast = onLast
    }

    /// Returns an `AsyncStream` for the given key, creating a new
    /// `Broadcast` for that key if one does not already exist.
    func subscribe(for key: Key) async -> AsyncStream<Element> {
        if let existing = broadcasts[key] {
            return await existing.subscribe()
        }
        let broadcast = Broadcast<Element>(
            mode: mode,
            onFirst: { [makeOnFirst, key] in await makeOnFirst?(key) },
            onLast: { [makeOnLast, key] in await makeOnLast?(key) }
        )
        broadcasts[key] = broadcast
        return await broadcast.subscribe()
    }

    /// Sends a value to all subscribers of the `Broadcast` registered
    /// under `key`. If no `Broadcast` exists for `key`, the value is
    /// dropped.
    func send(_ value: Element, for key: Key) async {
        guard let broadcast = broadcasts[key] else { return }
        await broadcast.send(value)
    }

    /// Sends a state value, caching it for replay even if no subscriber
    /// is currently attached to the `Broadcast` for `key`. Creates a
    /// `Broadcast` for `key` if one does not exist.
    func sendState(_ value: Element, for key: Key) async {
        if broadcasts[key] == nil {
            let broadcast = Broadcast<Element>(
                mode: mode,
                onFirst: { [makeOnFirst, key] in await makeOnFirst?(key) },
                onLast: { [makeOnLast, key] in await makeOnLast?(key) }
            )
            broadcasts[key] = broadcast
        }
        await broadcasts[key]?.sendState(value)
    }

    /// Finishes all `Broadcast` instances in the family and clears
    /// the registry.
    func finishAll() async {
        for (_, broadcast) in broadcasts {
            await broadcast.finish()
        }
        broadcasts.removeAll()
    }
}
