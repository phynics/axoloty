// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

/// Caller-owned destination for synchronous protocol actions.
public protocol ProtocolActionSink: ~Copyable {
    /// Remaining action slots available to the processor.
    var remainingCapacity: Int { get }
    /// Largest payload that the sink can retain in one action.
    var maximumPayloadBytes: Int { get }
    /// Admits all slots needed for one atomic processor operation.
    /// - Parameter actionCount: Number of actions the processor will append.
    /// - Returns: `true` when the complete operation fits. A sink may reserve
    ///   those slots until append; failed admission leaves it unchanged.
    mutating func preflight(actionCount: Int) -> Bool
    /// Accepts one borrowed action into the sink's storage policy.
    /// - Parameter action: Action whose borrowed payload remains owned by the
    ///   caller. A retaining sink must copy every borrowed byte.
    /// - Returns: `true` when the action was appended, or `false` when no
    ///   preflighted slot remains.
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
    /// This borrowed sink does not copy payload bytes.
    public var maximumPayloadBytes: Int { Int.max }
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

/// A reusable contiguous host sink with the same bounded interface as the
/// Embedded sink and the host-default capacity. Its backing storage is
/// retained across operations so warmed host probes do not repeatedly grow it.
public struct ReusableProtocolActionSink: ProtocolActionSink {
    private var storage: [BorrowedProtocolAction]
    private let capacity: Int
    private var operationCapacity: Int

    /// Creates a reusable sink with the requested bounded capacity.
    public init(capacity: Int = 64) {
        self.capacity = max(0, capacity)
        self.operationCapacity = max(0, capacity)
        self.storage = []
        self.storage.reserveCapacity(max(0, capacity))
    }

    /// Number of actions currently stored.
    public var count: Int { storage.count }
    /// This borrowed sink does not copy payload bytes.
    public var maximumPayloadBytes: Int { Int.max }
    /// Remaining action slots available to the next operation.
    public var remainingCapacity: Int { operationCapacity - storage.count }

    /// Clears retained actions and bounds the next operation by downstream capacity.
    /// - Parameter maximumActionCount: Complete action count the downstream
    ///   dispatcher can accept without loss.
    public mutating func prepare(maximumActionCount: Int) {
        storage.removeAll(keepingCapacity: true)
        operationCapacity = min(capacity, max(0, maximumActionCount))
    }

    /// Checks capacity without changing the sink.
    public mutating func preflight(actionCount: Int) -> Bool {
        actionCount >= 0 && actionCount <= remainingCapacity
    }

    /// Appends a borrowed action while retaining the preallocated buffer.
    public mutating func append(_ action: BorrowedProtocolAction) -> Bool {
        guard storage.count < operationCapacity else { return false }
        storage.append(action)
        return true
    }

    /// Returns a borrowed action by slot index.
    public subscript(index: Int) -> BorrowedProtocolAction? {
        guard index >= 0, index < storage.count else { return nil }
        return storage[index]
    }

    /// Removes all actions while retaining contiguous host capacity.
    public mutating func removeAll() {
        storage.removeAll(keepingCapacity: true)
        operationCapacity = capacity
    }
}
