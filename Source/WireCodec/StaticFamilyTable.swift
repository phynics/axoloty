// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

/// A fixed-capacity, keyed subscriber registry for synchronous dispatch to
/// a subset of subscribers matching a key.
///
/// Replaces the `BroadcastFamily<Key, Element>` actor (which uses a
/// heap-allocated dictionary of `AsyncStream` continuations keyed by `Key`)
/// with a fixed-size open-addressing table. Each entry holds a small
/// `StaticDispatchTable` for its subscribers.
///
/// Used for Advertise (keyed by event-type filter), Channel (keyed by
/// channel ID), and response streams (keyed by correlation ID).
public struct StaticFamilyTable<Key: Hashable & Sendable> {
    private var entries: [Entry?]
    private var capacity: Int
    private var entryCapacity: Int

    private struct Entry {
        var key: Key
        var table: StaticDispatchTable
    }

    /// A subscriber token carrying both the entry index and the inner token.
    public struct Token: Equatable {
        let entryIndex: Int
        let inner: StaticDispatchTable.Token
    }

    /// Creates a family table with the given maximum entries and subscribers
    /// per entry.
    public init(
        maxEntries: Int = WireBufferConfig.maxFamilyEntries,
        maxSubscribersPerEntry: Int = WireBufferConfig.maxFamilySubscribers
    ) {
        self.capacity = maxEntries
        self.entryCapacity = maxSubscribersPerEntry
        self.entries = Array(repeating: nil, count: maxEntries)
    }

    /// Subscribes a handler for the given key. Returns a token for later
    /// unsubscribe, or nil if the table is full.
    public mutating func subscribe(
        key: Key,
        _ handler: @Sendable @escaping (BorrowedMessage) -> Void
    ) -> Token? {
        // Find existing entry for this key
        for i in 0..<capacity {
            if var entry = entries[i], entry.key == key {
                if let inner = entry.table.subscribe(handler) {
                    entries[i] = entry
                    return Token(entryIndex: i, inner: inner)
                }
                return nil
            }
        }
        // Find free slot for a new entry
        for i in 0..<capacity {
            if entries[i] == nil {
                var table = StaticDispatchTable(capacity: entryCapacity)
                guard let inner = table.subscribe(handler) else { return nil }
                entries[i] = Entry(key: key, table: table)
                return Token(entryIndex: i, inner: inner)
            }
        }
        return nil
    }

    /// Removes the subscriber identified by `token`.
    public mutating func unsubscribe(_ token: Token) {
        guard token.entryIndex < capacity else { return }
        entries[token.entryIndex]?.table.unsubscribe(token.inner)
        // If the entry has no more subscribers, free the slot
        if entries[token.entryIndex]?.table.subscriberCount == 0 {
            entries[token.entryIndex] = nil
        }
    }

    /// Dispatches `message` to all subscribers matching `key`.
    public func dispatch(key: Key, _ message: BorrowedMessage) {
        for i in 0..<capacity {
            if let entry = entries[i], entry.key == key {
                entry.table.dispatch(message)
            }
        }
    }

    /// Dispatches `message` to all subscribers regardless of key.
    /// Used for deadvertise (broadcast to all family entries).
    public func dispatchAll(_ message: BorrowedMessage) {
        for i in 0..<capacity {
            if let entry = entries[i] {
                entry.table.dispatch(message)
            }
        }
    }

    /// The number of active entries (keys with at least one subscriber).
    public var entryCount: Int {
        entries.reduce(0) { $0 + ($1 != nil ? 1 : 0) }
    }
}
