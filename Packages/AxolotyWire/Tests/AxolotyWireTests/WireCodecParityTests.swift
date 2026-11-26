// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyWire
import Testing

/// Profile parity tests for the format-neutral wire codec (ADR 0011,
/// epic #977).
///
/// Every wire DTO decodes and encodes BOTH profiles from one implementation:
/// each fixture is decoded through ``WireCodec`` with `coaty/3` (JSON) and
/// `axoloty/1` (CBOR), and each encode must reproduce the fixture bytes
/// exactly. The JSON fixtures are the pre-seam `coaty/3` wire bytes, so their
/// round trips also prove the JSON engine stayed byte-identical.
@Suite("Wire codec profile parity")
struct WireCodecParityTests {

    // MARK: - Helpers

    /// Decodes one DTO from a byte array that stays alive for the caller's
    /// scope, because the returned DTO borrows the array's storage.
    private func decode<T: WireDecodable>(
        _ profile: WireProfile, _ bytes: [UInt8], as _: T.Type = T.self
    ) throws -> T {
        try bytes.withUnsafeBufferPointer { buffer in
            let reader = WireCodec(profile: profile).reader(
                bytes: buffer.baseAddress!,
                length: buffer.count
            )
            return try T(from: reader)
        }
    }

    /// Encodes one DTO through the profile-selected writer.
    private func encode<T: WireEncodable>(_ profile: WireProfile, _ value: T) throws -> [UInt8] {
        var output = [UInt8](repeating: 0, count: WireBufferConfig.maxPayloadSize)
        let count = try output.withUnsafeMutableBufferPointer { buffer -> Int in
            var writer = WireCodec(profile: profile).writer(
                buffer: buffer.baseAddress!,
                capacity: buffer.count
            )
            try value.encode(to: &writer)
            return writer.position
        }
        return Array(output[0..<count])
    }

    private func cborText(_ string: String) -> [UInt8] {
        let content = Array(string.utf8)
        let head: [UInt8]
        if content.count < 24 {
            head = [0x60 | UInt8(content.count)]
        } else if content.count <= 0xFF {
            head = [0x78, UInt8(content.count)]
        } else {
            head = [0x79, UInt8((content.count >> 8) & 0xFF), UInt8(content.count & 0xFF)]
        }
        return head + content
    }

    private func cborUUID(_ string: String) throws -> [UInt8] {
        let uuid = try #require(UUID16(parsing: string))
        var raw: [UInt8] = [0xD8, 0x25, 0x50]
        withUnsafeBytes(of: uuid.bytes) { buffer in
            for index in 0..<16 { raw.append(buffer[index]) }
        }
        return raw
    }

    private func cborInt(_ value: Int) -> [UInt8] {
        if value >= 0 {
            let unsigned = UInt64(value)
            if unsigned < 24 { return [UInt8(unsigned)] }
            if unsigned <= 0xFF { return [0x18, UInt8(unsigned)] }
            if unsigned <= 0xFFFF {
                return [0x19, UInt8((unsigned >> 8) & 0xFF), UInt8(unsigned & 0xFF)]
            }
            if unsigned <= 0xFFFF_FFFF {
                return [0x1A] + (0...3).map { UInt8((unsigned >> UInt64(24 - 8 * $0)) & 0xFF) }
            }
            return [0x1B] + (0...7).map { UInt8((unsigned >> UInt64(56 - 8 * $0)) & 0xFF) }
        }
        let magnitude = UInt64(-Int64(value) - 1)
        if magnitude < 24 { return [0x20 | UInt8(magnitude)] }
        if magnitude <= 0xFF { return [0x38, UInt8(magnitude)] }
        if magnitude <= 0xFFFF {
            return [0x39, UInt8((magnitude >> 8) & 0xFF), UInt8(magnitude & 0xFF)]
        }
        if magnitude <= 0xFFFF_FFFF {
            return [0x3A] + (0...3).map { UInt8((magnitude >> UInt64(24 - 8 * $0)) & 0xFF) }
        }
        return [0x3B] + (0...7).map { UInt8((magnitude >> UInt64(56 - 8 * $0)) & 0xFF) }
    }

    private func cborArray(_ items: [[UInt8]]) -> [UInt8] {
        let head: [UInt8] = items.count < 24 ? [0x80 | UInt8(items.count)] : [0x98, UInt8(items.count)]
        return items.reduce(head) { $0 + $1 }
    }

    /// Emits one CBOR map. The pairs must already be in deterministic key
    /// order (length first, then bytewise).
    private func cborMap(_ pairs: [([UInt8], [UInt8])]) -> [UInt8] {
        let head: [UInt8] = pairs.count < 24 ? [0xA0 | UInt8(pairs.count)] : [0xB8, UInt8(pairs.count)]
        return pairs.reduce(head) { $0 + $1.0 + $1.1 }
    }

    private let cborTrue: [UInt8] = [0xF5]
    private let cborFalse: [UInt8] = [0xF4]
    private let cborNull: [UInt8] = [0xF6]

    // MARK: - Associate

    @Test("associate decodes and encodes both profiles")
    func associateParity() throws {
        let source = "33333333-3333-4333-8333-333333333333"
        let actor = "44444444-4444-4444-8444-444444444444"
        let route = "coaty/3/fuzz/IOV/33333333-3333-4333-8333-333333333333"
        let jsonBytes = Array(
            #"{"ioSourceId":"\#(source)","ioActorId":"\#(actor)","associatingRoute":"\#(route)","isExternalRoute":true,"updateRate":250}"#.utf8
        )
        let cborBytes = cborMap([
            (cborText("ioActorId"), try cborUUID(actor)),
            (cborText("ioSourceId"), try cborUUID(source)),
            (cborText("updateRate"), cborInt(250)),
            (cborText("isExternalRoute"), cborTrue),
            (cborText("associatingRoute"), cborText(route)),
        ])

        let jsonValue = try decode(.coaty3JSON, jsonBytes, as: AssociateWireData.self)
        let cborValue = try decode(.axoloty1CBOR, cborBytes, as: AssociateWireData.self)

        #expect(try encode(.coaty3JSON, jsonValue) == jsonBytes)
        #expect(try encode(.axoloty1CBOR, cborValue) == cborBytes)
        // One implementation serves both profiles in both directions.
        #expect(try encode(.axoloty1CBOR, jsonValue) == cborBytes)
        #expect(try encode(.coaty3JSON, cborValue) == jsonBytes)

        #expect(cborValue.ioSourceId == jsonValue.ioSourceId)
        #expect(cborValue.ioActorId == jsonValue.ioActorId)
        #expect(cborValue.isExternalRoute == true)
        #expect(cborValue.updateRate == 250)
        #expect(cborValue.associatingRoute?.ownedBytes() == Array(route.utf8))
    }

    @Test("associate minimal payload omits optional fields on both profiles")
    func associateMinimalParity() throws {
        let jsonBytes = Array(
            #"{"ioSourceId":"33333333-3333-4333-8333-333333333333","ioActorId":"44444444-4444-4444-8444-444444444444"}"#.utf8
        )
        let cborBytes = cborMap([
            (cborText("ioActorId"), try cborUUID("44444444-4444-4444-8444-444444444444")),
            (cborText("ioSourceId"), try cborUUID("33333333-3333-4333-8333-333333333333")),
        ])
        let jsonValue = try decode(.coaty3JSON, jsonBytes, as: AssociateWireData.self)
        let cborValue = try decode(.axoloty1CBOR, cborBytes, as: AssociateWireData.self)
        #expect(try encode(.coaty3JSON, jsonValue) == jsonBytes)
        #expect(try encode(.axoloty1CBOR, cborValue) == cborBytes)
        #expect(cborValue.associatingRoute == nil && cborValue.isExternalRoute == nil && cborValue.updateRate == nil)
    }

    // MARK: - Advertise

    @Test("advertise preserves raw object bytes on both profiles")
    func advertiseParity() throws {
        let objectJSON = #"{"objectType":"example.Thing","objectId":"11111111-1111-4111-8111-111111111111"}"#
        let jsonBytes = Array(#"{"object":\#(objectJSON),"privateData":{"enabled":true}}"#.utf8)
        let objectCBOR = cborMap([
            (cborText("objectId"), try cborUUID("11111111-1111-4111-8111-111111111111")),
            (cborText("objectType"), cborText("example.Thing")),
        ])
        let privateDataCBOR = cborMap([(cborText("enabled"), cborTrue)])
        let cborBytes = cborMap([
            (cborText("object"), objectCBOR),
            (cborText("privateData"), privateDataCBOR),
        ])

        let jsonValue = try decode(.coaty3JSON, jsonBytes, as: AdvertiseWireData.self)
        let cborValue = try decode(.axoloty1CBOR, cborBytes, as: AdvertiseWireData.self)

        #expect(try encode(.coaty3JSON, jsonValue) == jsonBytes)
        #expect(try encode(.axoloty1CBOR, cborValue) == cborBytes)
        #expect(jsonValue.object.asString() == objectJSON)
        #expect(cborValue.object.ownedBytes() == objectCBOR)
        #expect(try #require(cborValue.privateData).ownedBytes() == privateDataCBOR)
        #expect(jsonValue.leaseMS == nil && jsonValue.ownerEpoch == nil)
        #expect(cborValue.leaseMS == nil && cborValue.ownerEpoch == nil)
    }

    @Test("advertise presence fields round trip on both profiles")
    func advertisePresenceParity() throws {
        let objectJSON = #"{"objectType":"example.Thing","objectId":"11111111-1111-4111-8111-111111111111"}"#
        let jsonBytes = Array(
            #"{"object":\#(objectJSON),"leaseMs":10000,"ownerEpoch":7,"privateData":{"enabled":true}}"#.utf8
        )
        let objectCBOR = cborMap([
            (cborText("objectId"), try cborUUID("11111111-1111-4111-8111-111111111111")),
            (cborText("objectType"), cborText("example.Thing")),
        ])
        let privateDataCBOR = cborMap([(cborText("enabled"), cborTrue)])
        let cborBytes = cborMap([
            (cborText("object"), objectCBOR),
            (cborText("leaseMs"), cborInt(10_000)),
            (cborText("ownerEpoch"), cborInt(7)),
            (cborText("privateData"), privateDataCBOR),
        ])

        let jsonValue = try decode(.coaty3JSON, jsonBytes, as: AdvertiseWireData.self)
        let cborValue = try decode(.axoloty1CBOR, cborBytes, as: AdvertiseWireData.self)

        #expect(try encode(.coaty3JSON, jsonValue) == jsonBytes)
        #expect(try encode(.axoloty1CBOR, cborValue) == cborBytes)
        #expect(jsonValue.leaseMS == 10_000 && jsonValue.ownerEpoch == 7)
        #expect(cborValue.leaseMS == 10_000 && cborValue.ownerEpoch == 7)
        #expect(jsonValue.object.asString() == objectJSON)
        #expect(cborValue.object.ownedBytes() == objectCBOR)
    }

    @Test("advertise decodes out-of-policy presence fields without rejecting")
    func advertisePresenceDecodeDoesNotValidate() throws {
        let jsonBytes = Array(#"{"object":{},"leaseMs":0,"ownerEpoch":0}"#.utf8)
        let value = try decode(.coaty3JSON, jsonBytes, as: AdvertiseWireData.self)
        #expect(value.leaseMS == 0 && value.ownerEpoch == 0)

        let cborBytes = cborMap([
            (cborText("object"), cborMap([])),
            (cborText("leaseMs"), cborInt(0)),
            (cborText("ownerEpoch"), cborInt(0)),
        ])
        let cborValue = try decode(.axoloty1CBOR, cborBytes, as: AdvertiseWireData.self)
        #expect(cborValue.leaseMS == 0 && cborValue.ownerEpoch == 0)
    }

    @Test("advertise rejects wrong-typed presence fields on both profiles")
    func advertisePresenceWrongTypes() {
        #expect(throws: WireDecodeError.self) {
            _ = try decode(.coaty3JSON, Array(#"{"object":{},"leaseMs":"10000"}"#.utf8), as: AdvertiseWireData.self)
        }
        #expect(throws: WireDecodeError.self) {
            _ = try decode(.coaty3JSON, Array(#"{"object":{},"leaseMs":10.5}"#.utf8), as: AdvertiseWireData.self)
        }
        #expect(throws: WireDecodeError.self) {
            _ = try decode(.coaty3JSON, Array(#"{"object":{},"ownerEpoch":"7"}"#.utf8), as: AdvertiseWireData.self)
        }
        #expect(throws: WireDecodeError.self) {
            _ = try decode(.coaty3JSON, Array(#"{"object":{},"ownerEpoch":7.5}"#.utf8), as: AdvertiseWireData.self)
        }
        let cborTextMap = cborMap([
            (cborText("object"), cborMap([])),
            (cborText("leaseMs"), cborText("10000")),
        ])
        #expect(throws: WireDecodeError.self) {
            _ = try decode(.axoloty1CBOR, cborTextMap, as: AdvertiseWireData.self)
        }
        let cborEpochTextMap = cborMap([
            (cborText("object"), cborMap([])),
            (cborText("ownerEpoch"), cborText("7")),
        ])
        #expect(throws: WireDecodeError.self) {
            _ = try decode(.axoloty1CBOR, cborEpochTextMap, as: AdvertiseWireData.self)
        }
        let cborFloat: [UInt8] = [0xFA, 0x46, 0x1C, 0x40, 0x00] // 10000.0
        let cborFloatMap = cborMap([
            (cborText("object"), cborMap([])),
            (cborText("leaseMs"), cborFloat),
        ])
        #expect(throws: WireDecodeError.self) {
            _ = try decode(.axoloty1CBOR, cborFloatMap, as: AdvertiseWireData.self)
        }
        let cborEpochFloatMap = cborMap([
            (cborText("object"), cborMap([])),
            (cborText("ownerEpoch"), cborFloat),
        ])
        #expect(throws: WireDecodeError.self) {
            _ = try decode(.axoloty1CBOR, cborEpochFloatMap, as: AdvertiseWireData.self)
        }
    }

    @Test("advertise treats null presence fields as absent and permits a partial pair")
    func advertisePresenceNullAndPartial() throws {
        let jsonNull = Array(#"{"object":{},"leaseMs":null,"ownerEpoch":null}"#.utf8)
        let nullValue = try decode(.coaty3JSON, jsonNull, as: AdvertiseWireData.self)
        #expect(nullValue.leaseMS == nil && nullValue.ownerEpoch == nil)

        let cborNullBytes = cborMap([
            (cborText("object"), cborMap([])),
            (cborText("leaseMs"), cborNull),
            (cborText("ownerEpoch"), cborNull),
        ])
        let cborNullValue = try decode(.axoloty1CBOR, cborNullBytes, as: AdvertiseWireData.self)
        #expect(cborNullValue.leaseMS == nil && cborNullValue.ownerEpoch == nil)

        // The presence policy rejects a partial pair; the DTO still round-trips it.
        let partialJSON = Array(#"{"object":{},"leaseMs":10000}"#.utf8)
        let partial = try decode(.coaty3JSON, partialJSON, as: AdvertiseWireData.self)
        #expect(partial.leaseMS == 10_000 && partial.ownerEpoch == nil)
        #expect(try encode(.coaty3JSON, partial) == partialJSON)

        let partialCBOR = cborMap([
            (cborText("object"), cborMap([])),
            (cborText("leaseMs"), cborInt(10_000)),
        ])
        let partialCBORValue = try decode(.axoloty1CBOR, partialCBOR, as: AdvertiseWireData.self)
        #expect(partialCBORValue.leaseMS == 10_000 && partialCBORValue.ownerEpoch == nil)
        #expect(try encode(.axoloty1CBOR, partialCBORValue) == partialCBOR)

        let singleNullJSON = Array(#"{"object":{},"leaseMs":null,"ownerEpoch":7}"#.utf8)
        let singleNull = try decode(.coaty3JSON, singleNullJSON, as: AdvertiseWireData.self)
        #expect(singleNull.leaseMS == nil && singleNull.ownerEpoch == 7)
    }

    @Test("owned advertise preserves presence fields through the owned event path")
    func advertisePresenceOwnedPath() throws {
        let objectCBOR = cborMap([(cborText("objectType"), cborText("example.Thing"))])
        let cborBytes = cborMap([
            (cborText("object"), objectCBOR),
            (cborText("leaseMs"), cborInt(10_000)),
            (cborText("ownerEpoch"), cborInt(7)),
        ])
        let value = try decode(.axoloty1CBOR, cborBytes, as: AdvertiseWireData.self)
        let owned = try BorrowedWireEvent.advertise(value).owned(profile: .axoloty1CBOR)
        guard case let .advertise(advertise) = owned else {
            Issue.record("expected an owned advertise event")
            return
        }
        #expect(advertise.leaseMS == 10_000)
        #expect(advertise.ownerEpoch == 7)
        #expect(advertise.profile == .axoloty1CBOR)
        var output = [UInt8](repeating: 0, count: cborBytes.count)
        let count = try output.withUnsafeMutableBufferPointer { buffer throws(WireEncodeError) -> Int in
            var writer = WireCodec(profile: .axoloty1CBOR).writer(buffer: buffer.baseAddress!, capacity: buffer.count)
            try owned.encode(to: &writer)
            return writer.position
        }
        #expect(Array(output.prefix(count)) == cborBytes)
    }

    // MARK: - Deadvertise

    @Test("deadvertise round trips and visits UUID elements on both profiles")
    func deadvertiseParity() throws {
        let source = "33333333-3333-4333-8333-333333333333"
        let actor = "44444444-4444-4444-8444-444444444444"
        let jsonBytes = Array(#"{"objectIds":["\#(source)","\#(actor)"]}"#.utf8)
        let cborBytes = cborMap([
            (cborText("objectIds"), cborArray([try cborUUID(source), try cborUUID(actor)])),
        ])

        let jsonValue = try decode(.coaty3JSON, jsonBytes, as: DeadvertiseWireData.self)
        let cborValue = try decode(.axoloty1CBOR, cborBytes, as: DeadvertiseWireData.self)
        #expect(try encode(.coaty3JSON, jsonValue) == jsonBytes)
        #expect(try encode(.axoloty1CBOR, cborValue) == cborBytes)

        // The protocol's deadvertise walk reads UUID elements through the
        // same facade accessor on both profiles.
        let expected = [UUID16(parsing: source)!, UUID16(parsing: actor)!]
        #expect(try collectUUIDElements(.coaty3JSON, jsonBytes) == expected)
        #expect(try collectUUIDElements(.axoloty1CBOR, cborBytes) == expected)
    }

    private func collectUUIDElements(_ profile: WireProfile, _ bytes: [UInt8]) throws -> [UUID16] {
        try bytes.withUnsafeBufferPointer { buffer in
            let reader = WireCodec(profile: profile).reader(
                bytes: buffer.baseAddress!, length: buffer.count
            )
            var visited: [UUID16] = []
            try reader.readUUIDElements("objectIds") { visited.append($0) }
            return visited
        }
    }

    // MARK: - IoValue

    @Test("io value preserves the raw payload on both profiles")
    func ioValueParity() throws {
        let jsonBytes = Array(#"{"payload":[0,1,2,255]}"#.utf8)
        let payloadCBOR = cborArray([cborInt(0), cborInt(1), cborInt(2), cborInt(255)])
        let cborBytes = cborMap([(cborText("payload"), payloadCBOR)])
        let jsonValue = try decode(.coaty3JSON, jsonBytes, as: IoValueWireData.self)
        let cborValue = try decode(.axoloty1CBOR, cborBytes, as: IoValueWireData.self)
        #expect(try encode(.coaty3JSON, jsonValue) == jsonBytes)
        #expect(try encode(.axoloty1CBOR, cborValue) == cborBytes)
        #expect(jsonValue.payload.ownedBytes() == Array(#"[0,1,2,255]"#.utf8))
        #expect(cborValue.payload.ownedBytes() == payloadCBOR)
    }

    // MARK: - Channel

    @Test("channel preserves optional raw fields on both profiles")
    func channelParity() throws {
        let jsonBytes = Array(
            #"{"object":{"objectType":"example.Thing"},"objects":[{"objectType":"example.Other"}],"privateData":{"enabled":true}}"#.utf8
        )
        let cborBytes = cborMap([
            (cborText("object"), cborMap([(cborText("objectType"), cborText("example.Thing"))])),
            (cborText("objects"), cborArray([cborMap([(cborText("objectType"), cborText("example.Other"))])])),
            (cborText("privateData"), cborMap([(cborText("enabled"), cborTrue)])),
        ])
        let jsonValue = try decode(.coaty3JSON, jsonBytes, as: ChannelWireData.self)
        let cborValue = try decode(.axoloty1CBOR, cborBytes, as: ChannelWireData.self)
        #expect(try encode(.coaty3JSON, jsonValue) == jsonBytes)
        #expect(try encode(.axoloty1CBOR, cborValue) == cborBytes)
        #expect(cborValue.object != nil && cborValue.objects != nil && cborValue.privateData != nil)
    }

    // MARK: - Discover

    @Test("discover decodes and encodes both profiles")
    func discoverParity() throws {
        let objectID = "11111111-1111-4111-8111-111111111111"
        let jsonBytes = Array(
            #"{"externalId":"external-1","objectId":"\#(objectID)","objectTypes":["coaty.Sensor"],"coreTypes":["IoSource"]}"#.utf8
        )
        let cborBytes = cborMap([
            (cborText("objectId"), cborText(objectID)),
            (cborText("coreTypes"), cborArray([cborText("IoSource")])),
            (cborText("externalId"), cborText("external-1")),
            (cborText("objectTypes"), cborArray([cborText("coaty.Sensor")])),
        ])
        let jsonValue = try decode(.coaty3JSON, jsonBytes, as: DiscoverWireData.self)
        let cborValue = try decode(.axoloty1CBOR, cborBytes, as: DiscoverWireData.self)
        #expect(try encode(.coaty3JSON, jsonValue) == jsonBytes)
        #expect(try encode(.axoloty1CBOR, cborValue) == cborBytes)
        #expect(cborValue.externalId?.ownedBytes() == Array("external-1".utf8))
        #expect(cborValue.objectId?.ownedBytes() == Array(objectID.utf8))
    }

    // MARK: - Query

    @Test("query preserves raw filter fields on both profiles")
    func queryParity() throws {
        let jsonBytes = Array(
            #"{"objectTypes":["coaty.Sensor"],"coreTypes":["IoSource"],"objectFilter":{"a":1},"objectJoinConditions":[{}]}"#.utf8
        )
        let cborBytes = cborMap([
            (cborText("coreTypes"), cborArray([cborText("IoSource")])),
            (cborText("objectTypes"), cborArray([cborText("coaty.Sensor")])),
            (cborText("objectFilter"), cborMap([(cborText("a"), cborInt(1))])),
            (cborText("objectJoinConditions"), cborArray([cborMap([])])),
        ])
        let jsonValue = try decode(.coaty3JSON, jsonBytes, as: QueryWireData.self)
        let cborValue = try decode(.axoloty1CBOR, cborBytes, as: QueryWireData.self)
        #expect(try encode(.coaty3JSON, jsonValue) == jsonBytes)
        #expect(try encode(.axoloty1CBOR, cborValue) == cborBytes)
        #expect(cborValue.objectFilter != nil && cborValue.objectJoinConditions != nil)
    }

    // MARK: - Call

    @Test("call preserves raw parameters and filter on both profiles")
    func callParity() throws {
        let jsonBytes = Array(#"{"parameters":{"op":1},"filter":["f"]}"#.utf8)
        let cborBytes = cborMap([
            (cborText("filter"), cborArray([cborText("f")])),
            (cborText("parameters"), cborMap([(cborText("op"), cborInt(1))])),
        ])
        let jsonValue = try decode(.coaty3JSON, jsonBytes, as: CallWireData.self)
        let cborValue = try decode(.axoloty1CBOR, cborBytes, as: CallWireData.self)
        #expect(try encode(.coaty3JSON, jsonValue) == jsonBytes)
        #expect(try encode(.axoloty1CBOR, cborValue) == cborBytes)
        #expect(jsonValue.parameters != nil && cborValue.parameters != nil)
    }

    // MARK: - Return

    @Test("return preserves raw result fields on both profiles")
    func returnParity() throws {
        let jsonBytes = Array(#"{"result":{"ok":true},"executionInfo":{"ms":1},"error":{"code":2}}"#.utf8)
        let cborBytes = cborMap([
            (cborText("error"), cborMap([(cborText("code"), cborInt(2))])),
            (cborText("result"), cborMap([(cborText("ok"), cborTrue)])),
            (cborText("executionInfo"), cborMap([(cborText("ms"), cborInt(1))])),
        ])
        let jsonValue = try decode(.coaty3JSON, jsonBytes, as: ReturnWireData.self)
        let cborValue = try decode(.axoloty1CBOR, cborBytes, as: ReturnWireData.self)
        #expect(try encode(.coaty3JSON, jsonValue) == jsonBytes)
        #expect(try encode(.axoloty1CBOR, cborValue) == cborBytes)
        #expect(jsonValue.result != nil && jsonValue.executionInfo != nil && jsonValue.error != nil)
        #expect(cborValue.result != nil && cborValue.executionInfo != nil && cborValue.error != nil)
    }

    // MARK: - Resolve

    @Test("resolve preserves object and related objects on both profiles")
    func resolveParity() throws {
        let jsonBytes = Array(
            #"{"object":{"objectType":"example.Thing"},"relatedObjects":[{"objectType":"example.Other"}],"privateData":{"enabled":true}}"#.utf8
        )
        let cborBytes = cborMap([
            (cborText("object"), cborMap([(cborText("objectType"), cborText("example.Thing"))])),
            (cborText("privateData"), cborMap([(cborText("enabled"), cborTrue)])),
            (cborText("relatedObjects"), cborArray([cborMap([(cborText("objectType"), cborText("example.Other"))])])),
        ])
        let jsonValue = try decode(.coaty3JSON, jsonBytes, as: ResolveWireData.self)
        let cborValue = try decode(.axoloty1CBOR, cborBytes, as: ResolveWireData.self)
        #expect(try encode(.coaty3JSON, jsonValue) == jsonBytes)
        #expect(try encode(.axoloty1CBOR, cborValue) == cborBytes)
        #expect(cborValue.relatedObjects != nil && cborValue.privateData != nil)
    }

    // MARK: - Retrieve

    @Test("retrieve preserves raw objects on both profiles")
    func retrieveParity() throws {
        let jsonBytes = Array(#"{"objects":[{"objectType":"example.Other"}],"privateData":{"enabled":true}}"#.utf8)
        let cborBytes = cborMap([
            (cborText("objects"), cborArray([cborMap([(cborText("objectType"), cborText("example.Other"))])])),
            (cborText("privateData"), cborMap([(cborText("enabled"), cborTrue)])),
        ])
        let jsonValue = try decode(.coaty3JSON, jsonBytes, as: RetrieveWireData.self)
        let cborValue = try decode(.axoloty1CBOR, cborBytes, as: RetrieveWireData.self)
        #expect(try encode(.coaty3JSON, jsonValue) == jsonBytes)
        #expect(try encode(.axoloty1CBOR, cborValue) == cborBytes)
    }

    // MARK: - Update

    @Test("update preserves the raw object on both profiles")
    func updateParity() throws {
        let jsonBytes = Array(#"{"object":{"objectType":"example.Thing"}}"#.utf8)
        let cborBytes = cborMap([
            (cborText("object"), cborMap([(cborText("objectType"), cborText("example.Thing"))])),
        ])
        let jsonValue = try decode(.coaty3JSON, jsonBytes, as: UpdateWireData.self)
        let cborValue = try decode(.axoloty1CBOR, cborBytes, as: UpdateWireData.self)
        #expect(try encode(.coaty3JSON, jsonValue) == jsonBytes)
        #expect(try encode(.axoloty1CBOR, cborValue) == cborBytes)
    }

    // MARK: - Complete

    @Test("complete preserves optional raw fields on both profiles")
    func completeParity() throws {
        let jsonBytes = Array(#"{"object":{"objectType":"example.Thing"},"privateData":{"enabled":true}}"#.utf8)
        let cborBytes = cborMap([
            (cborText("object"), cborMap([(cborText("objectType"), cborText("example.Thing"))])),
            (cborText("privateData"), cborMap([(cborText("enabled"), cborTrue)])),
        ])
        let jsonValue = try decode(.coaty3JSON, jsonBytes, as: CompleteWireData.self)
        let cborValue = try decode(.axoloty1CBOR, cborBytes, as: CompleteWireData.self)
        #expect(try encode(.coaty3JSON, jsonValue) == jsonBytes)
        #expect(try encode(.axoloty1CBOR, cborValue) == cborBytes)
    }

    // MARK: - IoState

    @Test("io state decodes and encodes both profiles")
    func ioStateParity() throws {
        let jsonBytes = Array(#"{"hasAssociations":true,"updateRate":250}"#.utf8)
        let cborBytes = cborMap([
            (cborText("updateRate"), cborInt(250)),
            (cborText("hasAssociations"), cborTrue),
        ])
        let jsonValue = try decode(.coaty3JSON, jsonBytes, as: IoStateWireData.self)
        let cborValue = try decode(.axoloty1CBOR, cborBytes, as: IoStateWireData.self)
        #expect(try encode(.coaty3JSON, jsonValue) == jsonBytes)
        #expect(try encode(.axoloty1CBOR, cborValue) == cborBytes)
        #expect(jsonValue.hasAssociations && jsonValue.updateRate == 250)
        #expect(cborValue.hasAssociations && cborValue.updateRate == 250)
    }

    @Test("io state treats an explicit CBOR null update rate as absent")
    func ioStateNullParity() throws {
        let cborBytes = cborMap([
            (cborText("updateRate"), cborNull),
            (cborText("hasAssociations"), cborFalse),
        ])
        let cborValue = try decode(.axoloty1CBOR, cborBytes, as: IoStateWireData.self)
        #expect(cborValue.hasAssociations == false)
        #expect(cborValue.updateRate == nil)
        #expect(try encode(.axoloty1CBOR, cborValue) == cborMap([
            (cborText("hasAssociations"), cborFalse),
        ]))
    }

    @Test("io state rejects a non-integer CBOR update rate")
    func ioStateRejectsNonIntegerCBORUpdateRate() {
        let cborBytes = cborMap([
            (cborText("updateRate"), cborText("250")),
            (cborText("hasAssociations"), cborTrue),
        ])
        #expect(throws: WireDecodeError.self) {
            _ = try decode(.axoloty1CBOR, cborBytes, as: IoStateWireData.self)
        }
    }

    // MARK: - Rejection parity

    @Test("duplicate top-level keys are rejected on both profiles")
    func duplicateKeysAreRejected() throws {
        let jsonBytes = Array(
            #"{"ioActorId":"44444444-4444-4444-8444-444444444444","ioActorId":"44444444-4444-4444-8444-444444444444"}"#.utf8
        )
        let actor = try cborUUID("44444444-4444-4444-8444-444444444444")
        let cborBytes = cborMap([
            (cborText("ioActorId"), actor),
            (cborText("ioActorId"), actor),
        ])
        #expect(throws: WireDecodeError.self) {
            _ = try decode(.coaty3JSON, jsonBytes, as: AssociateWireData.self)
        }
        #expect(throws: WireDecodeError.self) {
            _ = try decode(.axoloty1CBOR, cborBytes, as: AssociateWireData.self)
        }
    }

    @Test("missing required fields are rejected on both profiles")
    func missingFieldsAreRejected() {
        let jsonBytes = Array(#"{"ioActorId":"44444444-4444-4444-8444-444444444444"}"#.utf8)
        let cborBytes = cborMap([
            (cborText("ioActorId"), [0xD8, 0x25, 0x50] + [UInt8](repeating: 0x44, count: 16)),
        ])
        #expect(throws: WireDecodeError.self) {
            _ = try decode(.coaty3JSON, jsonBytes, as: AssociateWireData.self)
        }
        #expect(throws: WireDecodeError.self) {
            _ = try decode(.axoloty1CBOR, cborBytes, as: AssociateWireData.self)
        }
    }

    @Test("the CBOR engine rejects non-deterministic and malformed maps")
    func cborEngineRejections() throws {
        let actor = try cborUUID("44444444-4444-4444-8444-444444444444")
        // Indefinite-length map.
        let indefinite: [UInt8] = [0x9F] + cborText("ioActorId") + actor + [0xFF]
        // Non-minimal integer: 10 must be 0x0A, not 0x18 0x0A.
        let nonMinimal = cborMap([(cborText("updateRate"), [0x18, 0x0A])])
        // Trailing bytes after the map.
        let trailing = cborMap([(cborText("ioActorId"), actor)]) + [0x00]
        // Non-text map key.
        let integerKey: [UInt8] = [0xA1, 0x01, 0x01]
        // Bare array root instead of a map.
        let arrayRoot = cborArray([cborText("ioActorId")])

        for bytes in [indefinite, nonMinimal, trailing, integerKey, arrayRoot] {
            #expect(throws: WireDecodeError.self) {
                _ = try decode(.axoloty1CBOR, bytes, as: AssociateWireData.self)
            }
        }
    }

    @Test("the CBOR engine rejects malformed UUID values")
    func cborRejectsMalformedUUIDs() {
        // Tag 37 with a 12-byte payload instead of 16.
        let shortUUID: [UInt8] = [0xD8, 0x25, 0x4C] + [UInt8](repeating: 0x33, count: 12)
        let cborBytes = cborMap([(cborText("ioActorId"), shortUUID)])
        #expect(throws: WireDecodeError.self) {
            _ = try decode(.axoloty1CBOR, cborBytes, as: AssociateWireData.self)
        }
    }

    // MARK: - Writer bounds

    @Test("the CBOR writer orders map keys and rejects duplicates")
    func cborWriterOrdersAndRejectsDuplicates() throws {
        var output = [UInt8](repeating: 0, count: 256)
        let actor = try cborUUID("44444444-4444-4444-8444-444444444444")
        try output.withUnsafeMutableBufferPointer { buffer in
            var writer = WireCodec(profile: .axoloty1CBOR).writer(
                buffer: buffer.baseAddress!, capacity: buffer.count
            )
            try writer.beginObject()
            try writer.writeIntField("updateRate", 250)
            try writer.writeUUIDField(
                "ioActorId",
                UUID16(parsing: "44444444-4444-4444-8444-444444444444")!
            )
            try writer.endObject()
            #expect(Array(buffer[0..<writer.position]) == cborMap([
                (cborText("ioActorId"), actor),
                (cborText("updateRate"), cborInt(250)),
            ]))

            // A duplicate key in one facade-built map is rejected.
            var duplicate = WireCodec(profile: .axoloty1CBOR).writer(
                buffer: buffer.baseAddress!, capacity: buffer.count
            )
            try duplicate.beginObject()
            try duplicate.writeIntField("a", 1)
            try duplicate.writeIntField("a", 2)
            #expect(throws: WireEncodeError.invalidValue) { try duplicate.endObject() }
        }
    }

    @Test("the CBOR writer emits the two-byte head for 24 fields")
    func cborWriterTwentyFourFieldHead() throws {
        var output = [UInt8](repeating: 0, count: 512)
        // 24 literal single-letter keys written in reverse: the deterministic
        // key order is a < b < ... < x, so endObject must sort every chunk.
        let expected = cborMap([
            (cborText("a"), cborInt(0)), (cborText("b"), cborInt(1)),
            (cborText("c"), cborInt(2)), (cborText("d"), cborInt(3)),
            (cborText("e"), cborInt(4)), (cborText("f"), cborInt(5)),
            (cborText("g"), cborInt(6)), (cborText("h"), cborInt(7)),
            (cborText("i"), cborInt(8)), (cborText("j"), cborInt(9)),
            (cborText("k"), cborInt(10)), (cborText("l"), cborInt(11)),
            (cborText("m"), cborInt(12)), (cborText("n"), cborInt(13)),
            (cborText("o"), cborInt(14)), (cborText("p"), cborInt(15)),
            (cborText("q"), cborInt(16)), (cborText("r"), cborInt(17)),
            (cborText("s"), cborInt(18)), (cborText("t"), cborInt(19)),
            (cborText("u"), cborInt(20)), (cborText("v"), cborInt(21)),
            (cborText("w"), cborInt(22)), (cborText("x"), cborInt(23)),
        ])
        try output.withUnsafeMutableBufferPointer { buffer in
            var writer = WireCodec(profile: .axoloty1CBOR).writer(
                buffer: buffer.baseAddress!, capacity: buffer.count
            )
            try writer.beginObject()
            try writer.writeIntField("x", 23)
            try writer.writeIntField("w", 22)
            try writer.writeIntField("v", 21)
            try writer.writeIntField("u", 20)
            try writer.writeIntField("t", 19)
            try writer.writeIntField("s", 18)
            try writer.writeIntField("r", 17)
            try writer.writeIntField("q", 16)
            try writer.writeIntField("p", 15)
            try writer.writeIntField("o", 14)
            try writer.writeIntField("n", 13)
            try writer.writeIntField("m", 12)
            try writer.writeIntField("l", 11)
            try writer.writeIntField("k", 10)
            try writer.writeIntField("j", 9)
            try writer.writeIntField("i", 8)
            try writer.writeIntField("h", 7)
            try writer.writeIntField("g", 6)
            try writer.writeIntField("f", 5)
            try writer.writeIntField("e", 4)
            try writer.writeIntField("d", 3)
            try writer.writeIntField("c", 2)
            try writer.writeIntField("b", 1)
            try writer.writeIntField("a", 0)
            try writer.endObject()
            #expect(Array(buffer[0..<writer.position]) == expected)
            #expect(Array(buffer[0..<2]) == [0xB8, 0x18])
        }
    }

    @Test("the CBOR writer bounds facade-built maps at the indexed field limit")
    func cborWriterRejectsOversizedMaps() throws {
        var output = [UInt8](repeating: 0, count: 512)
        try output.withUnsafeMutableBufferPointer { buffer in
            var writer = WireCodec(profile: .axoloty1CBOR).writer(
                buffer: buffer.baseAddress!, capacity: buffer.count
            )
            try writer.beginObject()
            try writer.writeIntField("a", 0)
            try writer.writeIntField("b", 1)
            try writer.writeIntField("c", 2)
            try writer.writeIntField("d", 3)
            try writer.writeIntField("e", 4)
            try writer.writeIntField("f", 5)
            try writer.writeIntField("g", 6)
            try writer.writeIntField("h", 7)
            try writer.writeIntField("i", 8)
            try writer.writeIntField("j", 9)
            try writer.writeIntField("k", 10)
            try writer.writeIntField("l", 11)
            try writer.writeIntField("m", 12)
            try writer.writeIntField("n", 13)
            try writer.writeIntField("o", 14)
            try writer.writeIntField("p", 15)
            try writer.writeIntField("q", 16)
            try writer.writeIntField("r", 17)
            try writer.writeIntField("s", 18)
            try writer.writeIntField("t", 19)
            try writer.writeIntField("u", 20)
            try writer.writeIntField("v", 21)
            try writer.writeIntField("w", 22)
            try writer.writeIntField("x", 23)
            #expect(throws: WireEncodeError.invalidValue) { try writer.writeIntField("y", 24) }
        }
    }

    @Test("the CBOR writer rejects a value without its key inside a map")
    func cborWriterRejectsKeylessValue() throws {
        var output = [UInt8](repeating: 0, count: 64)
        try output.withUnsafeMutableBufferPointer { buffer in
            var writer = WireCodec(profile: .axoloty1CBOR).writer(
                buffer: buffer.baseAddress!, capacity: buffer.count
            )
            try writer.beginObject()
            #expect(throws: WireEncodeError.invalidValue) { try writer.writeInt(1) }
        }
    }

    @Test("the CBOR writer rejects nested facade-built containers")
    func cborWriterRejectsNestedContainers() throws {
        var output = [UInt8](repeating: 0, count: 64)
        try output.withUnsafeMutableBufferPointer { buffer in
            var writer = WireCodec(profile: .axoloty1CBOR).writer(
                buffer: buffer.baseAddress!, capacity: buffer.count
            )
            try writer.beginObject()
            try writer.writeKey("object")
            #expect(throws: WireEncodeError.invalidValue) { try writer.beginObject() }
        }
    }

    @Test("the CBOR writer reports buffer overflow structurally")
    func cborWriterReportsOverflow() throws {
        let cborBytes = cborMap([
            (cborText("object"), cborMap([
                (cborText("objectType"), cborText("example.Thing")),
            ])),
        ])
        let value = try decode(.axoloty1CBOR, cborBytes, as: UpdateWireData.self)
        var output = [UInt8](repeating: 0, count: 8)
        do {
            _ = try output.withUnsafeMutableBufferPointer { buffer -> [UInt8] in
                var writer = WireCodec(profile: .axoloty1CBOR).writer(
                    buffer: buffer.baseAddress!, capacity: buffer.count
                )
                try value.encode(to: &writer)
                return Array(buffer[0..<writer.position])
            }
            Issue.record("undersized CBOR writer accepted an overflowing payload")
        } catch let error as WireEncodeError {
            #expect(error == .bufferOverflow)
        }
    }

    @Test("the CBOR writer validates spliced raw values")
    func cborWriterValidatesRawValues() throws {
        var output = [UInt8](repeating: 0, count: 64)
        let jsonBytes = Array(#"{"objectType":"example.Thing"}"#.utf8)
        try output.withUnsafeMutableBufferPointer { buffer in
            var writer = WireCodec(profile: .axoloty1CBOR).writer(
                buffer: buffer.baseAddress!, capacity: buffer.count
            )
            try writer.beginObject()
            try writer.writeKey("object")
            jsonBytes.withUnsafeBufferPointer { json in
                let slice = ByteSlice(bytes: json.baseAddress!, length: json.count)
                #expect(throws: WireEncodeError.invalidValue) {
                    try writer.writeRawValue(slice)
                }
            }
        }
    }

    @Test("rewind abandons an open CBOR container and restarts cleanly")
    func cborRewindRestartsTransaction() throws {
        var output = [UInt8](repeating: 0, count: 64)
        try output.withUnsafeMutableBufferPointer { buffer in
            var writer = WireCodec(profile: .axoloty1CBOR).writer(
                buffer: buffer.baseAddress!, capacity: buffer.count
            )
            let checkpoint = writer.position
            try writer.beginObject()
            try writer.writeIntField("a", 1)
            // A failed transaction rewinds and restarts from the checkpoint.
            writer.rewind(to: checkpoint)
            try writer.beginObject()
            try writer.writeIntField("b", 2)
            try writer.endObject()
            #expect(Array(buffer[0..<writer.position]) == cborMap([
                (cborText("b"), cborInt(2)),
            ]))
        }
    }

    @Test("the CBOR writer builds bare arrays with patched heads")
    func cborWriterBuildsBareArrays() throws {
        var output = [UInt8](repeating: 0, count: 64)
        try output.withUnsafeMutableBufferPointer { buffer in
            var writer = WireCodec(profile: .axoloty1CBOR).writer(
                buffer: buffer.baseAddress!, capacity: buffer.count
            )
            try writer.beginArray()
            try writer.writeInt(1)
            try writer.writeComma()
            try writer.writeInt(2)
            try writer.endArray()
            #expect(Array(buffer[0..<writer.position]) == cborArray([cborInt(1), cborInt(2)]))
        }
    }
}
