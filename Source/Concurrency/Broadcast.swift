// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// Buffering mode for a ``Broadcast`` stream.
///
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
/// goes from 0 to 1) and is **awaited** inside ``subscribe()``, so the
/// caller can rely on the MQTT topic being acquired before the stream
/// is returned. `onLast` fires when the last subscriber's continuation
/// terminates (count goes from 1 to 0) and is **awaited** inside
/// ``removeSubscriber(_:)``, so acquire always precedes release for the
/// same subscriber cycle. Both can fire multiple times over the
/// `Broadcast`'s lifetime if all subscribers leave and new ones later
/// attach.
///
/// The continuation is registered eagerly inside ``subscribe()``
/// before `onFirst` is awaited, so values sent between `subscribe()`
/// and the first `next()` call are buffered and delivered — no
/// registration race.
///
/// - Note: `send(_:)` on a `.state` broadcast is equivalent to
///   ``sendState(_:)`` — both update `lastValue`. The two methods exist
///   for call-site clarity: `sendState` signals "this value must be
///   cached even if no subscriber is attached."
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
    /// The continuation is registered eagerly before `onFirst` is
    /// awaited, so values sent between `subscribe()` and the first
    /// `next()` call are buffered and delivered. For `.state` mode,
    /// the most recently sent value (if any) is replayed as the first
    /// element.
    ///
    /// `onFirst` is awaited before this method returns, guaranteeing
    /// that any MQTT topic acquisition has completed before the caller
    /// receives the stream. This preserves the acquire-before-publish
    /// ordering that the request/response path depends on.
    func subscribe() async -> AsyncStream<Element> {
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
                await onFirst()
            }
        }

        return stream
    }

    /// Sends a value to all current subscribers.
    ///
    /// For `.state` mode, the value is cached for replay to future
    /// subscribers (equivalent to ``sendState(_:)``). If no subscriber
    /// is attached, the value is dropped (`.event`) or cached only
    /// (`.state`).
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
    /// Unlike ``send(_:)``, this always updates `lastValue` regardless
    /// of mode, so a subscriber that later calls ``subscribe()``
    /// receives this value as its first element.
    func sendState(_ value: Element) {
        lastValue = value
        for (_, continuation) in subscribers {
            continuation.yield(value)
        }
    }

    /// Finishes all subscriber continuations and clears replay state.
    ///
    /// If `onLast` is set and the `Broadcast` was started, `onLast`
    /// is awaited before this method returns, releasing any associated
    /// MQTT subscription.
    func finish() async {
        for (_, continuation) in subscribers {
            continuation.finish()
        }
        subscribers.removeAll()
        lastValue = nil
        if started {
            started = false
            if let onLast {
                await onLast()
            }
        }
    }

    private func removeSubscriber(_ id: UUID) async {
        guard subscribers.removeValue(forKey: id) != nil else { return }
        if subscribers.isEmpty && started {
            started = false
            if let onLast {
                await onLast()
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
/// `onFirst(key)` is awaited (e.g. to acquire the MQTT topic). When the
/// last subscriber for that key leaves, `onLast(key)` is awaited (e.g.
/// to release the MQTT topic).
///
/// By default, `Broadcast` instances are **not evicted** when their
/// subscriber count drops to zero, because the keys are drawn from a
/// bounded taxonomy (core types, operations, channel IDs) and a new
/// subscriber may re-attach at any time. For families with unbounded
/// keys (e.g. per-correlation-id response streams), set
/// `evictOnLast: true` to remove the `Broadcast` from the dictionary
/// when `onLast` fires, preventing unbounded memory growth.
internal actor BroadcastFamily<Key: Hashable & Sendable, Element: Sendable> {

    private let mode: BroadcastMode
    private let makeOnFirst: (@Sendable (Key) async -> Void)?
    private let makeOnLast: (@Sendable (Key) async -> Void)?
    private let evictOnLast: Bool
    private var broadcasts: [Key: Broadcast<Element>] = [:]

    init(
        mode: BroadcastMode,
        evictOnLast: Bool = false,
        onFirst: (@Sendable (Key) async -> Void)? = nil,
        onLast: (@Sendable (Key) async -> Void)? = nil
    ) {
        self.mode = mode
        self.evictOnLast = evictOnLast
        self.makeOnFirst = onFirst
        self.makeOnLast = onLast
    }

    /// Returns an `AsyncStream` for the given key, creating a new
    /// `Broadcast` for that key if one does not already exist.
    ///
    /// `onFirst` is awaited inside `Broadcast.subscribe()` before this
    /// method returns, guaranteeing MQTT topic acquisition completes
    /// before the caller receives the stream.
    func subscribe(for key: Key) async -> AsyncStream<Element> {
        if let existing = broadcasts[key] {
            return await existing.subscribe()
        }
        let broadcast = makeBroadcast(for: key)
        broadcasts[key] = broadcast
        return await broadcast.subscribe()
    }

    /// Sends a value to all subscribers of the `Broadcast` registered
    /// under `key`. If no `Broadcast` exists for `key` (no subscriber
    /// has ever attached), the value is dropped silently — matching
    /// the former `EventHub.yield` behavior for keys with no registered
    /// stream. A producer racing ahead of the first subscriber thus
    /// loses the value, same as before.
    func send(_ value: Element, for key: Key) async {
        guard let broadcast = broadcasts[key] else { return }
        await broadcast.send(value)
    }

    /// Sends a state value, caching it for replay even if no subscriber
    /// is currently attached to the `Broadcast` for `key`. Creates a
    /// `Broadcast` for `key` if one does not exist.
    func sendState(_ value: Element, for key: Key) async {
        if broadcasts[key] == nil {
            let broadcast = makeBroadcast(for: key)
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

    // MARK: - Private

    private func makeBroadcast(for key: Key) -> Broadcast<Element> {
        Broadcast<Element>(
            mode: mode,
            onFirst: { [makeOnFirst, key] in await makeOnFirst?(key) },
            onLast: { [weak self, key, makeOnLast, evictOnLast] in
                if evictOnLast {
                    await self?.evict(key)
                }
                await makeOnLast?(key)
            }
        )
    }

    private func evict(_ key: Key) {
        broadcasts.removeValue(forKey: key)
    }
}
