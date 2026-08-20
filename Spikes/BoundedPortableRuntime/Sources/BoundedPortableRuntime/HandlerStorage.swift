// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

/// A stable numeric context handle used by the handler experiment.
public struct HandlerContext {
    /// Caller-owned context identity.
    public var handle: UInt32
    /// Generation protects reuse of a handle after removal.
    public var generation: UInt32
    /// Registration state.
    public var active: Bool

    /// Creates an active context.
    public init(handle: UInt32, generation: UInt32 = 1, active: Bool = true) {
        self.handle = handle
        self.generation = generation
        self.active = active
    }
}

/// A noncapturing function entry plus caller-owned numeric context.
public struct HandlerEntry {
    /// The callback receives only a stable context handle.
    public let function: @Sendable (UInt32) -> Void
    /// The numeric context identity.
    public let context: HandlerContext

    /// Creates an entry without a runtime-owned closure capture.
    public init(function: @escaping @Sendable (UInt32) -> Void, context: HandlerContext) {
        self.function = function
        self.context = context
    }
}

/// A bounded handler table backed by the same inline slot discipline.
public struct HandlerTable<let capacity: Int>: ~Copyable {
    private var entries: InlineSlotTable<HandlerEntry, capacity>

    /// Creates an empty handler table.
    public init() { entries = InlineSlotTable() }

    /// Registers a noncapturing entry.
    public mutating func register(_ entry: HandlerEntry) -> UInt64? { entries.insert(entry) }

    /// Dispatches a live entry and rejects stale tokens.
    public mutating func dispatch(_ token: UInt64) -> Bool {
        entries.update(token) { entry in entry.function(entry.context.handle) }
    }

    /// Removes a registration.
    public mutating func unregister(_ token: UInt64) -> Bool { entries.remove(token) }
}
