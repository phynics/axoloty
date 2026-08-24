// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@_spi(AxolotyRuntimeAdapter) import AxolotyProtocol
import AxolotyObjectModel

enum StaticIoEndpointRole: UInt8 {
    case source
    case actor
}

struct StaticIoEndpointRecord {
    var active: Bool
    var id: ObjectID
    var generation: UInt32
    var role: StaticIoEndpointRole
    var representation: IoValueRepresentation
    var objectBytes: BoundedIoBytes<512>
    var publication: IoPublicationPolicy
    var machine: IoPublicationStateMachine
    var inFlight: Bool

    static var empty: Self {
        Self(
            active: false,
            id: ObjectID(uuid: .zero),
            generation: 1,
            role: .source,
            representation: .json,
            objectBytes: BoundedIoBytes(),
            publication: .immediate,
            machine: IoPublicationStateMachine(),
            inFlight: false
        )
    }
}

struct StaticIoActorSlot {
    var present: Bool
    var entry: StaticIoHandlerEntry?
    var context: UInt32

    static var empty: Self {
        Self(present: false, entry: nil, context: 0)
    }
}

struct StaticIoPendingSlot {
    var present: Bool
    var bytes: BoundedIoBytes<512>

    static var empty: Self {
        Self(present: false, bytes: BoundedIoBytes())
    }
}

struct StaticIoEndpointRegistry<let capacity: Int>: ~Copyable {
    private var endpoints: InlineArray<capacity, StaticIoEndpointRecord>
    private var actorSlots: InlineArray<capacity, StaticIoActorSlot>
    private var pendingSlots: InlineArray<capacity, StaticIoPendingSlot>

    init() {
        endpoints = InlineArray(repeating: .empty)
        actorSlots = InlineArray(repeating: .empty)
        pendingSlots = InlineArray(repeating: .empty)
    }

    borrowing func firstFreeSlot() -> Int? {
        for index in 0..<capacity where !endpoints[index].active {
            return index
        }
        return nil
    }

    borrowing func contains(id: ObjectID) -> Bool {
        for index in 0..<capacity where endpoints[index].active && endpoints[index].id == id {
            return true
        }
        return false
    }

    borrowing func sourceSlot(forID id: ObjectID) -> Int? {
        for index in 0..<capacity {
            guard endpoints[index].active,
                  endpoints[index].role == .source,
                  endpoints[index].id == id else { continue }
            return index
        }
        return nil
    }

    borrowing func actorSlot(forID id: ObjectID) -> Int? {
        for index in 0..<capacity {
            guard endpoints[index].active,
                  endpoints[index].role == .actor,
                  endpoints[index].id == id,
                  actorSlots[index].present else { continue }
            return index
        }
        return nil
    }

    borrowing func generation(at slot: Int) -> UInt32? {
        guard slot >= 0, slot < capacity, !endpoints[slot].active else { return nil }
        return endpoints[slot].generation
    }

    borrowing func sourceSlot<Value: IoEndpointValue>(
        for handle: borrowing IoSource<Value>,
        registryID: ObjectID
    ) -> Int? {
        let slot = Int(handle.runtimeSlot)
        guard slot >= 0, slot < capacity else { return nil }
        let record = endpoints[slot]
        guard record.active, record.role == .source,
              handle.matches(
                  registryID: registryID,
                  slot: handle.runtimeSlot,
                  generation: record.generation,
                  id: record.id,
                  representation: record.representation
              ) else { return nil }
        return slot
    }

    borrowing func actorSlot<Value: IoEndpointValue>(
        for handle: borrowing IoActor<Value>,
        registryID: ObjectID
    ) -> Int? {
        let slot = Int(handle.runtimeSlot)
        guard slot >= 0, slot < capacity else { return nil }
        let record = endpoints[slot]
        guard record.active, record.role == .actor,
              actorSlots[slot].present,
              handle.matches(
                  registryID: registryID,
                  slot: handle.runtimeSlot,
                  generation: record.generation,
                  id: record.id,
                  representation: record.representation
              ) else { return nil }
        return slot
    }

    borrowing func endpoint(at slot: Int) -> StaticIoEndpointRecord? {
        guard slot >= 0, slot < capacity, endpoints[slot].active else { return nil }
        return endpoints[slot]
    }

    borrowing func pending(at slot: Int) -> BoundedIoBytes<512>? {
        guard slot >= 0, slot < capacity, pendingSlots[slot].present else { return nil }
        return pendingSlots[slot].bytes
    }

    borrowing func actor(at slot: Int) -> StaticIoActorSlot? {
        guard slot >= 0, slot < capacity, actorSlots[slot].present else { return nil }
        return actorSlots[slot]
    }

    mutating func commitSource(
        at slot: Int,
        id: ObjectID,
        generation: UInt32,
        representation: IoValueRepresentation,
        objectBytes: BoundedIoBytes<512>,
        publication: IoPublicationPolicy
    ) {
        endpoints[slot] = StaticIoEndpointRecord(
            active: true,
            id: id,
            generation: generation,
            role: .source,
            representation: representation,
            objectBytes: objectBytes,
            publication: publication,
            machine: IoPublicationStateMachine(),
            inFlight: false
        )
        actorSlots[slot] = .empty
        pendingSlots[slot] = .empty
    }

    mutating func commitActor(
        at slot: Int,
        id: ObjectID,
        generation: UInt32,
        representation: IoValueRepresentation,
        objectBytes: BoundedIoBytes<512>,
        entry: StaticIoHandlerEntry,
        context: UInt32
    ) {
        endpoints[slot] = StaticIoEndpointRecord(
            active: true,
            id: id,
            generation: generation,
            role: .actor,
            representation: representation,
            objectBytes: objectBytes,
            publication: .immediate,
            machine: IoPublicationStateMachine(),
            inFlight: false
        )
        actorSlots[slot] = StaticIoActorSlot(present: true, entry: entry, context: context)
        pendingSlots[slot] = .empty
    }

    mutating func replacePending(at slot: Int, with bytes: BoundedIoBytes<512>) {
        pendingSlots[slot] = StaticIoPendingSlot(present: true, bytes: bytes)
    }

    mutating func clearPending(at slot: Int) {
        pendingSlots[slot] = .empty
    }

    mutating func commitEmission(at slot: Int, nowMS: UInt32) {
        endpoints[slot].machine.commitEmission(at: nowMS)
        endpoints[slot].inFlight = true
        pendingSlots[slot] = .empty
    }

    mutating func clearSourceTransportState(at slot: Int) {
        endpoints[slot].machine.clear()
        endpoints[slot].inFlight = false
        pendingSlots[slot] = .empty
    }

    mutating func clearAllTransportState() {
        for index in 0..<capacity where endpoints[index].active {
            endpoints[index].machine.clear()
            endpoints[index].inFlight = false
            pendingSlots[index] = .empty
        }
    }

    mutating func clearInFlight() {
        for index in 0..<capacity where endpoints[index].active {
            endpoints[index].inFlight = false
        }
    }
}
