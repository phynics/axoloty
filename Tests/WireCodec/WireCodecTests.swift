// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@testable import Axoloty
import Testing

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
        let view = try bytes.withUnsafeBufferPointer { buf in
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
        let view = try bytes.withUnsafeBufferPointer { buf in
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
        let view = try bytes.withUnsafeBufferPointer { buf in
            TopicView(topicBytes: buf.baseAddress!, length: buf.count)
        }

        #expect(view.isRawTopic == true)
        #expect(view.eventType == nil)
    }

    @Test
    func topicViewParsesAssociateWithFilter() throws {
        let topic = "coaty/3/wire-compat-v1/ASC:io-context-1/55555555-5555-4555-8555-555555555555"
        let bytes = Array(topic.utf8)
        let view = try bytes.withUnsafeBufferPointer { buf in
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
        let slice = try bytes.withUnsafeBufferPointer { buf in
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
        let reader = try bytes.withUnsafeBufferPointer { buf in
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
        let reader = try bytes.withUnsafeBufferPointer { buf in
            WireReader(bytes: buf.baseAddress!, length: buf.count)
        }

        #expect(reader.readInt("updateRate") == 250)
    }

    @Test
    func wireReaderReadsBoolField() throws {
        let json = #"{"isExternalRoute":true}"#
        let bytes = Array(json.utf8)
        let reader = try bytes.withUnsafeBufferPointer { buf in
            WireReader(bytes: buf.baseAddress!, length: buf.count)
        }

        #expect(reader.readBool("isExternalRoute") == true)
    }

    @Test
    func wireReaderReadsUUIDField() throws {
        let json = #"{"ioSourceId":"33333333-3333-4333-8333-333333333333"}"#
        let bytes = Array(json.utf8)
        let reader = try bytes.withUnsafeBufferPointer { buf in
            WireReader(bytes: buf.baseAddress!, length: buf.count)
        }

        let uuid = reader.readUUID("ioSourceId")
        #expect(uuid != nil)
    }

    @Test
    func wireReaderReadsRawObjectField() throws {
        let json = #"{"result":{"temp":23.5,"unit":"C"}}"#
        let bytes = Array(json.utf8)
        let reader = try bytes.withUnsafeBufferPointer { buf in
            WireReader(bytes: buf.baseAddress!, length: buf.count)
        }

        let raw = reader.readRaw("result")
        #expect(raw != nil)
        // The raw bytes should contain the object
        let rawStr = String(bytes: (0..<raw!.length).map { raw!.byte(at: $0)! }, encoding: .utf8)
        #expect(rawStr?.contains("\"temp\"") == true)
    }

    @Test
    func wireReaderReturnsNilForMissingField() throws {
        let json = #"{"foo":"bar"}"#
        let bytes = Array(json.utf8)
        let reader = try bytes.withUnsafeBufferPointer { buf in
            WireReader(bytes: buf.baseAddress!, length: buf.count)
        }

        #expect(reader.readString("baz") == nil)
    }

    @Test
    func wireReaderReadsNullField() throws {
        let json = #"{"metadata":null}"#
        let bytes = Array(json.utf8)
        let reader = try bytes.withUnsafeBufferPointer { buf in
            WireReader(bytes: buf.baseAddress!, length: buf.count)
        }

        let raw = reader.readRaw("metadata")
        #expect(try #require(raw).equals("null"))
    }

    @Test
    func wireReaderHandlesEscapedStringKeys() throws {
        let json = #"{"weird\"key":"value"}"#
        let bytes = Array(json.utf8)
        let reader = try bytes.withUnsafeBufferPointer { buf in
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
        let reader = try bytes.withUnsafeBufferPointer { buf in
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
}
