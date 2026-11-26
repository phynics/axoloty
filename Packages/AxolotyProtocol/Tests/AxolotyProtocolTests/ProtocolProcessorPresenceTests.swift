// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Testing
import AxolotyProtocol
import AxolotyWire

/// Soft-state presence is an `axoloty/1` processor policy. These tests pin the
/// opt-in boundary, renew/re-announce, expiry, and suspend/resume behavior.
extension ProtocolProcessorTests {
    private static let peer = "00000000-0000-4000-8000-000000000201"
    private static let actor = "00000000-0000-4000-8000-000000000202"
    private static let other = "00000000-0000-4000-8000-000000000203"

    private static func makePresenceProcessor() throws -> ProtocolProcessor<4> {
        try ProtocolProcessor<4>(
            wireCodec: WireCodec(profile: .axoloty1CBOR),
            presencePolicy: .enabled
        )
    }

    private static func encodeCBOR(
        _ body: (inout WireWriter) throws -> Void
    ) throws -> [UInt8] {
        var output = [UInt8](repeating: 0, count: 1_024)
        let length = try output.withUnsafeMutableBufferPointer { buffer throws -> Int in
            var writer = WireCodec(profile: .axoloty1CBOR).writer(
                buffer: buffer.baseAddress!,
                capacity: buffer.count
            )
            try body(&writer)
            return writer.position
        }
        output.removeSubrange(length..<output.count)
        return output
    }

    private static func writeText(
        _ writer: inout WireWriter,
        _ key: StaticString,
        _ value: String
    ) throws {
        let bytes = Array(value.utf8)
        try bytes.withUnsafeBufferPointer { buffer throws in
            try writer.writeStringField(key, ByteSlice(bytes: buffer.baseAddress!, length: buffer.count))
        }
    }

    private static func objectPayload(
        objectID: String,
        coreType: String = "IoSource"
    ) throws -> [UInt8] {
        try encodeCBOR { writer in
            try writer.beginObject()
            try writer.writeUUIDField("objectId", UUID16(parsing: objectID)!)
            try writer.writeComma()
            try writeText(&writer, "coreType", coreType)
            try writer.writeComma()
            try writeText(&writer, "objectType", "coaty.\(coreType)")
            try writer.writeComma()
            try writeText(&writer, "name", "presence-object")
            try writer.endObject()
        }
    }

    private static func advertisePayload(
        objectID: String,
        leaseMS: Int?,
        ownerEpoch: Int?,
        coreType: String = "IoSource"
    ) throws -> [UInt8] {
        let object = try objectPayload(objectID: objectID, coreType: coreType)
        return try encodeCBOR { writer in
            try writer.beginObject()
            try object.withUnsafeBufferPointer { buffer throws in
                try writer.writeRawField("object", ByteSlice(bytes: buffer.baseAddress!, length: buffer.count))
            }
            if let leaseMS {
                try writer.writeComma()
                try writer.writeIntField("leaseMs", leaseMS)
            }
            if let ownerEpoch {
                try writer.writeComma()
                try writer.writeIntField("ownerEpoch", ownerEpoch)
            }
            try writer.endObject()
        }
    }

    private static func associatePayload(sourceID: String, actorID: String) throws -> [UInt8] {
        try encodeCBOR { writer in
            try writer.beginObject()
            try writer.writeUUIDField("ioActorId", UUID16(parsing: actorID)!)
            try writer.writeComma()
            try writer.writeUUIDField("ioSourceId", UUID16(parsing: sourceID)!)
            try writer.writeComma()
            try writeText(&writer, "associatingRoute", "coaty/io/presence")
            try writer.endObject()
        }
    }

    private static func withCBORFrame<R>(
        topic: String,
        payload: [UInt8],
        _ body: (BorrowedProtocolFrame) throws -> R
    ) throws -> R {
        let topicBytes = Array(topic.utf8)
        return try topicBytes.withUnsafeBufferPointer { topicBuffer in
            try payload.withUnsafeBufferPointer { payloadBuffer in
                let view = TopicView(topicBytes: topicBuffer.baseAddress!, length: topicBuffer.count)
                let bytes = ByteSlice(bytes: payloadBuffer.baseAddress!, length: payloadBuffer.count)
                return try body(try BorrowedProtocolFrame(topic: view, payload: bytes))
            }
        }
    }

    private static func advertise(
        _ payload: [UInt8],
        from source: String,
        into processor: inout ProtocolProcessor<4>,
        nowMS: UInt32
    ) throws -> (ProtocolProcessOutcome, Int) {
        try withCBORFrame(topic: "axoloty/1/presence/ADV/\(source)", payload: payload) { frame in
            var sink = InlineProtocolActionSink<8>()
            let outcome = processor.processInbound(.profile(frame), nowMS: nowMS, sink: &sink)
            return (outcome, sink.count)
        }
    }

    private static func associate(
        _ payload: [UInt8],
        from source: String,
        into processor: inout ProtocolProcessor<4>,
        nowMS: UInt32
    ) throws -> ProtocolProcessOutcome {
        try withCBORFrame(topic: "axoloty/1/presence/ASC/\(source)", payload: payload) { frame in
            var sink = InlineProtocolActionSink<8>()
            return processor.processInbound(.profile(frame), nowMS: nowMS, sink: &sink)
        }
    }

    @Test("presence requires an axoloty/1 codec")
    func presenceRejectsCoatyCodec() {
        #expect(throws: ProtocolPresenceConfigurationError.unsupportedWireProfile) {
            _ = try ProtocolProcessor<4>(
                wireCodec: WireCodec(profile: .coaty3JSON),
                presencePolicy: .enabled
            )
        }
    }

    @Test("presence validates the pair and bounds before mutation")
    func presenceValidatesPairAndBounds() throws {
        var processor = try Self.makePresenceProcessor()
        let partial = try Self.advertisePayload(objectID: Self.peer, leaseMS: 10_000, ownerEpoch: nil)
        #expect(try Self.advertise(partial, from: Self.peer, into: &processor, nowMS: 1).0
            == .rejected(.malformedPayload))
        let zeroLease = try Self.advertisePayload(objectID: Self.peer, leaseMS: 0, ownerEpoch: 1)
        #expect(try Self.advertise(zeroLease, from: Self.peer, into: &processor, nowMS: 1).0
            == .rejected(.malformedPayload))
        let largeLease = try Self.advertisePayload(objectID: Self.peer, leaseMS: 3_600_001, ownerEpoch: 1)
        #expect(try Self.advertise(largeLease, from: Self.peer, into: &processor, nowMS: 1).0
            == .rejected(.malformedPayload))
        #expect(processor.state.activeObjects == 0)
    }

    @Test("a same-epoch refresh renews without an action or generation change")
    func presenceRenewKeepsStateAndRows() throws {
        var processor = try Self.makePresenceProcessor()
        let announce = try Self.advertisePayload(objectID: Self.peer, leaseMS: 10_000, ownerEpoch: 7)
        let first = try Self.advertise(announce, from: Self.peer, into: &processor, nowMS: 100)
        #expect(first.0 == .accepted && first.1 == 1)
        let association = try Self.associatePayload(sourceID: Self.peer, actorID: Self.actor)
        #expect(try Self.associate(association, from: Self.peer, into: &processor, nowMS: 101) == .accepted)
        let generation = processor.state.generation

        let renew = try Self.advertise(announce, from: Self.peer, into: &processor, nowMS: 5_000)
        #expect(renew.0 == .accepted && renew.1 == 0)
        #expect(processor.state.generation == generation)
        #expect(processor.state.activeAssociations == 1)
    }

    @Test("a changed epoch re-announces, delivers, and releases rows")
    func presenceReannounceReleasesRows() throws {
        var processor = try Self.makePresenceProcessor()
        let first = try Self.advertisePayload(objectID: Self.peer, leaseMS: 10_000, ownerEpoch: 1)
        #expect(try Self.advertise(first, from: Self.peer, into: &processor, nowMS: 100).0 == .accepted)
        let association = try Self.associatePayload(sourceID: Self.peer, actorID: Self.actor)
        #expect(try Self.associate(association, from: Self.peer, into: &processor, nowMS: 101) == .accepted)

        let second = try Self.advertisePayload(objectID: Self.peer, leaseMS: 10_000, ownerEpoch: 2)
        let reannounce = try Self.advertise(second, from: Self.peer, into: &processor, nowMS: 200)
        #expect(reannounce.0 == .accepted)
        #expect(reannounce.1 == 2)
        #expect(processor.state.activeAssociations == 0)
        #expect(processor.state.activeObjects == 1)
    }

    @Test("a short sink rejects a re-announce without mutation")
    func presenceReannounceRejectsWithShortSink() throws {
        var processor = try Self.makePresenceProcessor()
        let first = try Self.advertisePayload(objectID: Self.peer, leaseMS: 10_000, ownerEpoch: 1)
        #expect(try Self.advertise(first, from: Self.peer, into: &processor, nowMS: 100).0 == .accepted)
        let association = try Self.associatePayload(sourceID: Self.peer, actorID: Self.actor)
        #expect(try Self.associate(association, from: Self.peer, into: &processor, nowMS: 101) == .accepted)
        let generation = processor.state.generation

        let second = try Self.advertisePayload(objectID: Self.peer, leaseMS: 10_000, ownerEpoch: 2)
        try Self.withCBORFrame(topic: "axoloty/1/presence/ADV/\(Self.peer)", payload: second) { frame in
            var sink = InlineProtocolActionSink<1>()
            let outcome = processor.processInbound(.profile(frame), nowMS: 200, sink: &sink)
            #expect(outcome == .rejected(.capacityExceeded))
            #expect(sink.count == 0)
        }
        #expect(processor.state.activeAssociations == 1)
        #expect(processor.state.generation == generation)
    }

    @Test("expiry removes one peer object and leaves rows")
    func presenceExpiryRemovesOneObject() throws {
        var processor = try Self.makePresenceProcessor()
        let announce = try Self.advertisePayload(objectID: Self.peer, leaseMS: 1_000, ownerEpoch: 1)
        #expect(try Self.advertise(announce, from: Self.peer, into: &processor, nowMS: 100).0 == .accepted)
        let association = try Self.associatePayload(sourceID: Self.peer, actorID: Self.actor)
        #expect(try Self.associate(association, from: Self.peer, into: &processor, nowMS: 101) == .accepted)

        #expect(processor.expirePresence(nowMS: 1_099) == nil)
        let expiredValue = processor.expirePresence(nowMS: 1_100)
        let expired = try #require(expiredValue)
        #expect(expired.sourceID == UUID16(parsing: Self.peer))
        #expect(expired.objectID == UUID16(parsing: Self.peer))
        #expect(processor.state.activeObjects == 0)
        #expect(processor.state.activeAssociations == 1)
        #expect(processor.expirePresence(nowMS: 1_100) == nil)
    }

    @Test("suspend keeps leased peers, drops unleased peers, and resume re-bases")
    func presenceSuspendAndResume() throws {
        var processor = try Self.makePresenceProcessor()
        let leased = try Self.advertisePayload(objectID: Self.peer, leaseMS: 1_000, ownerEpoch: 1)
        let unleased = try Self.advertisePayload(objectID: Self.other, leaseMS: nil, ownerEpoch: nil)
        #expect(try Self.advertise(leased, from: Self.peer, into: &processor, nowMS: 100).0 == .accepted)
        #expect(try Self.advertise(unleased, from: Self.other, into: &processor, nowMS: 101).0 == .accepted)

        processor.suspendPresence()
        #expect(processor.state.activeObjects == 1)
        #expect(processor.expirePresence(nowMS: 100_000) == nil)

        processor.resumePresence(nowMS: 100_000)
        #expect(processor.expirePresence(nowMS: 100_999) == nil)
        #expect(processor.expirePresence(nowMS: 101_000) != nil)
        #expect(processor.state.activeObjects == 0)
        processor.suspendPresence()
        #expect(processor.state.activeObjects == 0)
        processor.resumePresence(nowMS: 200_000)
        processor.resumePresence(nowMS: 200_001)
    }

    @Test("presence off keeps repeated Advertise duplicates and never expires")
    func presenceOffKeepsLegacyBehavior() throws {
        var processor = ProtocolProcessor<4>(wireCodec: WireCodec(profile: .axoloty1CBOR))
        let announce = try Self.advertisePayload(objectID: Self.peer, leaseMS: 1_000, ownerEpoch: 1)
        #expect(try Self.advertise(announce, from: Self.peer, into: &processor, nowMS: 100).0 == .accepted)
        #expect(try Self.advertise(announce, from: Self.peer, into: &processor, nowMS: 200).0
            == .rejected(.duplicate))
        #expect(processor.expirePresence(nowMS: 1_000_000) == nil)
        #expect(processor.state.activeObjects == 1)
    }

    private static func sendAdvertise(
        _ payload: [UInt8],
        from source: String,
        into processor: inout ProtocolProcessor<4>,
        nowMS: UInt32
    ) -> (ProtocolProcessOutcome, Int) {
        payload.withUnsafeBufferPointer { buffer in
            var sink = InlineProtocolActionSink<8>()
            let operation = ProtocolLocalOperation.advertise(
                sourceID: UUID16(parsing: source)!,
                payload: ByteSlice(bytes: buffer.baseAddress!, length: buffer.count)
            )
            let outcome = processor.processOutbound(operation, nowMS: nowMS, sink: &sink)
            return (outcome, sink.count)
        }
    }

    @Test("a local leased Advertise stores presence and refreshes")
    func presenceLocalRefresh() throws {
        var processor = try Self.makePresenceProcessor()
        let payload = try Self.advertisePayload(objectID: Self.peer, leaseMS: 1_000, ownerEpoch: 1)
        #expect(Self.sendAdvertise(payload, from: Self.peer, into: &processor, nowMS: 100).0 == .accepted)
        #expect(processor.state.activeObjects == 1)
        let generation = processor.state.generation
        #expect(processor.expirePresence(nowMS: 1_000_000) == nil)

        #expect(Self.sendAdvertise(payload, from: Self.peer, into: &processor, nowMS: 500).0 == .accepted)
        #expect(processor.state.generation == generation)

        let reannounce = try Self.advertisePayload(objectID: Self.peer, leaseMS: 1_000, ownerEpoch: 2)
        #expect(Self.sendAdvertise(reannounce, from: Self.peer, into: &processor, nowMS: 600).0 == .accepted)
        #expect(processor.state.generation > generation)
    }

    @Test("a suspended full table evicts the oldest leased peer for a local advertise")
    func presenceSuspendedEviction() throws {
        var processor = try Self.makePresenceProcessor()
        let peer = try Self.advertisePayload(objectID: Self.other, leaseMS: 1_000, ownerEpoch: 1)
        #expect(try Self.advertise(peer, from: Self.other, into: &processor, nowMS: 100).0 == .accepted)
        processor.suspendPresence()
        #expect(processor.state.activeObjects == 1)

        for index in 0..<4 {
            let object = "00000000-0000-4000-8000-00000000021\(index)"
            let payload = try Self.advertisePayload(objectID: object, leaseMS: 1_000, ownerEpoch: 1)
            let result = Self.sendAdvertise(payload, from: object, into: &processor, nowMS: 200 + UInt32(index))
            #expect(result.0 == .accepted)
        }
        #expect(processor.state.activeObjects == 4)
    }
}
