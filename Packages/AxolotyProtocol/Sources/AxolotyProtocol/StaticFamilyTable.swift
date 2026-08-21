// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyWire

/// A fixed-capacity, keyed subscriber registry for synchronous dispatch to
/// a subset of subscribers matching a key.
///
/// Replaces the `BroadcastFamily<Key, Element>` actor (which uses a
/// heap-allocated dictionary of `AsyncStream` continuations keyed by `Key`)
/// with a fixed-size open-addressing table. Each entry holds a small
/// `StaticDispatchTable` for its subscribers. The steady-state dispatch path
/// performs no allocation; construction and key insertion allocate the fixed
/// capacity.
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

    /// An opaque, sendable handle for removing one keyed subscription.
    ///
    /// A token identifies one keyed subscription. Copying a populated family
    /// table copies that subscription, so its token can remove the inherited
    /// subscription independently from either value. Subscriptions created
    /// after copied values diverge have distinct issuers and cannot remove one
    /// another. A token is inert in a value after successful unsubscribe or
    /// entry reuse.
    public struct Token: Equatable, Sendable {
        let entryIndex: Int
        let inner: StaticDispatchTable.Token

        internal func replacingEntryIndexForTesting(_ entryIndex: Int) -> Token {
            Token(entryIndex: entryIndex, inner: inner)
        }
    }

    /// Creates a family table with the given maximum entries and subscribers
    /// per entry.
    ///
    /// - Parameters:
    ///   - maxEntries: The maximum number of keyed entries. Must be non-negative
    ///     and no greater than ``WireBufferConfig/maxFamilyEntries``.
    ///   - maxSubscribersPerEntry: The maximum number of subscribers per entry.
    ///     Must be non-negative and no greater than
    ///     ``WireBufferConfig/maxFamilySubscribers``.
    /// - Throws: ``WireCapacityError`` if either capacity is negative or exceeds
    ///   its configured maximum.
    public init(
        maxEntries: Int = ProtocolBufferConfig.maxFamilyEntries,
        maxSubscribersPerEntry: Int = ProtocolBufferConfig.maxFamilySubscribers
    ) throws(ProtocolCapacityError) {
        if maxEntries < 0 {
            throw ProtocolCapacityError(.negativeCapacity, parameter: "maxEntries")
        }
        if maxEntries > ProtocolBufferConfig.maxFamilyEntries {
            throw ProtocolCapacityError(.exceedsMaximum, parameter: "maxEntries")
        }
        if maxSubscribersPerEntry < 0 {
            throw ProtocolCapacityError(.negativeCapacity, parameter: "maxSubscribersPerEntry")
        }
        if maxSubscribersPerEntry > ProtocolBufferConfig.maxFamilySubscribers {
            throw ProtocolCapacityError(.exceedsMaximum, parameter: "maxSubscribersPerEntry")
        }
        self.capacity = maxEntries
        self.entryCapacity = maxSubscribersPerEntry
        self.entries = Array(repeating: nil, count: maxEntries)
    }

    /// Creates a family table with caller-guaranteed-valid capacities, without
    /// re-validating. Used by ``EmbeddedMessageRouter`` after it has validated the
    /// router-level capacity arguments.
    internal init(
        prevalidatedMaxEntries maxEntries: Int,
        prevalidatedMaxSubscribers maxSubscribersPerEntry: Int
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
            guard entries[i]?.key == key else { continue }
            guard let inner = entries[i]?.table.subscribe(handler) else { return nil }
            return Token(entryIndex: i, inner: inner)
        }
        // Find free slot for a new entry
        for i in 0..<capacity where entries[i] == nil {
            var table = StaticDispatchTable(prevalidated: entryCapacity)
            guard let inner = table.subscribe(handler) else { return nil }
            entries[i] = Entry(key: key, table: table)
            return Token(entryIndex: i, inner: inner)
        }
        return nil
    }

    /// Removes the subscriber identified by `token`.
    public mutating func unsubscribe(_ token: Token) {
        guard token.entryIndex >= 0, token.entryIndex < capacity else { return }
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

    /// Dispatches `message` to subscribers whose key satisfies `matches`.
    ///
    /// Use this overload when the lookup value is a borrowed representation
    /// such as a ``ByteSlice`` and creating an owned `Key` solely for the
    /// lookup would allocate.
    ///
    /// - Parameters:
    ///   - matches: A synchronous predicate evaluated for each active key.
    ///   - message: The borrowed message to dispatch.
    public func dispatch(
        matching matches: (Key) -> Bool,
        _ message: BorrowedMessage
    ) {
        for i in 0..<capacity where entries[i].map({ matches($0.key) }) == true {
            entries[i]?.table.dispatch(message)
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

extension StaticFamilyTable where Key == String {

    /// Dispatches `message` to all subscribers whose stored `String` key
    /// matches the given byte slice, without allocating a `String` from the
    /// slice.
    ///
    /// The stored keys remain owned `String` values (they must outlive the
    /// borrowed message); only the lookup avoids the per-dispatch `String`
    /// allocation by comparing the slice bytes against each stored key's
    /// UTF-8 view directly.
    public func dispatch(byBytes keyBytes: ByteSlice, _ message: BorrowedMessage) {
        for i in 0..<capacity {
            guard let entry = entries[i] else { continue }
            if Self.string(entry.key, equals: keyBytes) {
                entry.table.dispatch(message)
            }
        }
    }

    @inline(__always)
    private static func string(_ s: String, equals slice: ByteSlice) -> Bool {
        let utf8 = s.utf8
        guard utf8.count == slice.length else { return false }
        var idx = utf8.startIndex
        for i in 0..<slice.length {
            if utf8[idx] != slice.byte(at: i) { return false }
            utf8.formIndex(after: &idx)
        }
        return true
    }
}
