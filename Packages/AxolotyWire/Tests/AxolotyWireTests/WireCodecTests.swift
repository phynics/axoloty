// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyWire
import Testing

private func decodeIoStateData(_ json: String) throws -> IoStateWireData {
    let bytes = Array(json.utf8)
    return try bytes.withUnsafeBufferPointer { buffer in
        let reader = WireReader(bytes: buffer.baseAddress!, length: buffer.count)
        return try IoStateWireData(from: reader)
    }
}

/// Encodes a wire value into a new, exactly sized byte array.
private func encodeWireValue(
    profile: WireProfile,
    _ body: (inout WireWriter) throws(WireEncodeError) -> Void
) throws(WireEncodeError) -> [UInt8] {
    var output = [UInt8](repeating: 0, count: WireBufferConfig.maxPayloadSize)
    let count = try output.withUnsafeMutableBufferPointer {
        (destination: inout UnsafeMutableBufferPointer<UInt8>) throws(WireEncodeError) -> Int in
        var writer = WireCodec(profile: profile).writer(
            buffer: destination.baseAddress!, capacity: destination.count
        )
        try body(&writer)
        return writer.position
    }
    return Array(output[0..<count])
}

/// Tests for the Foundation-free wire codec primitives.
///
/// These tests verify the zero-allocation topic parsing, UUID handling,
/// and JSON field scanning that will underpin the embedded routing path.
/// They run on the standard Swift toolchain but exercise code that is
/// written to compile without Foundation.
@Suite
struct WireCodecTests {

    // MARK: - TopicView

    @Test
    func topicViewParsesAdvertiseTopic() throws {
        let topic = "coaty/3/wire-compat-v1/ADV:sensors/33333333-3333-4333-8333-333333333333"
        let bytes = Array(topic.utf8)
        let view = bytes.withUnsafeBufferPointer { buf in
            TopicView(topicBytes: buf.baseAddress!, length: buf.count)
        }

        #expect(view.levelCount == 5)
        #expect(view.eventType == .advertise)
        #expect(view.isRawTopic == false)
        #expect(try #require(view.level(0)).equals("coaty"))
        #expect(try #require(view.level(1)).equals("3"))
        #expect(try #require(view.level(2)).equals("wire-compat-v1"))
        #expect(try #require(view.eventTypeFilter).equals("sensors"))
    }

    @Test
    func topicViewParsesQueryWithCorrelationId() throws {
        let topic = "coaty/3/wire-compat-v1/QRY/55555555-5555-4555-8555-555555555555/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        let bytes = Array(topic.utf8)
        let view = bytes.withUnsafeBufferPointer { buf in
            TopicView(topicBytes: buf.baseAddress!, length: buf.count)
        }

        #expect(view.levelCount == 6)
        #expect(view.eventType == .query)
        #expect(try #require(view.level(4)).equals("55555555-5555-4555-8555-555555555555"))
        #expect(try #require(view.level(5)).equals("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"))
    }

    @Test
    func topicViewIdentifiesRawTopic() throws {
        let topic = "external/wire-compat-v1/io-external-1"
        let bytes = Array(topic.utf8)
        let view = bytes.withUnsafeBufferPointer { buf in
            TopicView(topicBytes: buf.baseAddress!, length: buf.count)
        }

        #expect(view.isRawTopic == true)
        #expect(view.eventType == nil)
    }

    @Test
    func topicViewParsesAssociateWithFilter() throws {
        let topic = "coaty/3/wire-compat-v1/ASC:io-context-1/55555555-5555-4555-8555-555555555555"
        let bytes = Array(topic.utf8)
        let view = bytes.withUnsafeBufferPointer { buf in
            TopicView(topicBytes: buf.baseAddress!, length: buf.count)
        }

        #expect(view.eventType == .associate)
        #expect(try #require(view.eventTypeFilter).equals("io-context-1"))

        let typedTopic = "coaty/3/wire-compat-v1/ADV::coaty.Sensor/33333333-3333-4333-8333-333333333333"
        let typedBytes = Array(typedTopic.utf8)
        let typedView = typedBytes.withUnsafeBufferPointer { buffer in
            TopicView(topicBytes: buffer.baseAddress!, length: buffer.count)
        }
        #expect(try #require(typedView.eventTypeFilter).equals("coaty.Sensor"))
    }

    @Test
    func topicViewBoundsIndexesAndRetainsOverflow() throws {
        let topic = "a/b/c/d/e/f/g"
        let bytes = Array(topic.utf8)
        let view = bytes.withUnsafeBufferPointer { buffer in
            TopicView(topicBytes: buffer.baseAddress!, length: buffer.count)
        }
        #expect(view.levelCount == 7)
        #expect(try #require(view.level(0)).equals("a"))
        #expect(try #require(view.level(6)).equals("g"))
        #expect(view.level(-1) == nil)
        #expect(view.level(7) == nil)

        let overflowing = Array("a/b/c/d/e/f/g/h".utf8)
        let overflowingView = overflowing.withUnsafeBufferPointer { buffer in
            TopicView(topicBytes: buffer.baseAddress!, length: buffer.count)
        }
        #expect(overflowingView.levelCount > WireBufferConfig.maxTopicLevels)
        #expect(overflowingView.level(7) == nil)
        #expect(throws: WireDecodeError.self) {
            try overflowingView.validate()
        }
    }

    @Test
    func topicViewRejectsTotalLengthAboveLimit() throws {
        let bytes = Array((
            "coaty/3/ns/ADV/" + String(repeating: "A", count: WireBufferConfig.maxTopicLength)
        ).utf8)
        #expect(bytes.count > WireBufferConfig.maxTopicLength)
        let view = bytes.withUnsafeBufferPointer { buffer in
            TopicView(topicBytes: buffer.baseAddress!, length: buffer.count)
        }
        #expect(throws: WireDecodeError.self) {
            try view.validate()
        }
    }

    // MARK: - UUID16

    @Test
    func uuid16ParsesValidUuid() throws {
        let uuid = UUID16(parsing: "33333333-3333-4333-8333-333333333333")
        #expect(uuid != nil)
    }

    @Test
    func uuid16RejectsInvalidUuid() {
        #expect(UUID16(parsing: "not-a-uuid") == nil)
        #expect(UUID16(parsing: "33333333-3333-4333-8333-33333333333") == nil) // too short
        #expect(UUID16(parsing: "33333333-3333-4333-8333-3333333333333") == nil) // too long
        #expect(UUID16(parsing: "3333333333334333833333333333333333") == nil) // no dashes
    }

    @Test
    func uuid16Equatable() throws {
        let a = try #require(UUID16(parsing: "11111111-2222-3333-4444-555555555555"))
        let b = try #require(UUID16(parsing: "11111111-2222-3333-4444-555555555555"))
        let c = try #require(UUID16(parsing: "11111111-2222-3333-4444-555555555556"))

        #expect(a == b)
        #expect(a != c)
    }

    @Test
    func uuid16FromByteSlice() throws {
        let uuidString = "44444444-4444-4444-8444-444444444444"
        let bytes = Array(uuidString.utf8)
        let slice = bytes.withUnsafeBufferPointer { buf in
            ByteSlice(bytes: buf.baseAddress!, length: buf.count)
        }
        let uuid = UUID16(parsing: slice)
        #expect(uuid != nil)
    }

    // MARK: - WireReader

    @Test
    func wireReaderReadsStringField() throws {
        let json = #"{"ioSourceId":"33333333-3333-4333-8333-333333333333","ioActorId":"44444444-4444-4444-8444-444444444444"}"#
        let bytes = Array(json.utf8)
        let reader = bytes.withUnsafeBufferPointer { buf in
            WireReader(bytes: buf.baseAddress!, length: buf.count)
        }

        let sourceId = reader.readString("ioSourceId")
        #expect(try #require(sourceId).equals("33333333-3333-4333-8333-333333333333"))

        let actorId = reader.readString("ioActorId")
        #expect(try #require(actorId).equals("44444444-4444-4444-8444-444444444444"))
    }

    @Test
    func wireReaderReadsIntField() throws {
        let json = #"{"updateRate":250}"#
        let bytes = Array(json.utf8)
        let reader = bytes.withUnsafeBufferPointer { buf in
            WireReader(bytes: buf.baseAddress!, length: buf.count)
        }

        #expect(reader.readInt("updateRate") == 250)
    }

    @Test
    func ioStateWireDataRejectsNegativeUpdateRate() throws {
        do {
            _ = try decodeIoStateData(#"{"hasAssociations":true,"updateRate":-1}"#)
            Issue.record("Negative updateRate was accepted")
        } catch let error as WireDecodeError {
            guard case .invalidValue = error.reason else {
                Issue.record("Negative updateRate returned the wrong error: \(error.reason)")
                return
            }
            #expect(error.field != nil)
        }
    }

    @Test
    func ioStateWireDataAcceptsOptionalAndBoundaryUpdateRates() throws {
        let payloads: [(json: String, expected: Int?)] = [
            (#"{"hasAssociations":false}"#, nil),
            (#"{"hasAssociations":true,"updateRate":null}"#, nil),
            (#"{"hasAssociations":true,"updateRate":0}"#, 0),
            (#"{"hasAssociations":true,"updateRate":250}"#, 250),
            ("{\"hasAssociations\":true,\"updateRate\":\(Int.max)}", Int.max),
        ]

        for payload in payloads {
            let data = try decodeIoStateData(payload.json)
            #expect(data.updateRate == payload.expected)
        }
    }

    @Test
    func ioStateWireDataRejectsMalformedAndWronglyTypedFields() {
        let invalidPayloads = [
            #"{}"#,
            #"{"hasAssociations":1}"#,
            #"{"hasAssociations":true,"updateRate":"250"}"#,
            #"{"hasAssociations":true,"updateRate":true}"#,
            "{\"hasAssociations\":true,\"updateRate\":\(String(Int.max))0}",
            #"{"hasAssociations":true"#,
        ]

        for payload in invalidPayloads {
            do {
                _ = try decodeIoStateData(payload)
                Issue.record("Invalid IoState payload was accepted: \(payload)")
            } catch let error as WireDecodeError {
                #expect(error.field != nil || payload == #"{"hasAssociations":true"#)
            } catch {
                Issue.record("Unexpected error type: \(error)")
            }
        }
    }

    @Test
    func wireReaderReadsNegativeInt() throws {
        let json = #"{"n":-42}"#
        let bytes = Array(json.utf8)
        let reader = bytes.withUnsafeBufferPointer { buf in
            WireReader(bytes: buf.baseAddress!, length: buf.count)
        }

        #expect(reader.readInt("n") == -42)
    }

    @Test
    func wireReaderReadsIntMinAndIntMax() throws {
        let minJson = "{\"n\":\(Int.min)}"
        let maxJson = "{\"n\":\(Int.max)}"

        let minBytes = Array(minJson.utf8)
        let minReader = minBytes.withUnsafeBufferPointer { buf in
            WireReader(bytes: buf.baseAddress!, length: buf.count)
        }
        #expect(minReader.readInt("n") == Int.min)

        let maxBytes = Array(maxJson.utf8)
        let maxReader = maxBytes.withUnsafeBufferPointer { buf in
            WireReader(bytes: buf.baseAddress!, length: buf.count)
        }
        #expect(maxReader.readInt("n") == Int.max)
    }

    @Test
    func wireReaderReadsIntOverflowReturnsNil() throws {
        // Regression for #222: a value exceeding Int.max must return nil,
        // not trap on signed-integer overflow.
        let json = #"{"n":99999999999999999999}"#
        let bytes = Array(json.utf8)
        let reader = bytes.withUnsafeBufferPointer { buf in
            WireReader(bytes: buf.baseAddress!, length: buf.count)
        }

        #expect(reader.readInt("n") == nil)
    }

    @Test
    func wireReaderReadsLoneMinusSignReturnsNil() throws {
        // Regression for #222: a lone '-' is not a valid integer.
        let json = #"{"n":-}"#
        let bytes = Array(json.utf8)
        let reader = bytes.withUnsafeBufferPointer { buf in
            WireReader(bytes: buf.baseAddress!, length: buf.count)
        }

        #expect(reader.readInt("n") == nil)
    }

    @Test
    func wireReaderReadsBoolField() throws {
        let json = #"{"isExternalRoute":true}"#
        let bytes = Array(json.utf8)
        let reader = bytes.withUnsafeBufferPointer { buf in
            WireReader(bytes: buf.baseAddress!, length: buf.count)
        }

        #expect(reader.readBool("isExternalRoute") == true)
    }

    @Test
    func wireReaderReadsUUIDField() throws {
        let json = #"{"ioSourceId":"33333333-3333-4333-8333-333333333333"}"#
        let bytes = Array(json.utf8)
        let reader = bytes.withUnsafeBufferPointer { buf in
            WireReader(bytes: buf.baseAddress!, length: buf.count)
        }

        let uuid = reader.readUUID("ioSourceId")
        #expect(uuid != nil)
    }

    @Test
    func wireReaderReadsRawObjectField() throws {
        let json = #"{"result":{"temp":23.5,"unit":"C"}}"#
        let bytes = Array(json.utf8)
        let reader = bytes.withUnsafeBufferPointer { buf in
            WireReader(bytes: buf.baseAddress!, length: buf.count)
        }

        let raw = reader.readField("result")
        #expect(raw != nil)
        // The raw bytes should contain the object
        let rawStr = String(decoding: (0..<raw!.length).map { raw!.byte(at: $0)! }, as: UTF8.self)
        #expect(rawStr.contains("\"temp\"") == true)
    }

    @Test
    func wireReaderReadsSiblingsAfterNestedObjectAndArray() throws {
        let json = #"{"object":{"value":1},"privateData":{"foo":"bar"},"objects":[{"id":1}],"filter":["one"]}"#
        let bytes = Array(json.utf8)
        let reader = bytes.withUnsafeBufferPointer { buf in
            WireReader(bytes: buf.baseAddress!, length: buf.count)
        }

        #expect(reader.readField("privateData") != nil)
        #expect(reader.readField("filter") != nil)
    }

    @Test
    func wireReaderReturnsNilForMissingField() throws {
        let json = #"{"foo":"bar"}"#
        let bytes = Array(json.utf8)
        let reader = bytes.withUnsafeBufferPointer { buf in
            WireReader(bytes: buf.baseAddress!, length: buf.count)
        }

        #expect(reader.readString("baz") == nil)
    }

    @Test
    func wireReaderReadsNullField() throws {
        let json = #"{"metadata":null}"#
        let bytes = Array(json.utf8)
        let reader = bytes.withUnsafeBufferPointer { buf in
            WireReader(bytes: buf.baseAddress!, length: buf.count)
        }

        let raw = reader.readField("metadata")
        #expect(try #require(raw).equals("null"))
    }

    @Test
    func wireReaderReadsFalseBool() throws {
        let json = #"{"flag":false}"#
        let bytes = Array(json.utf8)
        let reader = bytes.withUnsafeBufferPointer { buf in
            WireReader(bytes: buf.baseAddress!, length: buf.count)
        }

        #expect(reader.readBool("flag") == false)
    }

    @Test
    func wireReaderTruncatedTrueLiteralDoesNotReadOutOfBounds() throws {
        // Regression for #221: truncated "tru" must not read past the buffer.
        let json = #"{"a":tru"#
        let bytes = Array(json.utf8)
        let reader = bytes.withUnsafeBufferPointer { buf in
            WireReader(bytes: buf.baseAddress!, length: buf.count)
        }

        #expect(reader.readBool("a") == nil)
    }

    @Test
    func wireReaderTruncatedFalseLiteralDoesNotReadOutOfBounds() throws {
        // Regression for #221: truncated "fals" must not read past the buffer.
        let json = #"{"a":fals"#
        let bytes = Array(json.utf8)
        let reader = bytes.withUnsafeBufferPointer { buf in
            WireReader(bytes: buf.baseAddress!, length: buf.count)
        }

        #expect(reader.readBool("a") == nil)
    }

    @Test
    func wireReaderTruncatedNullLiteralDoesNotReadOutOfBounds() throws {
        // Regression for #221: truncated "nul" must not read past the buffer.
        let json = #"{"a":nul"#
        let bytes = Array(json.utf8)
        let reader = bytes.withUnsafeBufferPointer { buf in
            WireReader(bytes: buf.baseAddress!, length: buf.count)
        }

        #expect(reader.readField("a") == nil)
        #expect(reader.readBool("a") == nil)
    }

    @Test
    func wireReaderHandlesEscapedStringKeys() throws {
        let json = #"{"weird\"key":"value"}"#
        let bytes = Array(json.utf8)
        let reader = bytes.withUnsafeBufferPointer { buf in
            WireReader(bytes: buf.baseAddress!, length: buf.count)
        }

        // The escaped key should not match "weird"key" as a static string,
        // but the reader should still skip it and not crash.
        #expect(reader.readString("normalKey") == nil)
    }

    @Test
    func wireReaderReadsAssociateEventFields() throws {
        // Simulates the exact wire shape a CoatyJS Associate event has
        let json = #"{"ioSourceId":"33333333-3333-4333-8333-333333333333","ioActorId":"44444444-4444-4444-8444-444444444444","associatingRoute":"coaty/3/wire-compat-v1/IOV/33333333-3333-4333-8333-333333333333","updateRate":250}"#
        let bytes = Array(json.utf8)
        let reader = bytes.withUnsafeBufferPointer { buf in
            WireReader(bytes: buf.baseAddress!, length: buf.count)
        }

        let sourceId = reader.readUUID("ioSourceId")
        let actorId = reader.readUUID("ioActorId")
        let route = reader.readString("associatingRoute")
        let updateRate = reader.readInt("updateRate")

        #expect(sourceId != nil)
        #expect(actorId != nil)
        #expect(try #require(route).equals("coaty/3/wire-compat-v1/IOV/33333333-3333-4333-8333-333333333333"))
        #expect(updateRate == 250)
    }

    @Test
    func wireWriterEncodesIntMinWithSingleMinusSign() throws {
        // Regression for #223: Int.min must encode as -9223372036854775808,
        // not --9223372036854775808.
        var buffer = [UInt8](repeating: 0, count: 32)
        var writer = buffer.withUnsafeMutableBufferPointer { buf in
            WireWriter(buffer: buf.baseAddress!, capacity: buf.count)
        }
        try writer.writeInt(Int.min)
        let written = String(decoding: buffer[0..<writer.position], as: UTF8.self)
        #expect(written == "-9223372036854775808")
    }

    @Test
    func wireWriterEncodesUUID() throws {
        // Regression for #224: writeUUID must produce the canonical
        // 8-4-4-4-12 lowercase-hex form without heap allocations.
        let uuid = try #require(UUID16(parsing: "33333333-3333-4333-8333-333333333333"))
        var buffer = [UInt8](repeating: 0, count: 40)
        var writer = buffer.withUnsafeMutableBufferPointer { buf in
            WireWriter(buffer: buf.baseAddress!, capacity: buf.count)
        }
        try writer.writeUUID(uuid)
        let written = String(decoding: buffer[0..<writer.position], as: UTF8.self)
        #expect(written == "33333333-3333-4333-8333-333333333333")
        #expect(writer.position == 36)
    }

    @Test
    func strictReaderRejectsTrailingAndMalformedJSON() throws {
        let malformed = Array(#"{"payload":{"x":1}extra"#.utf8)
        let trailing = Array(#"{"payload":1} trailing"#.utf8)
        for bytes in [malformed, trailing] {
            let reader = bytes.withUnsafeBufferPointer {
                WireReader(bytes: $0.baseAddress!, length: $0.count)
            }
            #expect((try? reader.validate()) == nil)
        }
    }

    @Test
    func ownedWireEventCopiesPayload() throws {
        var source = Array(#"{"payload":{"value":1}}"#.utf8)
        let owned = try source.withUnsafeBufferPointer { buffer -> OwnedWireEvent in
            let reader = WireReader(bytes: buffer.baseAddress!, length: buffer.count)
            return try BorrowedWireEvent.ioValue(try IoValueWireData(from: reader)).owned()
        }
        source[2] = 0x58
        if case .ioValue(let value) = owned {
            #expect(value.payload.first == 0x7B)
        } else { Issue.record("wrong owned event family") }
    }

    @Test
    func byteSliceBoundsAreNonTrapping() {
        let bytes: [UInt8] = [1, 2, 3]
        let slice = bytes.withUnsafeBufferPointer { ByteSlice(bytes: $0.baseAddress!, length: $0.count) }
        #expect(slice.byte(at: -1) == nil)
        #expect(slice.byte(at: 3) == nil)
        #expect(slice.subSlice(from: -1, length: 1).length == 0)
        #expect(slice.subSlice(from: 2, length: 2).length == 0)
    }

    @Test
    func byteSliceOwnedBytesCopyOutlivesTheBorrowedBuffer() {
        var source: [UInt8] = [0x7B, 0x22, 0x61, 0x22, 0x7D]
        let owned = source.withUnsafeBufferPointer { buffer in
            ByteSlice(bytes: buffer.baseAddress! + 1, length: 3).ownedBytes()
        }
        source[2] = 0x58
        #expect(owned == [0x22, 0x61, 0x22])
        #expect(ByteSlice.empty.ownedBytes().isEmpty)
    }

    @Test
    func byteSliceTestReflectionShowsHexAndText() {
        Array("ADV".utf8).withUnsafeBufferPointer { buffer in
            let slice = ByteSlice(bytes: buffer.baseAddress!, length: buffer.count)
            let fields = wireTestMirrorFields(slice)
            #expect(fields["length"] as? Int == 3)
            #expect(fields["hex"] as? String == "41 44 56")
            #expect(fields["text"] as? String == "ADV")
        }
    }

    @Test
    func byteSliceTestReflectionTruncatesHex() {
        let bytes = [UInt8](repeating: 0xAB, count: 100)
        #expect(WireTestReflection.hex(bytes, limit: 4) == "ab ab ab ab ...")
    }

    @Test
    func topicViewTestReflectionShowsLevelsAndText() {
        Array("coaty/3/ns/ADV/33333333-3333-4333-8333-333333333333".utf8).withUnsafeBufferPointer { buffer in
            let view = TopicView(topicBytes: buffer.baseAddress!, length: buffer.count)
            let fields = wireTestMirrorFields(view)
            #expect(fields["levelCount"] as? Int == 5)
            #expect(fields["namespace"] as? String == "ns")
            #expect(fields["sourceId"] as? String == "33333333-3333-4333-8333-333333333333")
            #expect((fields["text"] as? String)?.hasPrefix("coaty/3/ns/ADV/") == true)
        }
    }

    @Test
    func negativeLengthsAreClampedToZeroWithoutTrapping() throws {
        var dummy: UInt8 = 0
        withUnsafePointer(to: &dummy) { pointer in
            let slice = ByteSlice(bytes: pointer, length: -1)
            #expect(slice.length == 0)
            #expect(slice.byte(at: 0) == nil)
            #expect(slice == ByteSlice(bytes: pointer, length: 0))

            let view = TopicView(topicBytes: pointer, length: -1)
            #expect(view.levelCount == 0)
            #expect(view.eventType == nil)
            #expect(view.isRawTopic)

            let reader = WireReader(bytes: pointer, length: -1)
            #expect(reader.length == 0)
            do {
                try reader.validate()
                Issue.record("expected empty reader validation to fail")
            } catch {}
        }
    }

    @Test
    func writerReportsOverflowRatherThanTrapping() throws {
        // A tiny writer with a valid, growing number of fields: writing past the
        // destination capacity must surface bufferOverflow rather than trap.
        var buffer = [UInt8](repeating: 0, count: 8)
        try buffer.withUnsafeMutableBufferPointer { destination in
            var writer = WireWriter(buffer: destination.baseAddress!, capacity: destination.count)
            do {
                while true {
                    try writer.writeIntField("k", 1)
                }
            } catch let error as WireEncodeError {
                #expect(error == .bufferOverflow)
            }
        }
    }

    @Test
    func rawWriterAcceptsScalarArrayAndStringValues() throws {
        let fragments = ["1", "true", "null", "[1,2]", #""text""#]
        for fragment in fragments {
            let bytes = Array(fragment.utf8)
            var output = [UInt8](repeating: 0, count: 64)
            try bytes.withUnsafeBufferPointer { input in
                try output.withUnsafeMutableBufferPointer { destination in
                    var writer = WireWriter(buffer: destination.baseAddress!, capacity: destination.count)
                    try writer.writeRawField("value", ByteSlice(bytes: input.baseAddress!, length: input.count))
                }
            }
        }
    }

    @Test
    func stringWriterDistinguishesPlainAndEncodedContent() throws {
        let plain = Array(#"line\nbreak"#.utf8)
        var plainOutput = [UInt8](repeating: 0, count: 64)
        let plainCount = try plain.withUnsafeBufferPointer { input in
            try plainOutput.withUnsafeMutableBufferPointer { output in
                var writer = WireWriter(buffer: output.baseAddress!, capacity: output.count)
                try writer.writeStringField("value", ByteSlice(bytes: input.baseAddress!, length: input.count))
                return writer.position
            }
        }
        #expect(String(decoding: plainOutput[..<plainCount], as: UTF8.self) == #""value":"line\\nbreak""#)

        let source = Array(#"{"externalId":"line\nbreak"}"#.utf8)
        var encodedOutput = [UInt8](repeating: 0, count: 64)
        let encodedCount = try source.withUnsafeBufferPointer { input in
            let reader = WireReader(bytes: input.baseAddress!, length: input.count)
            let encoded = try DiscoverWireData(from: reader)
            return try encodedOutput.withUnsafeMutableBufferPointer { output in
                var writer = WireWriter(buffer: output.baseAddress!, capacity: output.count)
                try encoded.encode(to: &writer)
                return writer.position
            }
        }
        #expect(String(decoding: encodedOutput[..<encodedCount], as: UTF8.self) == #"{"externalId":"line\nbreak"}"#)
    }

    // MARK: - WireCodec profile dispatch

    @Test
    func wireCodecReaderDispatchesByProfile() throws {
        let json = Array(#"{"updateRate":250,"flag":true,"label":"abc"}"#.utf8)
        // A CBOR map: {"flag": true, "label": "abc", "updateRate": 250}
        // in deterministic key order.
        let cbor: [UInt8] = [0xA3]
            + [0x64] + Array("flag".utf8) + [0xF5]
            + [0x65] + Array("label".utf8) + [0x63] + Array("abc".utf8)
            + [0x6A] + Array("updateRate".utf8) + [0x18, 0xFA]

        json.withUnsafeBufferPointer { buffer in
            let reader = WireCodec(profile: .coaty3JSON).reader(
                bytes: buffer.baseAddress!, length: buffer.count
            )
            #expect(reader.readInt("updateRate") == 250)
            #expect(reader.readBool("flag") == true)
        }
        try cbor.withUnsafeBufferPointer { buffer in
            let reader = WireCodec(profile: .axoloty1CBOR).reader(
                bytes: buffer.baseAddress!, length: buffer.count
            )
            #expect(reader.readInt("updateRate") == 250)
            #expect(reader.readBool("flag") == true)
            #expect(reader.readString("label")?.equals("abc") == true)
            #expect(reader.readOptionalRaw("updateRate") != nil)
            try reader.validate()
        }
    }

    @Test
    func wireCodecJSONWriterMatchesTheDirectWriter() throws {
        // The default engine and the coaty/3 codec produce identical bytes.
        let value = Array(#"line\nbreak"#.utf8)
        var direct = [UInt8](repeating: 0, count: 64)
        var throughCodec = [UInt8](repeating: 0, count: 64)
        let directCount = try direct.withUnsafeMutableBufferPointer { output in
            var writer = WireWriter(buffer: output.baseAddress!, capacity: output.count)
            try value.withUnsafeBufferPointer { input in
                try writer.writeStringField(
                    "value", ByteSlice(bytes: input.baseAddress!, length: input.count)
                )
            }
            return writer.position
        }
        let codecCount = try throughCodec.withUnsafeMutableBufferPointer { output in
            var writer = WireCodec(profile: .coaty3JSON).writer(
                buffer: output.baseAddress!, capacity: output.count
            )
            try value.withUnsafeBufferPointer { input in
                try writer.writeStringField(
                    "value", ByteSlice(bytes: input.baseAddress!, length: input.count)
                )
            }
            return writer.position
        }
        #expect(direct[0..<directCount] == throughCodec[0..<codecCount])
    }

    @Test
    func wireCodecAppliesTheProfilesBareValueGate() {
        let binary: [UInt8] = [0x00, 0x01, 0x02]
        let invalidJSON: [UInt8] = [0x22, 0x61, 0x22, 0x22] // "a""
        let jsonCodec = WireCodec(profile: .coaty3JSON)
        let cborCodec = WireCodec(profile: .axoloty1CBOR)
        for bytes in [binary, invalidJSON] {
            let slice = bytes.withUnsafeBufferPointer {
                ByteSlice(bytes: $0.baseAddress!, length: $0.count)
            }
            // coaty/3 keeps the sealed first-byte sniff.
            #expect(jsonCodec.isValidBareValue(slice) == (bytes == binary))
            // axoloty/1 cannot sniff, so the gate accepts and the bounded
            // decode owns validation.
            #expect(cborCodec.isValidBareValue(slice))
        }
    }

    @Test
    func wireCodecCopiesDecodedStringContentByProfile() throws {
        // coaty/3 decodes JSON escape sequences while copying.
        let escaped = Array(#"line\nbreak"#.utf8)
        var decoded = InlineArray<16, UInt8>(repeating: 0)
        let jsonCount = try escaped.withUnsafeBufferPointer { buffer in
            let slice = ByteSlice(bytes: buffer.baseAddress!, length: buffer.count)
            return try WireCodec(profile: .coaty3JSON).copyDecodedString(slice, into: &decoded)
        }
        #expect(jsonCount == 10)
        #expect(decoded[0] == 0x6C && decoded[4] == 0x0A)

        // axoloty/1 copies plain UTF-8 content unchanged.
        let plain = Array("line\nbreak".utf8)
        var copied = InlineArray<16, UInt8>(repeating: 0)
        let cborCount = try plain.withUnsafeBufferPointer { buffer in
            let slice = ByteSlice(bytes: buffer.baseAddress!, length: buffer.count)
            return try WireCodec(profile: .axoloty1CBOR).copyDecodedString(slice, into: &copied)
        }
        #expect(cborCount == plain.count)
        for (index, byte) in plain.enumerated() {
            #expect(copied[index] == byte)
        }
    }

    @Test
    func wireFacadeExposesCBOROnlyLexicalKinds() throws {
        // The facade reaches the axoloty/1-only float, byte-string, and tag
        // kinds without a caller constructing a CBORReader or CBORWriter.
        let blob: [UInt8] = [0xDE, 0xAD, 0xBE, 0xEF]
        var output = [UInt8](repeating: 0, count: 128)
        let count = try output.withUnsafeMutableBufferPointer { destination in
            var writer = WireCodec(profile: .axoloty1CBOR).writer(
                buffer: destination.baseAddress!, capacity: destination.count
            )
            try writer.beginObject()
            try blob.withUnsafeBufferPointer { bytes in
                try writer.writeByteStringField(
                    "blob", ByteSlice(bytes: bytes.baseAddress!, length: bytes.count)
                )
            }
            try writer.writeFloatField("ratio", 1.5)
            // A tag and its tagged item form one CBOR data item.
            try writer.writeTagField("time", 1)
            try writer.writeInt(1_700_000_000)
            try writer.endObject()
            return writer.position
        }
        try output.withUnsafeBufferPointer { buffer in
            let reader = WireCodec(profile: .axoloty1CBOR).reader(
                bytes: buffer.baseAddress!, length: count
            )
            #expect(reader.readByteString("blob")?.ownedBytes() == blob)
            #expect(reader.readFloat("ratio") == 1.5)
            #expect(reader.readTag("time") == 1)
            try reader.validate()
        }
    }

    @Test
    func wireFacadeCBOROnlyLexicalKindsRejectJSON() throws {
        // JSON has no byte-string, float, or tag token, so the accessors
        // return nil and the writers reject the value.
        let json = Array(#"{"blob":"x","ratio":1.5,"time":1}"#.utf8)
        json.withUnsafeBufferPointer { buffer in
            let reader = WireCodec(profile: .coaty3JSON).reader(
                bytes: buffer.baseAddress!, length: buffer.count
            )
            #expect(reader.readByteString("blob") == nil)
            #expect(reader.readFloat("ratio") == nil)
            #expect(reader.readTag("time") == nil)
        }
        var output = [UInt8](repeating: 0, count: 64)
        try output.withUnsafeMutableBufferPointer { destination in
            var writer = WireCodec(profile: .coaty3JSON).writer(
                buffer: destination.baseAddress!, capacity: destination.count
            )
            try writer.beginObject()
            #expect(throws: WireEncodeError.invalidValue) {
                try writer.writeByteStringField("blob", ByteSlice.empty)
            }
            #expect(throws: WireEncodeError.invalidValue) {
                try writer.writeFloatField("ratio", 1.5)
            }
            #expect(throws: WireEncodeError.invalidValue) {
                try writer.writeTagField("time", 1)
            }
        }
    }

    // MARK: - Standalone axoloty/1 lexical writers

    @Test
    func wireFacadeStandaloneLexicalWritersRoundTrip() throws {
        // The standalone writers emit bare items for array positions with no
        // key, unlike the `...Field` variants.
        let blob: [UInt8] = [0xDE, 0xAD, 0xBE, 0xEF]
        let encoded = try blob.withUnsafeBufferPointer { (bytes: UnsafeBufferPointer<UInt8>) throws -> [UInt8] in
            let slice = ByteSlice(bytes: bytes.baseAddress!, length: bytes.count)
            return try encodeWireValue(profile: .axoloty1CBOR) { (writer: inout WireWriter) throws(WireEncodeError) in
                try writer.beginArray()
                try writer.writeFloat64(1.5)
                try writer.writeByteString(slice)
                try writer.writeTag(1)
                try writer.writeInt(1_700_000_000)
                try writer.endArray()
            }
        }
        // 1.5 is losslessly single precision, so the float is four bytes; the
        // tag and its integer form one array element.
        let expected: [UInt8] = [
            0x83,
            0xFA, 0x3F, 0xC0, 0x00, 0x00,
            0x44, 0xDE, 0xAD, 0xBE, 0xEF,
            0xC1, 0x1A, 0x65, 0x53, 0xF1, 0x00,
        ]
        #expect(encoded == expected)

        encoded.withUnsafeBufferPointer { buffer in
            var reader = CBORReader(bytes: buffer.baseAddress!, length: encoded.count)
            #expect((try? reader.readArrayHeader()) == 3)
            #expect((try? reader.readFloat()) == 1.5)
            #expect((try? reader.readByteString())?.ownedBytes() == blob)
            #expect((try? reader.readTag()) == 1)
            #expect((try? reader.readInteger()) == 1_700_000_000)
            #expect(reader.isAtEnd)
        }
    }

    @Test
    func wireFacadeStandaloneLexicalWritersRejectJSON() throws {
        // JSON has no byte-string, float, or tag token, so every standalone
        // writer rejects the value with `invalidValue`.
        _ = try encodeWireValue(profile: .coaty3JSON) { (writer: inout WireWriter) throws(WireEncodeError) in
            try writer.beginArray()
            #expect(throws: WireEncodeError.invalidValue) {
                try writer.writeFloat64(1.5)
            }
            #expect(throws: WireEncodeError.invalidValue) {
                try writer.writeByteString(ByteSlice.empty)
            }
            #expect(throws: WireEncodeError.invalidValue) {
                try writer.writeTag(1)
            }
        }
    }

    // MARK: - IoValue typed payloads

    @Test
    func ioValueWireDataExposesTypedCBORPayloads() throws {
        // A first-party DTO now consumes the facade's float, byte-string, and
        // tag readers through its real `payload` field.
        let blob: [UInt8] = [0xDE, 0xAD, 0xBE, 0xEF]

        let floatBytes = try encodeWireValue(profile: .axoloty1CBOR) { (writer: inout WireWriter) throws(WireEncodeError) in
            try writer.beginObject()
            try writer.writeFloatField("payload", 1.5)
            try writer.endObject()
        }
        try floatBytes.withUnsafeBufferPointer { buffer in
            let reader = WireCodec(profile: .axoloty1CBOR).reader(
                bytes: buffer.baseAddress!, length: floatBytes.count
            )
            let value = try IoValueWireData(from: reader)
            #expect(value.floatPayload == 1.5)
            #expect(value.byteStringPayload == nil)
            #expect(value.tagPayload == nil)
        }

        let bytesBytes = try blob.withUnsafeBufferPointer { (bytes: UnsafeBufferPointer<UInt8>) throws -> [UInt8] in
            let slice = ByteSlice(bytes: bytes.baseAddress!, length: bytes.count)
            return try encodeWireValue(profile: .axoloty1CBOR) { (writer: inout WireWriter) throws(WireEncodeError) in
                try writer.beginObject()
                try writer.writeByteStringField("payload", slice)
                try writer.endObject()
            }
        }
        try bytesBytes.withUnsafeBufferPointer { buffer in
            let reader = WireCodec(profile: .axoloty1CBOR).reader(
                bytes: buffer.baseAddress!, length: bytesBytes.count
            )
            let value = try IoValueWireData(from: reader)
            #expect(value.floatPayload == nil)
            #expect(value.byteStringPayload?.ownedBytes() == blob)
            #expect(value.tagPayload == nil)
        }

        let tagBytes = try encodeWireValue(profile: .axoloty1CBOR) { (writer: inout WireWriter) throws(WireEncodeError) in
            try writer.beginObject()
            try writer.writeTagField("payload", 1)
            try writer.writeInt(1_700_000_000)
            try writer.endObject()
        }
        try tagBytes.withUnsafeBufferPointer { buffer in
            let reader = WireCodec(profile: .axoloty1CBOR).reader(
                bytes: buffer.baseAddress!, length: tagBytes.count
            )
            let value = try IoValueWireData(from: reader)
            #expect(value.floatPayload == nil)
            #expect(value.byteStringPayload == nil)
            #expect(value.tagPayload == 1)
        }
    }

    @Test
    func ioValueWireDataTypedViewsAreNilUnderJSON() throws {
        let json = Array(#"{"payload":1.5}"#.utf8)
        try json.withUnsafeBufferPointer { buffer in
            let reader = WireCodec(profile: .coaty3JSON).reader(
                bytes: buffer.baseAddress!, length: json.count
            )
            let value = try IoValueWireData(from: reader)
            // JSON has no float, byte-string, or tag token. The raw payload is
            // retained unchanged and every typed view stays nil.
            #expect(value.floatPayload == nil)
            #expect(value.byteStringPayload == nil)
            #expect(value.tagPayload == nil)
            #expect(value.payload.ownedBytes() == Array("1.5".utf8))
        }
    }

    @Test
    func ownedIoValueTypedConstructorsEncodeBareCBORItems() throws {
        // The typed constructors consume the standalone facade writers.
        let blob: [UInt8] = [0xDE, 0xAD, 0xBE, 0xEF]
        let floatOwned = try OwnedIoValueWireData(cborFloat: 1.5)
        let bytesOwned = try OwnedIoValueWireData(cborByteString: blob)
        let tagOwned = try OwnedIoValueWireData(
            cborTag: 1, taggedItem: [0x1A, 0x65, 0x53, 0xF1, 0x00]
        )

        #expect(floatOwned.profile == .axoloty1CBOR)
        #expect(floatOwned.payload == [0xFA, 0x3F, 0xC0, 0x00, 0x00])
        #expect(bytesOwned.payload == [0x44, 0xDE, 0xAD, 0xBE, 0xEF])
        #expect(tagOwned.payload == [0xC1, 0x1A, 0x65, 0x53, 0xF1, 0x00])
    }
}
