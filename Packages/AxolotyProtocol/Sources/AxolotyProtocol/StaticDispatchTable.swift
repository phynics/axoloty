// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyWire

/// A fixed-capacity subscriber registry for synchronous message dispatch.
///
/// Replaces the `Broadcast<Element>` actor (which uses a heap-allocated
/// dictionary of `AsyncStream` continuations) with a fixed-size array of
/// subscriber callbacks. Dispatch is synchronous — no actor hop, no
/// `AsyncStream`, no heap allocation in the steady state. Construction
/// allocates the fixed capacity once; per-dispatch/steady-state work does not
/// allocate.
///
/// When the subscriber count reaches `maxSubscribers`, the next subscribe
/// call returns nil instead of growing a heap array. The embedded target
/// tunes `maxSubscribers` via ``ProtocolBufferConfig``.
public struct StaticDispatchTable: Sendable {
    private typealias Handler = @Sendable (BorrowedMessage) -> Void

    fileprivate final class Identity: Equatable, Sendable {
        static func == (lhs: Identity, rhs: Identity) -> Bool {
            lhs === rhs
        }
    }

    /// Mutable storage is never shared across a mutation: ``ensureUniqueStorage()``
    /// detaches it first. The unchecked conformance expresses that COW invariant.
    private final class Storage: @unchecked Sendable {
        let branchIdentity: Identity
        var slots: [Slot]

        init(capacity: Int, initialGeneration: UInt16) {
            self.branchIdentity = Identity()
            self.slots = (0..<capacity).map { _ in
                Slot(issuerIdentity: nil, generation: initialGeneration, handler: nil)
            }
        }

        init(copying other: Storage) {
            self.branchIdentity = Identity()
            self.slots = other.slots
        }
    }

    private var storage: Storage

    private struct Slot: Sendable {
        var issuerIdentity: Identity?
        var generation: UInt16
        var handler: Handler?
    }

    /// An opaque, sendable handle for removing one subscription.
    ///
    /// A token identifies one subscription by its immutable issuer, slot, and
    /// generation. Copying a populated table copies that subscription, so its
    /// token can remove the inherited subscription independently from either
    /// value. When either value mutates, it detaches with a fresh branch identity;
    /// subscriptions created after the values diverge cannot remove one another.
    /// A token becomes inert in a value after successful unsubscribe or when
    /// its slot's generation is exhausted.
    ///
    /// Tokens retain only an immutable identity marker; they do not retain the
    /// table's handlers or mutable storage.
    public struct Token: Equatable, Sendable {
        fileprivate let issuerIdentity: Identity
        let index: Int
        let generation: UInt16

        internal func replacingIndexForTesting(_ index: Int) -> Token {
            Token(issuerIdentity: issuerIdentity, index: index, generation: generation)
        }
    }

    /// Creates a dispatch table with the given maximum subscriber count.
    ///
    /// - Parameter capacity: The maximum number of active subscribers. Must be
    ///   non-negative and no greater than ``ProtocolBufferConfig/maxSubscribers``.
    /// - Throws: ``ProtocolCapacityError`` if `capacity` is negative or exceeds the
    ///   configured maximum.
    public init(capacity: Int = ProtocolBufferConfig.maxSubscribers) throws(ProtocolCapacityError) {
        try Self.validateCapacity(
            capacity, maximum: ProtocolBufferConfig.maxSubscribers, parameter: "capacity"
        )
        self.storage = Storage(capacity: capacity, initialGeneration: 0)
    }

    internal init(capacity: Int, initialGenerationForTesting: UInt16) throws(ProtocolCapacityError) {
        try Self.validateCapacity(
            capacity, maximum: ProtocolBufferConfig.maxSubscribers, parameter: "capacity"
        )
        self.storage = Storage(
            capacity: capacity,
            initialGeneration: initialGenerationForTesting
        )
    }

    /// Creates a dispatch table with a caller-guaranteed-valid capacity, without
    /// re-validating. Used for per-family entry tables whose capacity was already
    /// validated by ``StaticFamilyTable`` construction.
    internal init(prevalidated capacity: Int, initialGeneration: UInt16 = 0) {
        self.storage = Storage(capacity: capacity, initialGeneration: initialGeneration)
    }

    private static func validateCapacity(
        _ value: Int, maximum: Int, parameter: StaticString
    ) throws(ProtocolCapacityError) {
        if value < 0 { throw ProtocolCapacityError(.negativeCapacity, parameter: parameter) }
        if value > maximum { throw ProtocolCapacityError(.exceedsMaximum, parameter: parameter) }
    }

    /// Validates the router-level capacity arguments before any table is built.
    internal static func validateCapacityForRouter(
        _ maxSubscribers: Int,
        _ maxFamilyEntries: Int,
        _ maxFamilySubscribers: Int
    ) throws(ProtocolCapacityError) {
        try validateCapacity(
            maxSubscribers,
            maximum: ProtocolBufferConfig.maxSubscribers,
            parameter: "maxSubscribers"
        )
        try validateCapacity(
            maxFamilyEntries,
            maximum: ProtocolBufferConfig.maxFamilyEntries,
            parameter: "maxFamilyEntries"
        )
        try validateCapacity(
            maxFamilySubscribers,
            maximum: ProtocolBufferConfig.maxFamilySubscribers,
            parameter: "maxFamilySubscribers"
        )
    }

    /// Subscribes a handler. Returns a token for later unsubscribe, or nil
    /// if the table is full.
    public mutating func subscribe(
        _ handler: @Sendable @escaping (BorrowedMessage) -> Void
    ) -> Token? {
        ensureUniqueStorage()
        for i in storage.slots.indices {
            guard storage.slots[i].handler == nil,
                  storage.slots[i].generation < UInt16.max else { continue }

            storage.slots[i].generation += 1
            storage.slots[i].issuerIdentity = storage.branchIdentity
            storage.slots[i].handler = handler
            return Token(
                issuerIdentity: storage.branchIdentity,
                index: i,
                generation: storage.slots[i].generation
            )
        }
        return nil
    }

    /// Removes the subscriber identified by `token`.
    public mutating func unsubscribe(_ token: Token) {
        ensureUniqueStorage()
        guard token.index >= storage.slots.startIndex,
              token.index < storage.slots.endIndex,
              storage.slots[token.index].handler != nil,
              storage.slots[token.index].issuerIdentity == token.issuerIdentity,
              storage.slots[token.index].generation == token.generation else { return }
        storage.slots[token.index].handler = nil
        storage.slots[token.index].issuerIdentity = nil
    }

    /// Dispatches `message` to all active subscribers synchronously.
    ///
    /// Iteration uses explicit indices over the fixed slot storage rather than
    /// a sequence iterator so the steady-state dispatch path performs no
    /// allocation (issue #490).
    public func dispatch(_ message: BorrowedMessage) {
        let slots = storage.slots
        var index = slots.startIndex
        let end = slots.endIndex
        while index < end {
            if let handler = slots[index].handler {
                handler(message)
            }
            index &+= 1
        }
    }

    /// The number of active subscribers.
    public var subscriberCount: Int {
        storage.slots.reduce(0) { $0 + ($1.handler == nil ? 0 : 1) }
    }

    internal static var slotStrideForTesting: Int {
        MemoryLayout<Slot>.stride
    }

    private mutating func ensureUniqueStorage() {
        guard !isKnownUniquelyReferenced(&storage) else { return }
        storage = Storage(copying: storage)
    }
}
