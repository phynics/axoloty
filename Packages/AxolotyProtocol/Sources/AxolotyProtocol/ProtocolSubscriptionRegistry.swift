// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyWire

private enum ProtocolSubscriptionLimits {
    static let maxKeyBytes = 128
}

/// The typed selector accepted by the protocol subscription registry.
public enum ProtocolSubscriptionSelector: Sendable, Equatable {
    /// Match every action in one capability family.
    case capability(ProtocolCapability)
    /// Match an Advertise filter; pass the filter bytes to registration.
    case advertise
    /// Match a Channel identifier; pass the identifier bytes to registration.
    case channel
    /// Match an IoValue actor endpoint.
    case ioActor(UUID16)
    /// Match a response capability and correlation identity.
    case correlated(ProtocolCapability, UUID16)
}

/// A slot-index-plus-generation subscription token.
public struct ProtocolSubscriptionToken: Sendable, Equatable {
    fileprivate let index: UInt32
    fileprivate let generation: UInt32

    fileprivate init(index: Int, generation: UInt32) {
        self.index = UInt32(index)
        self.generation = generation
    }
}

/// The result of one bounded subscription registration.
public enum ProtocolSubscriptionOutcome: Sendable, Equatable {
    /// A handler matched and was invoked synchronously.
    case delivered
    /// No registered selector matched the action.
    case mismatch
    /// Registration could not fit in the fixed table.
    case full
    /// The handler was inactive at registration time.
    case inactive
    /// The selector and key did not form a valid bounded registration.
    case invalid
}

/// The result of removing a subscription token.
public enum ProtocolUnregisterOutcome: Sendable, Equatable {
    /// The active slot was removed.
    case removed
    /// The token generation no longer identifies the slot.
    case stale
    /// The slot was already inactive.
    case inactive
}

/// Fixed-inline subscription storage shared by host and Embedded adapters.
///
/// Registration copies only bounded selector data. The registry never stores
/// closures or application objects; handlers are noncapturing thin functions
/// with caller-owned numeric contexts.
public struct ProtocolSubscriptionRegistry<let capacity: Int>: ~Copyable {
    private struct Slot {
        var generation: UInt32 = 0
        var retired = false
        var selector: ProtocolSubscriptionSelectorStorage = .empty
        var keyLength = 0
        var key = InlineArray<128, UInt8>(repeating: 0)
        var handler: ProtocolHandlerEntry?
    }

    private enum ProtocolSubscriptionSelectorStorage: Sendable {
        case empty
        case capability(ProtocolCapability)
        case advertise
        case channel
        case ioActor(UUID16)
        case correlated(ProtocolCapability, UUID16)
    }

    private var slots: InlineArray<capacity, Slot>

    /// Creates an empty registry with the compile-time capacity.
    public init() {
        slots = InlineArray(repeating: Slot())
    }

    /// Registers a selector and noncapturing handler.
    ///
    /// - Parameters:
    ///   - selector: Typed family or endpoint selector.
    ///   - key: Fixed bytes for Advertise and Channel selectors.
    ///   - handler: Caller-owned thin callback and numeric context.
    /// - Throws: ``ProtocolError`` when the handler is inactive, the key is
    ///   invalid, or the fixed table is full.
    /// - Returns: A generation-protected token for later removal.
    public mutating func register(
        selector: ProtocolSubscriptionSelector,
        key: ByteSlice? = nil,
        handler: ProtocolHandlerEntry
    ) throws(ProtocolError) -> ProtocolSubscriptionToken {
        guard handler.active else { throw ProtocolError(.malformedFrame) }
        let keyLength = key?.length ?? 0
        switch selector {
        case .advertise, .channel:
            guard key != nil, keyLength > 0, keyLength <= ProtocolSubscriptionLimits.maxKeyBytes else {
                throw ProtocolError(.malformedFrame)
            }
        default:
            guard key == nil else { throw ProtocolError(.malformedFrame) }
        }

        for index in 0..<capacity {
            guard slots[index].handler == nil, !slots[index].retired else { continue }
            guard slots[index].generation < UInt32.max else {
                slots[index].retired = true
                continue
            }
            slots[index].generation &+= 1
            slots[index].selector = Self.storage(for: selector)
            slots[index].keyLength = keyLength
            if let key {
                for offset in 0..<keyLength { slots[index].key[offset] = key.byte(at: offset) ?? 0 }
            }
            var stored = handler
            stored.generation = slots[index].generation
            slots[index].handler = stored
            return ProtocolSubscriptionToken(index: index, generation: slots[index].generation)
        }
        throw ProtocolError(.capacityExceeded)
    }

    /// Removes a live subscription and rejects stale generations.
    public mutating func unregister(_ token: ProtocolSubscriptionToken) -> ProtocolUnregisterOutcome {
        let index = Int(token.index)
        guard index >= 0, index < capacity, slots[index].generation == token.generation else { return .stale }
        guard slots[index].handler != nil else { return .inactive }
        slots[index].handler = nil
        if slots[index].generation == UInt32.max { slots[index].retired = true }
        return .removed
    }

    /// Dispatches a borrowed action to every matching active handler.
    public mutating func dispatch(_ action: BorrowedProtocolAction) -> ProtocolSubscriptionOutcome {
        var delivered = false
        for index in 0..<capacity {
            guard let handler = slots[index].handler,
                  handler.active,
                  handler.generation == slots[index].generation,
                  Self.matches(slots[index], action: action) else { continue }
            handler.invoke(topic: action.topic, payload: action.payload)
            delivered = true
        }
        return delivered ? .delivered : .mismatch
    }

    private static func storage(for selector: ProtocolSubscriptionSelector) -> ProtocolSubscriptionSelectorStorage {
        switch selector {
        case .capability(let capability): return .capability(capability)
        case .advertise: return .advertise
        case .channel: return .channel
        case .ioActor(let identity): return .ioActor(identity)
        case .correlated(let capability, let identity): return .correlated(capability, identity)
        }
    }

    private static func matches(_ slot: Slot, action: BorrowedProtocolAction) -> Bool {
        switch slot.selector {
        case .empty: return false
        case .capability(let capability): return capability == action.routingKey.capability
        case .ioActor(let actor):
            if case .ioActor(let actionActor) = action.deliveryKey { return actor == actionActor }
            return false
        case .correlated(let capability, let correlation):
            if case .correlated(let actionCapability, let actionCorrelation) = action.deliveryKey {
                return capability == actionCapability && correlation == actionCorrelation
            }
            return false
        case .advertise:
            guard case .advertiseFilter(let filter) = action.deliveryKey else { return false }
            return Self.bytesEqual(slot.key, length: slot.keyLength, filter)
        case .channel:
            guard case .channel(let channel) = action.deliveryKey else { return false }
            return Self.bytesEqual(slot.key, length: slot.keyLength, channel)
        }
    }

    private static func bytesEqual(
        _ stored: InlineArray<128, UInt8>,
        length: Int,
        _ borrowed: ByteSlice
    ) -> Bool {
        guard length == borrowed.length else { return false }
        for offset in 0..<length {
            guard let byte = borrowed.byte(at: offset), stored[offset] == byte else { return false }
        }
        return true
    }
}
