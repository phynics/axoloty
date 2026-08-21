// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyWire

/// A thin handler receiving caller context and borrowed wire buffers.
public typealias ProtocolHandlerFunction = @convention(thin) (
    UInt32,
    UnsafePointer<UInt8>?, Int,
    UnsafePointer<UInt8>?, Int
) -> Void

/// A noncapturing callback entry owned by the caller of a handler table.
public struct ProtocolHandlerEntry {
    /// The thin callback receives the numeric context and borrowed buffers.
    public let function: ProtocolHandlerFunction
    /// Caller-owned context identity. The table never owns the referenced object.
    public var context: UInt32
    /// Generation used to reject stale registrations.
    public var generation: UInt32
    /// Whether dispatch is currently permitted.
    public var active: Bool

    /// Creates a noncapturing handler entry.
    ///
    /// - Parameters:
    ///   - function: Thin callback invoked with `context` and borrowed buffers.
    ///   - context: Caller-owned numeric context handle.
    ///   - generation: Initial generation supplied by the caller.
    ///   - active: Whether the entry may be registered.
    public init(
        function: @escaping ProtocolHandlerFunction,
        context: UInt32,
        generation: UInt32 = 1,
        active: Bool = true
    ) {
        self.function = function
        self.context = context
        self.generation = generation
        self.active = active
    }

    @inline(__always)
    func invoke(_ message: BorrowedMessage) {
        message.topic.withBytes { topicBytes, topicLength in
            message.payload.withBytes { payloadBytes, payloadLength in
                function(
                    context,
                    topicBytes.assumingMemoryBound(to: UInt8.self), topicLength,
                    payloadBytes.assumingMemoryBound(to: UInt8.self), payloadLength
                )
            }
        }
    }

    /// Invokes the entry with borrowed normalized buffers.
    @inline(__always)
    func invoke(topic: ByteSlice?, payload: ByteSlice) {
        if let topic {
            topic.withBytes { topicBytes, topicLength in
                payload.withBytes { payloadBytes, payloadLength in
                    function(
                        context,
                        topicBytes.assumingMemoryBound(to: UInt8.self), topicLength,
                        payloadBytes.assumingMemoryBound(to: UInt8.self), payloadLength
                    )
                }
            }
        } else {
            payload.withBytes { payloadBytes, payloadLength in
                function(
                    context, nil, 0,
                    payloadBytes.assumingMemoryBound(to: UInt8.self), payloadLength
                )
            }
        }
    }
}

/// An inline handler table with generation-protected tokens.
struct ProtocolHandlerTable<let capacity: Int>: ~Copyable {
    private struct Slot {
        var entry: ProtocolHandlerEntry?
        var generation: UInt32 = 0
    }
    private var slots: InlineArray<capacity, Slot>

    /// Creates an empty handler table.
    init() { slots = InlineArray(repeating: Slot()) }

    /// Registers an active noncapturing callback.
    ///
    /// - Parameter entry: Callback entry whose context remains caller-owned.
    /// - Returns: A generation-protected token, or `nil` when the table is full.
    mutating func register(_ entry: ProtocolHandlerEntry) -> UInt64? {
        guard entry.active else { return nil }
        for index in 0..<capacity where slots[index].entry == nil {
            slots[index].generation &+= 1
            var stored = entry
            stored.generation = slots[index].generation
            slots[index].entry = stored
            return UInt64(slots[index].generation) << 32 | UInt64(index)
        }
        return nil
    }

    /// Dispatches a live token and rejects stale or inactive contexts.
    ///
    /// - Parameter token: Token returned by ``register(_:)``.
    /// - Returns: `true` only when a live callback was invoked.
    mutating func dispatch(_ token: UInt64) -> Bool {
        let index = Int(token & 0xffff_ffff)
        let generation = UInt32(token >> 32)
        guard index < capacity, let entry = slots[index].entry,
              entry.active, entry.generation == generation,
              slots[index].generation == generation else { return false }
        entry.function(entry.context, nil, 0, nil, 0)
        return true
    }

    /// Dispatches a live token with a borrowed wire message.
    ///
    /// - Parameters:
    ///   - token: Token returned by ``register(_:)``.
    ///   - message: Borrowed message valid only for the synchronous callback.
    /// - Returns: `true` only when a live callback was invoked.
    mutating func dispatch(_ token: UInt64, message: BorrowedMessage) -> Bool {
        let index = Int(token & 0xffff_ffff)
        let generation = UInt32(token >> 32)
        guard index < capacity, let entry = slots[index].entry,
              entry.active, entry.generation == generation,
              slots[index].generation == generation else { return false }
        entry.invoke(message)
        return true
    }

    /// Deactivates and removes a live token.
    ///
    /// - Parameter token: Token returned by ``register(_:)``.
    /// - Returns: `true` when the token identified an active table entry.
    mutating func unregister(_ token: UInt64) -> Bool {
        let index = Int(token & 0xffff_ffff)
        let generation = UInt32(token >> 32)
        guard index < capacity, slots[index].entry?.generation == generation else { return false }
        slots[index].entry = nil
        return true
    }
}
