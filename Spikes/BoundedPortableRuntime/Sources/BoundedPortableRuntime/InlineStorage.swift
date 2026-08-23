// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

/// A fixed-capacity slot table used by the bounded-runtime probe.
public struct InlineSlotTable<Element, let capacity: Int>: ~Copyable {
    struct Slot {
        var generation: UInt32 = 0
        var active = false
        var value: Element?
    }

    private var slots: InlineArray<capacity, Slot>

    /// Creates an empty table with no heap-backed storage.
    public init() {
        self.slots = InlineArray(repeating: Slot())
    }

    /// The number of statically allocated slots.
    public var count: Int {
        var result = 0
        for index in 0..<capacity where slots[index].active { result += 1 }
        return result
    }

    /// Inserts a value, returning a generation-protected token.
    ///
    /// - Parameter value: Value stored directly in the first inactive slot.
    /// - Returns: A stable token, or `nil` when every slot is active.
    public mutating func insert(_ value: Element) -> UInt64? {
        for index in 0..<capacity {
            if !slots[index].active {
                let nextGeneration = slots[index].generation &+ 1
                slots[index].generation = nextGeneration
                slots[index].active = true
                slots[index].value = value
                return Self.makeToken(index: index, generation: nextGeneration)
            }
        }
        return nil
    }

    /// Mutates a live value in place and rejects stale tokens.
    ///
    /// - Parameters:
    ///   - token: Generation-protected token returned by ``insert(_:)``.
    ///   - body: Non-escaping mutation applied to the stored value.
    /// - Returns: Whether the token selected a live value.
    public mutating func update(_ token: UInt64, _ body: (inout Element) -> Void) -> Bool {
        let index = Self.index(from: token)
        guard index < capacity,
              slots[index].active,
              slots[index].generation == Self.generation(from: token),
              slots[index].value != nil else { return false }
        body(&slots[index].value!)
        return true
    }

    /// Removes a value and invalidates its token.
    ///
    /// - Parameter token: Generation-protected token returned by ``insert(_:)``.
    /// - Returns: Whether a matching live value was removed.
    public mutating func remove(_ token: UInt64) -> Bool {
        let index = Self.index(from: token)
        guard index < capacity,
              slots[index].active,
              slots[index].generation == Self.generation(from: token) else { return false }
        slots[index].active = false
        slots[index].value = nil
        return true
    }

    private static func makeToken(index: Int, generation: UInt32) -> UInt64 {
        UInt64(generation) << 32 | UInt64(index)
    }

    private static func index(from token: UInt64) -> Int { Int(token & 0xffff_ffff) }
    private static func generation(from token: UInt64) -> UInt32 { UInt32(token >> 32) }
}
