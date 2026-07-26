// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

/// A fixed-capacity, allocation-free subscriber registry for synchronous
/// message dispatch.
///
/// Replaces the `Broadcast<Element>` actor (which uses a heap-allocated
/// dictionary of `AsyncStream` continuations) with a fixed-size array of
/// subscriber callbacks. Dispatch is synchronous — no actor hop, no
/// `AsyncStream`, no heap allocation in the steady state.
///
/// When the subscriber count reaches `maxSubscribers`, the next subscribe
/// call returns nil instead of growing a heap array. The embedded target
/// tunes `maxSubscribers` via `WireBufferConfig`.
public struct StaticDispatchTable: Sendable {
    private var slots: [Slot]
    private var capacity: Int

    private struct Slot: Sendable {
        var active: Bool
        var handler: (@Sendable (BorrowedMessage) -> Void)?
    }

    /// A subscriber token used to unsubscribe.
    public struct Token: Equatable {
        let index: Int
    }

    /// Creates a dispatch table with the given maximum subscriber count.
    public init(capacity: Int = WireBufferConfig.maxSubscribers) {
        self.capacity = capacity
        self.slots = (0..<capacity).map { _ in Slot(active: false, handler: nil) }
    }

    /// Subscribes a handler. Returns a token for later unsubscribe, or nil
    /// if the table is full.
    public mutating func subscribe(
        _ handler: @Sendable @escaping (BorrowedMessage) -> Void
    ) -> Token? {
        for i in 0..<capacity {
            if !slots[i].active {
                slots[i] = Slot(active: true, handler: handler)
                return Token(index: i)
            }
        }
        return nil
    }

    /// Removes the subscriber identified by `token`.
    public mutating func unsubscribe(_ token: Token) {
        guard token.index < capacity else { return }
        slots[token.index] = Slot(active: false, handler: nil)
    }

    /// Dispatches `message` to all active subscribers synchronously.
    public func dispatch(_ message: BorrowedMessage) {
        for i in 0..<capacity {
            if slots[i].active, let handler = slots[i].handler {
                handler(message)
            }
        }
    }

    /// The number of active subscribers.
    public var subscriberCount: Int {
        slots.reduce(0) { $0 + ($1.active ? 1 : 0) }
    }
}
