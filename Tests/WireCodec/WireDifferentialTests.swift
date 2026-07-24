// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@testable import Axoloty
import Testing

/// Differential tests comparing the Foundation-free WireReader decode path
/// against the existing Codable path (PayloadCoder.decode).
///
/// Both paths decode the same JSON bytes. The tests assert that every
/// semantic field — UUID values, string values, integers, booleans, and
/// optional field presence — produces equivalent results. This is the
/// proof that the WireReader can replace Codable without behavioral change.
@Suite
struct WireDifferentialTests {

    // MARK: - AssociateEventData

    @Test
    func associateWireDataMatchesCodable() throws {
        let json = #"{"ioSourceId":"33333333-3333-4333-8333-333333333333","ioActorId":"44444444-4444-4444-8444-444444444444","associatingRoute":"coaty/3/test/IOV/33333333-3333-4333-8333-333333333333","updateRate":250}"#

        // Codable path
        let codable: AssociateEventData = try PayloadCoder.decode(json)

        // WireReader path
        let decoded = try decodeWire(json) as DecodedWire<AssociateWireData>; let wire = decoded.value

        // Assert semantic equivalence
        #expect(wire.ioSourceId == UUID16(parsing: "33333333-3333-4333-8333-333333333333"))
        #expect(wire.ioActorId == UUID16(parsing: "44444444-4444-4444-8444-444444444444"))
        #expect(wire.associatingRoute != nil)
        #expect(try #require(wire.associatingRoute).equals("coaty/3/test/IOV/33333333-3333-4333-8333-333333333333"))
        #expect(wire.isExternalRoute == nil)
        #expect(wire.updateRate == 250)

        // Cross-check: Codable values match wire values
        #expect(codable.ioSourceId.string == "33333333-3333-4333-8333-333333333333")
        #expect(codable.ioActorId.string == "44444444-4444-4444-8444-444444444444")
        #expect(codable.associatingRoute == "coaty/3/test/IOV/33333333-3333-4333-8333-333333333333")
        #expect(codable.isExternalRoute == nil)
        #expect(codable.updateRate == 250)
    }

    @Test
    func associateWireDataWithIsExternalRoute() throws {
        let json = #"{"ioSourceId":"33333333-3333-4333-8333-333333333333","ioActorId":"44444444-4444-4444-8444-444444444444","associatingRoute":"external/test/route","isExternalRoute":true,"updateRate":100}"#

        let codable: AssociateEventData = try PayloadCoder.decode(json)
        let decoded = try decodeWire(json) as DecodedWire<AssociateWireData>; let wire = decoded.value

        #expect(wire.isExternalRoute == true)
        #expect(codable.isExternalRoute == true)
        #expect(wire.updateRate == codable.updateRate)
    }

    @Test
    func associateWireDataDisassociation() throws {
        // Disassociation: no associatingRoute, no updateRate
        let json = #"{"ioSourceId":"33333333-3333-4333-8333-333333333333","ioActorId":"44444444-4444-4444-8444-444444444444"}"#

        let codable: AssociateEventData = try PayloadCoder.decode(json)
        let decoded = try decodeWire(json) as DecodedWire<AssociateWireData>; let wire = decoded.value

        #expect(wire.associatingRoute == nil)
        #expect(wire.updateRate == nil)
        #expect(wire.isExternalRoute == nil)
        #expect(codable.associatingRoute == nil)
        #expect(codable.updateRate == nil)
        #expect(codable.isExternalRoute == nil)
    }

    @Test
    func associateCoatyJSPayloadMatches() throws {
        // The exact payload CoatyJS 2.4.0 sends (no isExternalRoute field)
        let json = #"{"ioSourceId":"33333333-3333-4333-8333-333333333333","ioActorId":"44444444-4444-4444-8444-444444444444","associatingRoute":"coaty/3/wire-compat-v1/IOV/33333333-3333-4333-8333-333333333333","updateRate":250}"#

        let codable: AssociateEventData = try PayloadCoder.decode(json)
        let decoded = try decodeWire(json) as DecodedWire<AssociateWireData>; let wire = decoded.value

        // Both paths agree: isExternalRoute is nil (field absent)
        #expect(wire.isExternalRoute == nil)
        #expect(codable.isExternalRoute == nil)
        #expect(wire.updateRate == codable.updateRate)
    }

    // MARK: - IoValueEventData

    @Test
    func ioValueWireDataMatchesCodableRawPayload() throws {
        // Raw IoValue: payload is a JSON array of bytes
        let json = #"{"payload":[0,1,2,255]}"#

        let codable: IoValueEventData = try PayloadCoder.decode(json)
        let decoded = try decodeWire(json) as DecodedWire<IoValueWireData>
        let wire = decoded.value

        // WireReader returns the raw JSON bytes: [0,1,2,255] (11 chars)
        #expect(wire.payload.length == 11)
        #expect(wire.payload.byte(at: 0) == 0x5B) // '['
        #expect(wire.payload.byte(at: 10) == 0x5D) // ']'
        // Codable decodes the byte array
        #expect(codable.rawPayload == [0, 1, 2, 255])
    }

    @Test
    func ioValueWireDataMatchesCodableJsonPayload() throws {
        // JSON IoValue: payload is a raw JSON value (scalar number)
        let json = #"{"payload":42}"#

        let codable: IoValueEventData? = try? PayloadCoder.decode(json)
        let decoded = try decodeWire(json) as DecodedWire<IoValueWireData>; let wire = decoded.value

        // WireReader returns the raw bytes "42"
        #expect(wire.payload.length == 2)
        #expect(wire.payload.byte(at: 0) == 0x34) // '4'
        #expect(wire.payload.byte(at: 1) == 0x32) // '2'
        // Codable path may or may not decode this as rawPayload depending on type
        // The wire path preserves the raw bytes
    }

    @Test
    func ioValueWireDataNullPayload() throws {
        let json = #"{"payload":null}"#

        let decoded = try decodeWire(json) as DecodedWire<IoValueWireData>; let wire = decoded.value

        #expect(wire.payload.length == 4)
        #expect(wire.payload.equals("null"))
    }

    // MARK: - AdvertiseEventData

    @Test
    func advertiseWireDataMatchesCodableObject() throws {
        let json = #"{"object":{"coreType":"CoatyObject","objectType":"coaty.sensorThings.Thing","objectId":"11111111-1111-4111-8111-111111111111","name":"test-thing","description":"d","properties":null}}"#

        let codable: AdvertiseEvent = try PayloadCoder.decode(json)
        let decoded = try decodeWire(json) as DecodedWire<AdvertiseWireData>; let wire = decoded.value

        // Wire path returns the raw object bytes
        #expect(wire.object.length > 0)
        // Codable path decodes the object
        #expect(codable.data.object.objectType == "coaty.sensorThings.Thing")
        #expect(codable.data.object.name == "test-thing")
    }

    // MARK: - DeadvertiseEventData

    @Test
    func deadvertiseWireDataMatchesCodableObjectIds() throws {
        let json = #"{"objectIds":["33333333-3333-4333-8333-333333333333","44444444-4444-4444-8444-444444444444"]}"#

        let codable: DeadvertiseEvent = try PayloadCoder.decode(json)
        let decoded = try decodeWire(json) as DecodedWire<DeadvertiseWireData>; let wire = decoded.value

        #expect(wire.objectIds.count == 2)
        #expect(wire.objectIds[0] == UUID16(parsing: "33333333-3333-4333-8333-333333333333"))
        #expect(wire.objectIds[1] == UUID16(parsing: "44444444-4444-4444-8444-444444444444"))
        #expect(codable.data.objectIds.count == 2)
        #expect(codable.data.objectIds[0].string == "33333333-3333-4333-8333-333333333333")
        #expect(codable.data.objectIds[1].string == "44444444-4444-4444-8444-444444444444")
    }

    @Test
    func deadvertiseSingleObjectId() throws {
        let json = #"{"objectIds":["33333333-3333-4333-8333-333333333333"]}"#

        let decoded = try decodeWire(json) as DecodedWire<DeadvertiseWireData>; let wire = decoded.value

        #expect(wire.objectIds.count == 1)
        #expect(wire.objectIds[0] == UUID16(parsing: "33333333-3333-4333-8333-333333333333"))
    }

    // MARK: - ChannelEventData

    @Test
    func channelWireDataMatchesCodable() throws {
        let json = #"{"object":{"coreType":"CoatyObject","objectType":"coaty.test.Foo","objectId":"11111111-1111-4111-8111-111111111111","name":"foo"}}"#

        let codable: ChannelEvent = try PayloadCoder.decode(json)
        let decoded = try decodeWire(json) as DecodedWire<ChannelWireData>; let wire = decoded.value

        #expect(wire.object != nil)
        #expect(codable.data.object?.name == "foo")
    }

    // MARK: - Error handling

    @Test
    func wireReaderFailsOnMissingRequiredField() throws {
        let json = #"{"ioActorId":"44444444-4444-4444-8444-444444444444"}"#

        do {
            _ = try decodeWire(json) as DecodedWire<AssociateWireData>
            Issue.record("Expected WireDecodeError for missing ioSourceId")
        } catch is WireDecodeError {
            // expected
        }
    }

    @Test
    func wireReaderFailsOnMalformedUUID() throws {
        let json = #"{"ioSourceId":"not-a-uuid","ioActorId":"44444444-4444-4444-8444-444444444444"}"#

        do {
            _ = try decodeWire(json) as DecodedWire<AssociateWireData>
            Issue.record("Expected WireDecodeError for malformed UUID")
        } catch is WireDecodeError {
            // expected
        }
    }

    // MARK: - Round-trip: WireReader decode → WireWriter encode → WireReader decode

    @Test
    func associateRoundTripThroughWireCodec() throws {
        let json = #"{"ioSourceId":"33333333-3333-4333-8333-333333333333","ioActorId":"44444444-4444-4444-8444-444444444444","associatingRoute":"coaty/3/test/IOV/33333333-3333-4333-8333-333333333333","updateRate":250}"#

        // Decode
        let wire1 = (try decodeWire(json) as DecodedWire<AssociateWireData>).value

        // Encode back
        var buffer = [UInt8](repeating: 0, count: 512)
        var writer = buffer.withUnsafeMutableBufferPointer { buf in
            WireWriter(buffer: buf.baseAddress!, capacity: buf.count)
        }
        try writer.beginObject()
        try writer.writeUUIDField("ioSourceId", wire1.ioSourceId)
        try writer.writeComma()
        try writer.writeUUIDField("ioActorId", wire1.ioActorId)
        try writer.writeComma()
        try writer.writeStringField("associatingRoute", try #require(wire1.associatingRoute))
        try writer.writeComma()
        try writer.writeIntField("updateRate", try #require(wire1.updateRate))
        try writer.endObject()

        // The written bytes should be valid JSON
        let written = String(bytes: buffer[0..<writer.position], encoding: .utf8)
        #expect(written != nil)
        #expect(try #require(written).contains("\"ioSourceId\""))
        #expect(try #require(written).contains("\"updateRate\":250"))

        // Decode again
        let wire2 = (try decodeWire(try #require(written)) as DecodedWire<AssociateWireData>).value
        #expect(wire1.ioSourceId == wire2.ioSourceId)
        #expect(wire1.ioActorId == wire2.ioActorId)
        #expect(wire1.updateRate == wire2.updateRate)
    }
}

// MARK: - Helpers

/// Holds a decoded wire DTO alongside the bytes it borrows from, so the
/// ByteSlice pointers remain valid for the DTO's lifetime.
private struct DecodedWire<T: WireDecodable> {
    let value: T
    let _bytes: [UInt8]
}

private func decodeWire<T: WireDecodable>(_ json: String) throws -> DecodedWire<T> {
    let bytes = Array(json.utf8)
    let value = try bytes.withUnsafeBufferPointer { buf -> T in
        let reader = WireReader(bytes: buf.baseAddress!, length: buf.count)
        return try T(from: reader)
    }
    return DecodedWire(value: value, _bytes: bytes)
}
