// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Testing
import AxolotyProtocol
import AxolotyWire

/// Pins the field-kind boundary at the processor: a present wrong-kind field is
/// a malformed payload with unchanged state, and it never reaches the
/// "absent means disassociate" or "absent objectId means the source ID" paths.
extension ProtocolProcessorTests {
    private static let kindSource = "00000000-0000-4000-8000-000000000301"
    private static let kindActor = "00000000-0000-4000-8000-000000000302"
    private static let kindObject = "00000000-0000-4000-8000-000000000303"

    @Test("a wrong-kind Associate field rejects without removing the live row")
    func wrongKindAssociatePreservesRow() throws {
        let source = Self.kindSource
        let actor = Self.kindActor
        var processor = ProtocolProcessor<2>()

        let established = try Self.receiveJSON(
            "coaty/3/test/ASC/\(source)",
            #"{"ioSourceId":"\#(source)","ioActorId":"\#(actor)","associatingRoute":"coaty/3/IOV/\#(source)"}"#,
            into: &processor,
            nowMS: 1
        )
        #expect(established.outcome == .accepted)
        #expect(processor.state.activeAssociations == 1)

        let malformed = [
            #"{"ioSourceId":"\#(source)","ioActorId":"\#(actor)","associatingRoute":42}"#,
            #"{"ioSourceId":"\#(source)","ioActorId":"\#(actor)","associatingRoute":null}"#,
            #"{"ioSourceId":"\#(source)","ioActorId":"\#(actor)","isExternalRoute":"yes"}"#,
            #"{"ioSourceId":"\#(source)","ioActorId":"\#(actor)","updateRate":"fast"}"#,
        ]
        for payload in malformed {
            let result = try Self.receiveJSON("coaty/3/test/ASC/\(source)", payload, into: &processor, nowMS: 2)
            #expect(result.outcome == .rejected(.malformedPayload), "payload: \(payload)")
            #expect(result.actions == 0, "payload: \(payload)")
            #expect(processor.state.activeAssociations == 1, "payload: \(payload)")
        }

        // Omitting the route still means "disassociate".
        let omitted = try Self.receiveJSON(
            "coaty/3/test/ASC/\(source)",
            #"{"ioSourceId":"\#(source)","ioActorId":"\#(actor)"}"#,
            into: &processor,
            nowMS: 3
        )
        #expect(omitted.outcome == .accepted)
        #expect(processor.state.activeAssociations == 0)
    }

    @Test("an empty Associate route is a malformed payload, not a capacity failure")
    func emptyAssociateRouteIsMalformed() throws {
        let source = Self.kindSource
        let actor = Self.kindActor
        var processor = ProtocolProcessor<2>()

        _ = try Self.receiveJSON(
            "coaty/3/test/ASC/\(source)",
            #"{"ioSourceId":"\#(source)","ioActorId":"\#(actor)","associatingRoute":"coaty/3/IOV/\#(source)"}"#,
            into: &processor,
            nowMS: 1
        )
        let result = try Self.receiveJSON(
            "coaty/3/test/ASC/\(source)",
            #"{"ioSourceId":"\#(source)","ioActorId":"\#(actor)","associatingRoute":""}"#,
            into: &processor,
            nowMS: 2
        )
        #expect(result.outcome == .rejected(.malformedPayload))
        #expect(result.actions == 0)
        #expect(processor.state.activeAssociations == 1)
    }

    @Test("an Advertise without a usable objectId is malformed and does not block the next valid one")
    func advertiseObjectIdentityIsRequired() throws {
        let source = Self.kindSource
        var processor = ProtocolProcessor<2>()

        let malformed = [
            #"{"object":7}"#,
            #"{"object":{"coreType":"IoSource"}}"#,
            #"{"object":{"objectId":7,"coreType":"IoSource"}}"#,
            #"{"object":{"objectId":"not-a-uuid","coreType":"IoSource"}}"#,
        ]
        for payload in malformed {
            let result = try Self.receiveJSON("coaty/3/test/ADV/\(source)", payload, into: &processor, nowMS: 1)
            #expect(result.outcome == .rejected(.malformedPayload), "payload: \(payload)")
            #expect(processor.state.activeObjects == 0, "payload: \(payload)")
        }

        let valid = try Self.receiveJSON(
            "coaty/3/test/ADV/\(source)",
            #"{"object":{"objectId":"\#(source)","coreType":"IoSource"}}"#,
            into: &processor,
            nowMS: 2
        )
        #expect(valid.outcome == .accepted)
        #expect(processor.state.activeObjects == 1)
    }

    @Test("the axoloty/1 presence path applies the same Advertise object identity rule")
    func presenceAdvertiseObjectIdentityIsRequired() throws {
        let source = Self.kindSource
        var processor = try ProtocolProcessor<2>(
            wireCodec: WireCodec(profile: .axoloty1CBOR),
            presencePolicy: .enabled
        )

        let malformedObjects: [[UInt8]] = [
            try Self.encodeCBOR { writer in try writer.writeInt(7) },
            try Self.encodeCBOR { writer in
                try writer.beginObject()
                try Self.writeText(&writer, "coreType", "IoSource")
                try writer.endObject()
            },
            try Self.encodeCBOR { writer in
                try writer.beginObject()
                try writer.writeIntField("objectId", 7)
                try writer.writeComma()
                try Self.writeText(&writer, "coreType", "IoSource")
                try writer.endObject()
            },
            try Self.encodeCBOR { writer in
                try writer.beginObject()
                try Self.writeText(&writer, "objectId", "not-a-uuid")
                try writer.writeComma()
                try Self.writeText(&writer, "coreType", "IoSource")
                try writer.endObject()
            },
        ]

        for object in malformedObjects {
            let payload = try Self.advertiseCBOR(object: object)
            let result = try Self.receiveCBOR(
                "axoloty/1/presence/ADV/\(source)",
                payload,
                into: &processor,
                nowMS: 1
            )
            #expect(result == .rejected(.malformedPayload))
            #expect(processor.state.activeObjects == 0)
        }

        let validObject = try Self.encodeCBOR { writer in
            try writer.beginObject()
            try writer.writeUUIDField("objectId", UUID16(parsing: source)!)
            try writer.writeComma()
            try Self.writeText(&writer, "coreType", "IoSource")
            try writer.endObject()
        }
        let valid = try Self.receiveCBOR(
            "axoloty/1/presence/ADV/\(source)",
            Self.advertiseCBOR(object: validObject),
            into: &processor,
            nowMS: 2
        )
        #expect(valid == .accepted)
        #expect(processor.state.activeObjects == 1)
    }

    // MARK: - Helpers

    private static func receiveJSON(
        _ topic: String,
        _ payload: String,
        into processor: inout ProtocolProcessor<2>,
        nowMS: UInt32
    ) throws -> (outcome: ProtocolProcessOutcome, actions: Int) {
        try withBorrowedFrame(topic: topic, payload: payload) { frame in
            var sink = InlineProtocolActionSink<2>()
            let outcome = processor.processInbound(.profile(frame), nowMS: nowMS, sink: &sink)
            return (outcome, sink.count)
        }
    }

    private static func receiveCBOR(
        _ topic: String,
        _ payload: [UInt8],
        into processor: inout ProtocolProcessor<2>,
        nowMS: UInt32
    ) throws -> ProtocolProcessOutcome {
        let topicBytes = Array(topic.utf8)
        return try topicBytes.withUnsafeBufferPointer { topicBuffer in
            try payload.withUnsafeBufferPointer { payloadBuffer in
                let view = TopicView(topicBytes: topicBuffer.baseAddress!, length: topicBuffer.count)
                let bytes = ByteSlice(bytes: payloadBuffer.baseAddress!, length: payloadBuffer.count)
                var sink = InlineProtocolActionSink<2>()
                return processor.processInbound(
                    .profile(try BorrowedProtocolFrame(topic: view, payload: bytes)),
                    nowMS: nowMS,
                    sink: &sink
                )
            }
        }
    }

    private static func encodeCBOR(_ body: (inout WireWriter) throws -> Void) throws -> [UInt8] {
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

    private static func advertiseCBOR(object: [UInt8]) throws -> [UInt8] {
        try encodeCBOR { writer in
            try writer.beginObject()
            try object.withUnsafeBufferPointer { buffer throws in
                try writer.writeRawField("object", ByteSlice(bytes: buffer.baseAddress!, length: buffer.count))
            }
            try writer.writeComma()
            try writer.writeIntField("leaseMs", 1_000)
            try writer.writeComma()
            try writer.writeIntField("ownerEpoch", 1)
            try writer.endObject()
        }
    }
}
