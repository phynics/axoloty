// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

/// A stable numeric context handle used by the handler experiment.
public struct HandlerContext {
    /// Caller-owned context identity.
    public var handle: UInt32
    /// Generation protects reuse of a handle after removal.
    public var generation: UInt32
    /// Registration state.
    public var active: Bool

    /// Creates a caller-owned context.
    ///
    /// - Parameters:
    ///   - handle: Stable numeric identity passed to the callback.
    ///   - generation: Initial caller generation. Registration replaces this
    ///     with the slot generation used by the returned token.
    ///   - active: Whether the context may be registered and dispatched.
    public init(handle: UInt32, generation: UInt32 = 1, active: Bool = true) {
        self.handle = handle
        self.generation = generation
        self.active = active
    }
}

/// A noncapturing function entry plus caller-owned numeric context.
public struct HandlerEntry {
    /// The callback receives only a stable context handle.
    /// The C calling convention makes captured Swift contexts unrepresentable.
    public let function: @convention(c) (UInt32) -> Void
    /// The numeric context identity.
    public var context: HandlerContext

    /// Creates an entry without a runtime-owned closure capture.
    ///
    /// - Parameters:
    ///   - function: Noncapturing callback invoked during dispatch.
    ///   - context: Caller-owned numeric context.
    public init(function: @escaping @convention(c) (UInt32) -> Void, context: HandlerContext) {
        self.function = function
        self.context = context
    }
}

/// A bounded handler table backed by the same inline slot discipline.
public struct HandlerTable<let capacity: Int>: ~Copyable {
    private var entries: InlineSlotTable<HandlerEntry, capacity>

    /// Creates an empty handler table.
    public init() { entries = InlineSlotTable() }

    /// Registers an active, noncapturing entry.
    ///
    /// - Parameter entry: Entry whose context is owned by the caller.
    /// - Returns: A generation-protected token, or `nil` when the entry is
    ///   inactive or the table is full.
    public mutating func register(_ entry: HandlerEntry) -> UInt64? {
        guard entry.context.active, let token = entries.insert(entry) else { return nil }
        let generation = UInt32(token >> 32)
        guard entries.update(token, { $0.context.generation = generation }) else {
            _ = entries.remove(token)
            return nil
        }
        return token
    }

    /// Dispatches a live entry and rejects inactive or stale contexts.
    ///
    /// - Parameter token: Generation-protected token returned by ``register(_:)``.
    /// - Returns: `true` only when the matching live callback was invoked.
    public mutating func dispatch(_ token: UInt64) -> Bool {
        let generation = UInt32(token >> 32)
        var dispatched = false
        let found = entries.update(token) { entry in
            guard entry.context.active, entry.context.generation == generation else { return }
            entry.function(entry.context.handle)
            dispatched = true
        }
        return found && dispatched
    }

    /// Deactivates and removes a registration.
    ///
    /// - Parameter token: Generation-protected token returned by ``register(_:)``.
    /// - Returns: Whether a matching live entry was removed.
    public mutating func unregister(_ token: UInt64) -> Bool {
        guard entries.update(token, { $0.context.active = false }) else { return false }
        return entries.remove(token)
    }
}
