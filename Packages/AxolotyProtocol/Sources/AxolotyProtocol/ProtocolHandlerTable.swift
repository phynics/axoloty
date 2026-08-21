// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

/// A noncapturing callback entry owned by the caller of a handler table.
public struct ProtocolHandlerEntry {
    /// The thin function receives only the numeric caller context.
    public let function: @convention(thin) (UInt32) -> Void
    /// Caller-owned context identity and generation.
    public var context: UInt32
    /// Generation used to reject stale registrations.
    public var generation: UInt32
    /// Whether dispatch is currently permitted.
    public var active: Bool

    /// Creates a noncapturing handler entry.
    public init(
        function: @escaping @convention(thin) (UInt32) -> Void,
        context: UInt32,
        generation: UInt32 = 1,
        active: Bool = true
    ) {
        self.function = function
        self.context = context
        self.generation = generation
        self.active = active
    }
}

/// An inline handler table with generation-protected tokens.
public struct ProtocolHandlerTable<let capacity: Int>: ~Copyable {
    private struct Slot {
        var entry: ProtocolHandlerEntry?
        var generation: UInt32 = 0
    }
    private var slots: InlineArray<capacity, Slot>

    /// Creates an empty handler table.
    public init() { slots = InlineArray(repeating: Slot()) }

    /// Registers an active noncapturing callback.
    public mutating func register(_ entry: ProtocolHandlerEntry) -> UInt64? {
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
    public mutating func dispatch(_ token: UInt64) -> Bool {
        let index = Int(token & 0xffff_ffff)
        let generation = UInt32(token >> 32)
        guard index < capacity, let entry = slots[index].entry,
              entry.active, entry.generation == generation,
              slots[index].generation == generation else { return false }
        entry.function(entry.context)
        return true
    }

    /// Deactivates and removes a live token.
    public mutating func unregister(_ token: UInt64) -> Bool {
        let index = Int(token & 0xffff_ffff)
        let generation = UInt32(token >> 32)
        guard index < capacity, slots[index].entry?.generation == generation else { return false }
        slots[index].entry = nil
        return true
    }
}
