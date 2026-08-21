// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

/// Caller-owned destination for synchronous protocol actions.
public protocol ProtocolActionSink: ~Copyable {
    /// Remaining action slots available to the processor.
    var remainingCapacity: Int { get }
    /// Reserves all slots needed for one atomic processor operation.
    mutating func preflight(actionCount: Int) -> Bool
    /// Appends a borrowed action without copying its payload.
    mutating func append(_ action: BorrowedProtocolAction) -> Bool
}

/// A fixed inline action sink for Embedded Swift and bounded tests.
public struct InlineProtocolActionSink<let capacity: Int>: ~Copyable, ProtocolActionSink {
    private var slots: InlineArray<capacity, BorrowedProtocolAction?>
    private var used = 0

    /// Creates an empty sink.
    public init() { slots = InlineArray(repeating: nil) }

    /// Number of actions currently stored.
    public var count: Int { used }
    /// Remaining capacity before the next atomic operation.
    public var remainingCapacity: Int { capacity - used }

    /// Checks capacity without changing the sink.
    public mutating func preflight(actionCount: Int) -> Bool {
        actionCount >= 0 && actionCount <= remainingCapacity
    }

    /// Stores a borrowed action in the next inline slot.
    public mutating func append(_ action: BorrowedProtocolAction) -> Bool {
        guard used < capacity else { return false }
        slots[used] = action
        used += 1
        return true
    }

    /// Returns a borrowed action by slot index.
    public subscript(index: Int) -> BorrowedProtocolAction? {
        guard index >= 0, index < used else { return nil }
        return slots[index]
    }

    /// Removes all actions while retaining the caller-owned storage.
    public mutating func removeAll() {
        for index in 0..<used { slots[index] = nil }
        used = 0
    }
}

/// A reusable host sink with the same bounded interface as the Embedded sink.
public typealias ReusableProtocolActionSink = InlineProtocolActionSink<64>
