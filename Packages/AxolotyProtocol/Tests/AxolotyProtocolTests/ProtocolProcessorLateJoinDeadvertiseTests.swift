// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Testing
import AxolotyProtocol
import AxolotyWire

/// A consumer that connects after a peer advertised holds no table entry for
/// that peer, yet it must still learn the peer is gone, for example from the
/// broker last will. These tests pin the inbound identity rule on both wire
/// profiles through the one shared processor.
fileprivate enum LateJoinProfile: CaseIterable, CustomTestStringConvertible {
    case coaty3
    case axoloty1

    var testDescription: String { self == .coaty3 ? "coaty/3 JSON" : "axoloty/1 CBOR" }
    var wireProfile: WireProfile { self == .coaty3 ? .coaty3JSON : .axoloty1CBOR }
    func makeProcessor() -> ProtocolProcessor<4> {
        ProtocolProcessor<4>(wireCodec: WireCodec(profile: wireProfile))
    }

    /// Encodes `{"objectIds":[...]}` with the profile's production writer.
    func deadvertisePayload(_ ids: [UUID16]) throws -> [UInt8] {
        let outer = UnsafeMutablePointer<UInt8>.allocate(capacity: 512)
        let array = UnsafeMutablePointer<UInt8>.allocate(capacity: 256)
        defer { outer.deallocate(); array.deallocate() }
        var arrayWriter = WireCodec(profile: wireProfile).writer(buffer: array, capacity: 256)
        try arrayWriter.beginArray()
        for (index, id) in ids.enumerated() {
            if index > 0 { try arrayWriter.writeComma() }
            try arrayWriter.writeUUIDValue(id)
        }
        try arrayWriter.endArray()
        var writer = WireCodec(profile: wireProfile).writer(buffer: outer, capacity: 512)
        try writer.beginObject()
        try writer.writeRawField("objectIds", ByteSlice(bytes: array, length: arrayWriter.position))
        try writer.endObject()
        return Array(UnsafeBufferPointer(start: outer, count: writer.position))
    }

    /// Encodes `{"object":{"objectId":...}}` with the profile's production writer.
    func advertisePayload(_ id: UUID16) throws -> [UInt8] {
        let outer = UnsafeMutablePointer<UInt8>.allocate(capacity: 512)
        let inner = UnsafeMutablePointer<UInt8>.allocate(capacity: 256)
        defer { outer.deallocate(); inner.deallocate() }
        var innerWriter = WireCodec(profile: wireProfile).writer(buffer: inner, capacity: 256)
        try innerWriter.beginObject()
        try innerWriter.writeUUIDField("objectId", id)
        try innerWriter.endObject()
        var writer = WireCodec(profile: wireProfile).writer(buffer: outer, capacity: 512)
        try writer.beginObject()
        try writer.writeRawField("object", ByteSlice(bytes: inner, length: innerWriter.position))
        try writer.endObject()
        return Array(UnsafeBufferPointer(start: outer, count: writer.position))
    }

    /// Feeds one inbound frame and returns the outcome plus the delivered
    /// payload bytes, if the processor delivered the event.
    func receive(
        _ capability: ProtocolCapability,
        from source: UUID16,
        payload: [UInt8],
        into processor: inout ProtocolProcessor<4>
    ) throws -> (outcome: ProtocolProcessOutcome, delivered: [[UInt8]]) {
        let storage = UnsafeMutablePointer<UInt8>.allocate(capacity: 256)
        defer { storage.deallocate() }
        var builder = TopicBuilder(buffer: storage, capacity: 256)
        try builder.writePrefix(wireProfile)
        try builder.writeNamespace("late-join")
        try builder.writeEventType(capability.wireEventType)
        try builder.writeSourceId(source)
        let topic = builder.build()
        return try payload.withUnsafeBufferPointer { buffer in
            let topicView = topic.withBytes { pointer, length in
                TopicView(topicBytes: pointer.assumingMemoryBound(to: UInt8.self), length: length)
            }
            let frame = try BorrowedProtocolFrame(
                topic: topicView,
                payload: ByteSlice(bytes: buffer.baseAddress!, length: buffer.count)
            )
            var sink = InlineProtocolActionSink<4>()
            let outcome = processor.processInbound(.profile(frame), nowMS: 1, sink: &sink)
            var delivered: [[UInt8]] = []
            for index in 0..<sink.count {
                guard let action = sink[index], case .deliver(let delivery) = action.owned() else { continue }
                #expect(delivery.routingKey.capability == capability)
                delivered.append(delivery.payload)
            }
            return (outcome, delivered)
        }
    }

    func send(
        _ capability: ProtocolCapability,
        from source: UUID16,
        payload: [UInt8],
        into processor: inout ProtocolProcessor<4>
    ) throws -> ProtocolProcessOutcome {
        var sink = InlineProtocolActionSink<4>()
        return try payload.withUnsafeBufferPointer { buffer in
            let operation = try ProtocolLocalOperation(
                capability: capability,
                sourceID: source,
                payload: ByteSlice(bytes: buffer.baseAddress!, length: buffer.count)
            )
            return processor.processOutbound(operation, sink: &sink)
        }
    }
}

private let peerA = UUID16(bytes: (0x20, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1))
private let peerB = UUID16(bytes: (0x20, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2))
private let unknown1 = UUID16(bytes: (0x30, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1))
private let unknown2 = UUID16(bytes: (0x30, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2))
private let childA = UUID16(bytes: (0x40, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1))
private let childB = UUID16(bytes: (0x40, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2))

extension ProtocolProcessorTests {
    @Test("a late joiner receives a peer's identity deadvertisement with an empty table",
          arguments: LateJoinProfile.allCases)
    fileprivate func lateJoinDeliversOwnIdentity(profile: LateJoinProfile) throws {
        var processor = profile.makeProcessor()
        let before = processor.state
        let payload = try profile.deadvertisePayload([peerA])
        let result = try profile.receive(.deadvertise, from: peerA, payload: payload, into: &processor)
        #expect(result.outcome == .accepted)
        #expect(result.delivered == [payload])
        // Nothing was created or removed.
        #expect(processor.state.activeObjects == 0)
        #expect(processor.state.activeAssociations == 0)
        #expect(processor.state.pendingCorrelations == 0)
        #expect(before.activeObjects == 0)
    }

    @Test("a repeated identity deadvertisement is delivered again and stays stateless",
          arguments: LateJoinProfile.allCases)
    fileprivate func repeatedIdentityDeadvertiseIsDelivered(profile: LateJoinProfile) throws {
        var processor = profile.makeProcessor()
        let payload = try profile.deadvertisePayload([peerA])
        for _ in 0..<2 {
            let result = try profile.receive(.deadvertise, from: peerA, payload: payload, into: &processor)
            #expect(result.outcome == .accepted)
            #expect(result.delivered.count == 1)
        }
        #expect(processor.state.activeObjects == 0)
    }

    @Test("a local deadvertise of an object never announced stays rejected",
          arguments: LateJoinProfile.allCases)
    fileprivate func localUnannouncedDeadvertiseStaysRejected(profile: LateJoinProfile) throws {
        var processor = profile.makeProcessor()
        let identity = try profile.deadvertisePayload([peerA])
        #expect(try profile.send(.deadvertise, from: peerA, payload: identity, into: &processor)
            == .rejected(.malformedFrame))
        let other = try profile.deadvertisePayload([unknown1])
        #expect(try profile.send(.deadvertise, from: peerA, payload: other, into: &processor)
            == .rejected(.malformedFrame))
        #expect(processor.state.activeObjects == 0)
        #expect(processor.state.generation == 0)
    }

    @Test("a deadvertisement naming only other unknown identities stays rejected",
          arguments: LateJoinProfile.allCases)
    fileprivate func unmatchedForeignIdsStayRejected(profile: LateJoinProfile) throws {
        var processor = profile.makeProcessor()
        let payload = try profile.deadvertisePayload([unknown1, unknown2])
        let result = try profile.receive(.deadvertise, from: peerA, payload: payload, into: &processor)
        #expect(result.outcome == .rejected(.malformedFrame))
        #expect(result.delivered.isEmpty)
        #expect(processor.state.generation == 0)
        let empty = try profile.deadvertisePayload([])
        let none = try profile.receive(.deadvertise, from: peerA, payload: empty, into: &processor)
        #expect(none.outcome == .rejected(.malformedFrame))
    }

    @Test("a payload naming the source and other unknown ids creates and removes nothing",
          arguments: LateJoinProfile.allCases)
    fileprivate func sourceAmongUnknownIdsOwnsNothing(profile: LateJoinProfile) throws {
        var processor = profile.makeProcessor()
        let payload = try profile.deadvertisePayload([unknown1, peerA, unknown2])
        let result = try profile.receive(.deadvertise, from: peerA, payload: payload, into: &processor)
        #expect(result.outcome == .accepted)
        #expect(result.delivered == [payload])
        #expect(processor.state.activeObjects == 0)
    }

    @Test("a real table match behaves as before and removes only what the source owns",
          arguments: LateJoinProfile.allCases)
    fileprivate func matchedDeadvertiseRemovesOnlyOwnedObjects(profile: LateJoinProfile) throws {
        var processor = profile.makeProcessor()
        for (source, object) in [(peerA, childA), (peerA, peerA), (peerB, childB)] {
            let advertise = try profile.advertisePayload(object)
            let result = try profile.receive(.advertise, from: source, payload: advertise, into: &processor)
            #expect(result.outcome == .accepted)
        }
        #expect(processor.state.activeObjects == 3)

        // peer A names its identity, one of its children, a child of peer B,
        // and an unknown id. Only peer A's two entries go.
        let payload = try profile.deadvertisePayload([peerA, childA, childB, unknown1])
        let result = try profile.receive(.deadvertise, from: peerA, payload: payload, into: &processor)
        #expect(result.outcome == .accepted)
        #expect(result.delivered == [payload])
        #expect(processor.state.activeObjects == 1)

        // Peer B's surviving entry still matches, and the same identity
        // deadvertise is now an unmatched delivery for peer A.
        let again = try profile.receive(.deadvertise, from: peerA, payload: payload, into: &processor)
        #expect(again.outcome == .accepted)
        #expect(processor.state.activeObjects == 1)
        let bPayload = try profile.deadvertisePayload([childB])
        let bResult = try profile.receive(.deadvertise, from: peerB, payload: bPayload, into: &processor)
        #expect(bResult.outcome == .accepted)
        #expect(processor.state.activeObjects == 0)
    }

    @Test("a local deadvertise of an announced object still removes it",
          arguments: LateJoinProfile.allCases)
    fileprivate func localAnnouncedDeadvertiseStillWorks(profile: LateJoinProfile) throws {
        var processor = profile.makeProcessor()
        let advertise = try profile.advertisePayload(peerA)
        #expect(try profile.send(.advertise, from: peerA, payload: advertise, into: &processor) == .accepted)
        #expect(processor.state.activeObjects == 1)
        let payload = try profile.deadvertisePayload([peerA])
        #expect(try profile.send(.deadvertise, from: peerA, payload: payload, into: &processor) == .accepted)
        #expect(processor.state.activeObjects == 0)
        // Once gone, a second local deadvertise has nothing to remove.
        #expect(try profile.send(.deadvertise, from: peerA, payload: payload, into: &processor)
            == .rejected(.malformedFrame))
    }

    @Test("an identity deadvertisement with a malformed id array stays rejected",
          arguments: LateJoinProfile.allCases)
    fileprivate func malformedIdArrayStaysRejected(profile: LateJoinProfile) throws {
        var processor = profile.makeProcessor()
        // The source id is named first, then a non-UUID element follows.
        let storage = UnsafeMutablePointer<UInt8>.allocate(capacity: 256)
        let array = UnsafeMutablePointer<UInt8>.allocate(capacity: 128)
        defer { storage.deallocate(); array.deallocate() }
        var arrayWriter = WireCodec(profile: profile.wireProfile).writer(buffer: array, capacity: 128)
        try arrayWriter.beginArray()
        try arrayWriter.writeUUIDValue(peerA)
        try arrayWriter.writeComma()
        let text: StaticString = "not-a-uuid"
        try arrayWriter.writeEncodedStringValue(ByteSlice(bytes: text.utf8Start, length: text.utf8CodeUnitCount))
        try arrayWriter.endArray()
        var writer = WireCodec(profile: profile.wireProfile).writer(buffer: storage, capacity: 256)
        try writer.beginObject()
        try writer.writeRawField("objectIds", ByteSlice(bytes: array, length: arrayWriter.position))
        try writer.endObject()
        let payload = Array(UnsafeBufferPointer(start: storage, count: writer.position))
        let result = try profile.receive(.deadvertise, from: peerA, payload: payload, into: &processor)
        #expect(result.outcome != .accepted)
        #expect(result.delivered.isEmpty)
        #expect(processor.state.generation == 0)
    }
}
