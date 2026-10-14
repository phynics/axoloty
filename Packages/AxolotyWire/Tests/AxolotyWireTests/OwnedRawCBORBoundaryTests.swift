// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyWire
import Testing

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
        return [0x1B] + (0...7).map { UInt8((unsigned >> UInt64(56 - 8 * $0)) & 0xFF) }
    }
    let magnitude = UInt64(-Int64(value) - 1)
    if magnitude < 24 { return [0x20 | UInt8(magnitude)] }
    if magnitude <= 0xFF { return [0x38, UInt8(magnitude)] }
    return [0x3B] + (0...7).map { UInt8((magnitude >> UInt64(56 - 8 * $0)) & 0xFF) }
}

private func cborArray(_ items: [[UInt8]]) -> [UInt8] {
    let head: [UInt8] = items.count < 24 ? [0x80 | UInt8(items.count)] : [0x98, UInt8(items.count)]
    return items.reduce(head) { $0 + $1 }
}

/// Emits one CBOR map. The pairs must already be in deterministic key order
/// (length first, then bytewise).
private func cborMap(_ pairs: [([UInt8], [UInt8])]) -> [UInt8] {
    let head: [UInt8] = pairs.count < 24 ? [0xA0 | UInt8(pairs.count)] : [0xB8, UInt8(pairs.count)]
    return pairs.reduce(head) { $0 + $1.0 + $1.1 }
}

private func encodeCBOR(_ event: OwnedWireEvent, capacity: Int = 512) throws(WireEncodeError) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: capacity)
    let count = try bytes.withUnsafeMutableBufferPointer { (buffer) throws(WireEncodeError) in
        var writer = WireCodec(profile: .axoloty1CBOR).writer(
            buffer: buffer.baseAddress!, capacity: buffer.count
        )
        try event.encode(to: &writer)
        return writer.position
    }
    return Array(bytes[..<count])
}

private func encodeJSON(_ event: OwnedWireEvent, capacity: Int = 512) throws(WireEncodeError) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: capacity)
    let count = try bytes.withUnsafeMutableBufferPointer { (buffer) throws(WireEncodeError) in
        var writer = WireWriter(buffer: buffer.baseAddress!, capacity: buffer.count)
        try event.encode(to: &writer)
        return writer.position
    }
    return Array(bytes[..<count])
}

@Suite("Owned raw CBOR boundary")
struct OwnedRawCBORBoundaryTests {
    @Test("a CBOR object survives an owned event round trip byte-for-byte")
    func retainsCBORObjectThroughOwnedRoundTrip() throws {
        let object = cborMap([(cborText("value"), cborInt(1))])
        let fields = try OwnedUpdateWireData(profile: .axoloty1CBOR, object: object)
        #expect(fields.profile == .axoloty1CBOR)
        #expect(fields.object == object)

        let encoded = try encodeCBOR(.update(fields))
        #expect(encoded == cborMap([(cborText("object"), object)]))
    }

    @Test("CBOR-only value forms are retained verbatim")
    func retainsCBOROnlyValueForms() throws {
        // A byte string has no JSON equivalent.
        let byteString: [UInt8] = [0x43, 0x01, 0x02, 0x03]
        let byteFields = try OwnedIoValueWireData(profile: .axoloty1CBOR, payload: byteString)
        let byteEncoded = try encodeCBOR(.ioValue(byteFields))
        #expect(byteEncoded == cborMap([(cborText("payload"), byteString)]))

        // NaN and negative zero are legal CBOR floats but illegal JSON numbers.
        let floatCases: [[UInt8]] = [[0xF9, 0x7E, 0x00], [0xF9, 0x80, 0x00]]
        for float in floatCases {
            let fields = try OwnedIoValueWireData(profile: .axoloty1CBOR, payload: float)
            let encoded = try encodeCBOR(.ioValue(fields))
            #expect(encoded == cborMap([(cborText("payload"), float)]))
        }
    }

    @Test("CBOR big integers outside the allow-list are rejected")
    func rejectsCBORBigIntegers() {
        do {
            // Tag 2 (positive bignum) is not in the axoloty/1 tag allow-list.
            _ = try OwnedIoValueWireData(profile: .axoloty1CBOR, payload: [0xC2, 0x41, 0x01])
            Issue.record("a big integer was accepted")
        } catch {
            guard case .cborUnsupportedTag = error.reason else {
                Issue.record("unexpected error reason: \(error.reason)")
                return
            }
        }
    }

    @Test("CBOR raw fields must satisfy their required shape")
    func enforcesCBORShape() throws {
        do {
            _ = try OwnedUpdateWireData(profile: .axoloty1CBOR, object: cborArray([cborInt(1)]))
            Issue.record("an array was accepted for an object field")
        } catch {
            guard case .typeMismatch(let expected) = error.reason, "\(expected)" == "object" else {
                Issue.record("unexpected error reason: \(error.reason)")
                return
            }
        }

        do {
            _ = try OwnedDeadvertiseWireData(
                profile: .axoloty1CBOR,
                objectIds: cborMap([(cborText("a"), cborInt(1))])
            )
            Issue.record("a map was accepted for an array field")
        } catch {
            guard case .typeMismatch(let expected) = error.reason, "\(expected)" == "array" else {
                Issue.record("unexpected error reason: \(error.reason)")
                return
            }
        }

        let ids = cborArray([try cborUUID("33333333-3333-4333-8333-333333333333")])
        let fields = try OwnedDeadvertiseWireData(profile: .axoloty1CBOR, objectIds: ids)
        let encoded = try encodeCBOR(.deadvertise(fields))
        #expect(encoded == cborMap([(cborText("objectIds"), ids)]))
    }

    @Test("raw CBOR keeps a peer's map key order; sorting is a writer rule")
    func retainsOutOfOrderMapKeys() throws {
        // The profile writer sorts map keys, but the reader does not require
        // ascending encoded-key order. A retained raw field therefore keeps a
        // non-conforming peer's key order unchanged instead of rejecting or
        // rewriting it. This locks the reader tolerance that
        // `docs/wire-value-mapping.md` records.
        let outOfOrder = cborMap([
            (cborText("b"), cborInt(2)),
            (cborText("a"), cborInt(1)),
        ])
        let fields = try OwnedUpdateWireData(profile: .axoloty1CBOR, object: outOfOrder)
        #expect(fields.object == outOfOrder)
        #expect(try encodeCBOR(.update(fields)) == cborMap([(cborText("object"), outOfOrder)]))
    }

    @Test("malformed or non-deterministic CBOR is rejected")
    func rejectsMalformedCBOR() {
        let malformed: [[UInt8]] = [
            [0x18, 0x0A],                 // non-minimal integer
            cborInt(1) + [0x00],          // trailing bytes after one item
            [0x9F, 0xFF],                 // indefinite-length array
            [],                           // empty field
        ]
        for bytes in malformed {
            #expect(throws: WireDecodeError.self) {
                _ = try OwnedIoValueWireData(profile: .axoloty1CBOR, payload: bytes)
            }
        }
    }

    @Test("CBOR string content is UTF-8 validated, not recoded")
    func validatesCBORTextContent() throws {
        let route = Array("coaty/3/fuzz/IOV/33333333-3333-4333-8333-333333333333".utf8)
        let fields = try OwnedAssociateWireData(
            profile: .axoloty1CBOR,
            ioSourceId: UUID16(parsing: "33333333-3333-4333-8333-333333333333")!,
            ioActorId: UUID16(parsing: "44444444-4444-4444-8444-444444444444")!,
            associatingRoute: route,
            isExternalRoute: nil,
            updateRate: nil
        )
        #expect(fields.associatingRoute == route)
        #expect(fields.profile == .axoloty1CBOR)

        do {
            _ = try OwnedAssociateWireData(
                profile: .axoloty1CBOR,
                ioSourceId: UUID16(parsing: "33333333-3333-4333-8333-333333333333")!,
                ioActorId: UUID16(parsing: "44444444-4444-4444-8444-444444444444")!,
                associatingRoute: [0xFF, 0xFE],
                isExternalRoute: nil,
                updateRate: nil
            )
            Issue.record("invalid UTF-8 route content was accepted")
        } catch {
            guard case .invalidUTF8 = error.reason else {
                Issue.record("unexpected error reason: \(error.reason)")
                return
            }
        }
    }

    @Test("empty string content is retained for both profiles")
    func retainsEmptyTextContent() throws {
        let source = "33333333-3333-4333-8333-333333333333"
        let actor = "44444444-4444-4444-8444-444444444444"
        let cbor = try OwnedAssociateWireData(
            profile: .axoloty1CBOR,
            ioSourceId: UUID16(parsing: source)!,
            ioActorId: UUID16(parsing: actor)!,
            associatingRoute: [],
            isExternalRoute: nil,
            updateRate: nil
        )
        #expect(cbor.profile == .axoloty1CBOR)
        #expect(cbor.associatingRoute == [])
        #expect(
            try encodeCBOR(.associate(cbor)) == cborMap([
                (cborText("ioActorId"), try cborUUID(actor)),
                (cborText("ioSourceId"), try cborUUID(source)),
                (cborText("associatingRoute"), [0x60]),
            ])
        )

        let json = try OwnedAssociateWireData(
            ioSourceId: UUID16(parsing: source)!,
            ioActorId: UUID16(parsing: actor)!,
            associatingRoute: [],
            isExternalRoute: nil,
            updateRate: nil
        )
        #expect(json.profile == .coaty3JSON)
        #expect(json.associatingRoute == [])
        #expect(
            try encodeJSON(.associate(json)) == Array(
                #"{"ioSourceId":"33333333-3333-4333-8333-333333333333","ioActorId":"44444444-4444-4444-8444-444444444444","associatingRoute":""}"#.utf8
            )
        )
    }

    @Test("encoding across profiles is rejected as a lossy transcode")
    func rejectsCrossProfileEncoding() throws {
        let jsonObject = Array(#"{"value":1}"#.utf8)
        let jsonOwned = try OwnedUpdateWireData(object: jsonObject)
        #expect(throws: WireEncodeError.profileMismatch) {
            _ = try encodeCBOR(.update(jsonOwned))
        }

        let cborOwned = try OwnedUpdateWireData(
            profile: .axoloty1CBOR,
            object: cborMap([(cborText("value"), cborInt(1))])
        )
        #expect(throws: WireEncodeError.profileMismatch) {
            _ = try encodeJSON(.update(cborOwned))
        }
    }

    @Test("the default owned profile keeps the sealed coaty/3 JSON contract")
    func defaultOwnedProfileIsJSON() throws {
        let fields = try OwnedUpdateWireData(object: Array(#"{"value":1}"#.utf8))
        #expect(fields.profile == .coaty3JSON)
        let encoded = try encodeJSON(.update(fields))
        #expect(encoded == Array(#"{"object":{"value":1}}"#.utf8))
    }

    @Test("a borrowed CBOR message owns its raw slices in the route profile")
    func borrowedCBORMessageOwnsInRouteProfile() throws {
        let topic = Array("axoloty/1/ns/ASC/55555555-5555-4555-8555-555555555555".utf8)
        let source = "33333333-3333-4333-8333-333333333333"
        let actor = "44444444-4444-4444-8444-444444444444"
        let payload = cborMap([
            (cborText("ioActorId"), try cborUUID(actor)),
            (cborText("ioSourceId"), try cborUUID(source)),
        ])

        let owned = try #require(
            topic.withUnsafeBufferPointer { topicBuffer -> OwnedWireEvent? in
                payload.withUnsafeBufferPointer { payloadBuffer -> OwnedWireEvent? in
                    guard let topicBase = topicBuffer.baseAddress,
                          let payloadBase = payloadBuffer.baseAddress else {
                        Issue.record("missing buffer base address")
                        return nil
                    }
                    do {
                        let message = try BorrowedMessage.validated(
                            topicBytes: topicBase,
                            topicLength: topicBuffer.count,
                            payloadBytes: payloadBase,
                            payloadLength: payloadBuffer.count
                        )
                        #expect(message.profile == WireProfile.axoloty1CBOR)
                        return try message.ownedEvent()
                    } catch {
                        Issue.record("unexpected error: \(error)")
                        return nil
                    }
                }
            }
        )

        #expect(owned.profile == WireProfile.axoloty1CBOR)
        let encoded = try encodeCBOR(owned)
        #expect(encoded == payload)
    }
}
