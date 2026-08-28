// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

// Link probe for Embedded Swift compatibility (issues #321, #322).
//
// This file imports AxolotyWire as a separate module and exercises every
// runtime-relevant public API. It is compiled with `swiftc -c` and linked
// against the AxolotyWire module object by check-embedded-swift.sh.
//
// A compile-only check cannot catch missing runtime symbols (e.g. Unicode
// normalization tables), ABI mismatches, or relocation errors. This probe
// catches them by linking.
//
// Uses `StaticString` for all string literals to avoid pulling in Swift's
// Unicode normalization runtime — the same constraint the on-device
// `Main.swift` respects.

import AxolotyWire

// Exercise every WireEventType case.
@inline(__always)
func exerciseEventType(_ type: WireEventType) -> UInt8 {
    switch type {
    case .advertise: return 1
    case .deadvertise: return 2
    case .channel: return 3
    case .associate: return 4
    case .ioValue: return 5
    case .discover: return 6
    case .resolve: return 7
    case .query: return 8
    case .retrieve: return 9
    case .update: return 10
    case .complete: return 11
    case .call: return 12
    case .returnEvent: return 13
    }
}

@inline(__always)
func exerciseWireCode() -> Bool {
    let adv = WireEventType.advertise.wireCode
    return adv.utf8CodeUnitCount == 3
}

@inline(__always)
func exerciseWireCodeInit() -> WireEventType? {
    let code: StaticString = "ADV"
    let slice = ByteSlice(bytes: code.utf8Start, length: 3)
    return WireEventType(wireCode: slice)
}

@inline(__always)
func exerciseIsOneWay() -> Bool {
    return WireEventType.advertise.isOneWay && !WireEventType.discover.isOneWay
}

@inline(__always)
func exerciseTopicView() -> WireEventType? {
    let topic: StaticString = "coaty/3/ns/ADV:filter/source-id/corr"
    let tv = TopicView(topicBytes: topic.utf8Start, length: topic.utf8CodeUnitCount)
    _ = tv.eventTypeFilter
    _ = tv.sourceIdLevel
    _ = tv.correlationIdLevel
    _ = tv.isRawTopic
    return tv.eventType
}

@inline(__always)
func exerciseTopicBuilder() -> Bool {
    let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 128)
    defer { buf.deallocate() }
    var builder = TopicBuilder(buffer: buf, capacity: 128)
    var ok = false
    do throws(WireEncodeError) {
        try builder.writePrefix()
        try builder.writeNamespace("ns")
        try builder.writeEventType(.advertise, filter: nil)
        try builder.writeSourceId(UUID16.zero)
        ok = builder.build().length > 0
    } catch {
        ok = false
    }
    return ok
}

@inline(__always)
func exerciseUUID16() -> UUID16? {
    let str: StaticString = "33333333-3333-4333-8333-333333333333"
    let slice = ByteSlice(bytes: str.utf8Start, length: 36)
    return UUID16(parsing: slice)
}

@inline(__always)
func exerciseWireReader() -> Bool {
    let payload: StaticString = #"{"objectId":"33333333-3333-4333-8333-333333333333","name":"test","updateRate":100,"hasAssociations":true}"#
    let reader = WireReader(bytes: payload.utf8Start, length: payload.utf8CodeUnitCount)
    let uuid = reader.readUUID("objectId")
    let name = reader.readString("name")
    let rate = reader.readInt("updateRate")
    let assoc = reader.readBool("hasAssociations")
    return uuid != nil && name != nil && rate == 100 && assoc == true
}

@inline(__always)
func exerciseWireWriter() -> Bool {
    let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 256)
    defer { buf.deallocate() }
    var writer = WireWriter(buffer: buf, capacity: 256)
    var ok = false
    do throws(WireEncodeError) {
        try writer.beginObject()
        let nameVal: StaticString = "test"
        try writer.writeStringField("name", ByteSlice(bytes: nameVal.utf8Start, length: 4))
        try writer.writeIntField("updateRate", 100)
        try writer.writeBoolField("hasAssociations", true)
        try writer.writeUUIDField("objectId", UUID16.zero)
        try writer.writeNullField("deletedAt")
        try writer.writeInt(0)
        try writer.writeInt(1)
        try writer.writeInt(-1)
        try writer.writeInt(Int.max)
        try writer.writeInt(Int.min)
        try writer.endObject()
        ok = writer.position > 0
    } catch {
        ok = false
    }
    return ok
}

@inline(__always)
func exerciseConfig() -> Bool {
    return WireBufferConfig.maxPayloadSize == 2_048
        && WireBufferConfig.maxTopicLength == 128
}

@inline(__always)
func exerciseByteSlice() -> Bool {
    let str: StaticString = "hello"
    let slice = ByteSlice(bytes: str.utf8Start, length: 5)
    return slice.equals("hello") && slice.byte(at: 0) == 0x68
}

@inline(__always)
func exerciseBorrowedMessage() -> Bool {
    let topic: StaticString = "coaty/3/ns/ADV/source-id"
    let payload: StaticString = #"{"objectId":"33333333-3333-4333-8333-333333333333"}"#
    let msg = BorrowedMessage(
        topicBytes: topic.utf8Start,
        topicLength: topic.utf8CodeUnitCount,
        payloadBytes: payload.utf8Start,
        payloadLength: payload.utf8CodeUnitCount
    )
    let reader = msg.reader()
    return msg.eventType == .advertise && reader.readUUID("objectId") != nil
}

@inline(__always)
func exerciseTypedWireEvent() -> Bool {
    let payload: StaticString = #"{"payload":1}"#
    let reader = WireReader(bytes: payload.utf8Start, length: payload.utf8CodeUnitCount)
    guard let value = try? BorrowedWireEvent(eventType: .ioValue, from: reader) else { return false }
    if case .ioValue = value { return true }
    return false
}

// Main entry — call all exercise functions to ensure they are linked.
@inline(__always)
func runAllExercises() -> UInt8 {
    var result: UInt8 = 0
    result &+= exerciseEventType(.advertise)
    result &+= exerciseEventType(.deadvertise)
    result &+= exerciseEventType(.channel)
    result &+= exerciseEventType(.associate)
    result &+= exerciseEventType(.ioValue)
    result &+= exerciseEventType(.discover)
    result &+= exerciseEventType(.resolve)
    result &+= exerciseEventType(.query)
    result &+= exerciseEventType(.retrieve)
    result &+= exerciseEventType(.update)
    result &+= exerciseEventType(.complete)
    result &+= exerciseEventType(.call)
    result &+= exerciseEventType(.returnEvent)
    result &+= exerciseWireCode() ? 1 : 0
    result &+= exerciseWireCodeInit() != nil ? 1 : 0
    result &+= exerciseIsOneWay() ? 1 : 0
    result &+= exerciseTopicView() != nil ? 1 : 0
    result &+= exerciseTopicBuilder() ? 1 : 0
    result &+= exerciseUUID16() != nil ? 1 : 0
    result &+= exerciseWireReader() ? 1 : 0
    result &+= exerciseWireWriter() ? 1 : 0
    result &+= exerciseConfig() ? 1 : 0
    result &+= exerciseByteSlice() ? 1 : 0
    result &+= exerciseBorrowedMessage() ? 1 : 0
    result &+= exerciseTypedWireEvent() ? 1 : 0
    return result
}

// Keep the reference alive so the linker doesn't dead-strip.
@_cdecl("link_probe_main")
func link_probe_main() -> Int32 {
    _ = runAllExercises()
    return 0
}
