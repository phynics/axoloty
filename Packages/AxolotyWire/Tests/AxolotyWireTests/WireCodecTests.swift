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

        let raw = reader.readRaw("result")
        #expect(raw != nil)
        // The raw bytes should contain the object
        let rawStr = String(bytes: (0..<raw!.length).map { raw!.byte(at: $0)! }, encoding: .utf8)
        #expect(rawStr?.contains("\"temp\"") == true)
    }

    @Test
    func wireReaderReadsSiblingsAfterNestedObjectAndArray() throws {
        let json = #"{"object":{"value":1},"privateData":{"foo":"bar"},"objects":[{"id":1}],"filter":["one"]}"#
        let bytes = Array(json.utf8)
        let reader = bytes.withUnsafeBufferPointer { buf in
            WireReader(bytes: buf.baseAddress!, length: buf.count)
        }

        #expect(reader.readRaw("privateData") != nil)
        #expect(reader.readRaw("filter") != nil)
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

        let raw = reader.readRaw("metadata")
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

        #expect(reader.readRaw("a") == nil)
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
        let written = String(bytes: buffer[0..<writer.position], encoding: .utf8)
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
        let written = String(bytes: buffer[0..<writer.position], encoding: .utf8)
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
}
