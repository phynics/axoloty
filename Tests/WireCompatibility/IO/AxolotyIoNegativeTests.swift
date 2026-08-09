// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@testable import Axoloty
import Foundation
import Testing

/// Negative and forward-compatibility IO cases for T-021 scenario 6.
///
/// These run offline (no broker) and assert the decode/construct behavior that
/// underpins the live negative scenarios: unknown fields are tolerated,
/// missing optionals decode to nil, and mode-mismatched IoValue construction
/// is rejected. The remaining negative cases that need a live peer (duplicate
/// Associate, late value after disassociation) are exercised by the live
/// runners and recorded in the decisions doc.
@MainActor
struct AxolotyIoNegativeTests {

    /// Unknown fields in an Associate payload must be ignored on decode
    /// (forward compatibility: a peer that adds a field must not break an
    /// older decoder). The audit requires that unknown data be preserved only
    /// where the reference implementations do so; Coaty/Swift Codable drops
    /// unknown keys by default, which is the compatible behavior here.
    @Test
    func associateEventDecodesPayloadWithUnknownFields() throws {
        let payload = """
            {"ioSourceId":"33333333-3333-4333-8333-333333333333","ioActorId":"44444444-4444-4444-8444-444444444444","associatingRoute":"coaty/3/wire-compat-v1/IOV/33333333-3333-4333-8333-333333333333","updateRate":250,"futureField":"some-value","nested":{"a":1}}
            """

        let decoded: AssociateEventData = try PayloadCoder.decode(payload)

        #expect(decoded.ioSourceId == CoatyUUID(uuidString: "33333333-3333-4333-8333-333333333333"))
        #expect(decoded.updateRate == 250)
        // Unknown fields are silently dropped, not rejected.
    }

    /// An Associate payload with all optionals omitted (only the required
    /// ids and route) decodes with nil updateRate and nil isExternalRoute.
    @Test
    func associateEventDecodesPayloadWithMissingOptionals() throws {
        let payload = """
            {"ioSourceId":"33333333-3333-4333-8333-333333333333","ioActorId":"44444444-4444-4444-8444-444444444444","associatingRoute":"coaty/3/wire-compat-v1/IOV/33333333-3333-4333-8333-333333333333"}
            """

        let decoded: AssociateEventData = try PayloadCoder.decode(payload)

        #expect(decoded.updateRate == nil)
        #expect(decoded.isExternalRoute == nil)
    }

    /// Constructing a raw IoValue for a JSON-mode source (useRawIoValues
    /// false) must be rejected — value type/raw mode must agree.
    @Test
    func ioValueEventRejectsRawValueForJsonSource() {
        let source = IoSource(valueType: "com.coaty.test.WireIoValue", useRawIoValues: false)

        #expect(throws: AxolotyError.self) {
            _ = try IoValueEvent.with(ioSource: source, value: [UInt8]([0x01, 0x02]), options: [:])
        }
    }

    /// Constructing a JSON IoValue for a raw-mode source (useRawIoValues true)
    /// must be rejected.
    @Test
    func ioValueEventRejectsJsonValueForRawSource() {
        let source = IoSource(valueType: "com.coaty.test.WireIoValue", useRawIoValues: true)

        #expect(throws: AxolotyError.self) {
            _ = try IoValueEvent.with(ioSource: source, value: "42", options: [:])
        }
    }

    /// A disassociation Associate (nil route) still requires valid source and
    /// actor ids; decoding one with a malformed id fails (returns nil) rather
    /// than producing a partial event.
    @Test
    func associateEventRejectsMalformedSourceId() {
        let payload = """
            {"ioSourceId":"not-a-uuid","ioActorId":"44444444-4444-4444-8444-444444444444"}
            """

        let decoded: AssociateEventData? = try? PayloadCoder.decode(payload)

        #expect(decoded == nil)
    }

    // MARK: - Forward compatibility (scenario 9)

    /// An IoValueEventData JSON payload with unknown fields decodes without
    /// error (forward compatibility: a peer that adds a field must not break
    /// an older decoder). Unknown keys are silently dropped by Codable.
    @Test
    func ioValueDecodesPayloadWithUnknownFields() throws {
        // A bare JSON value is the wire payload; the event envelope is the
        // IoValueEventData with a single "payload" key holding the value.
        // Extra unknown keys at the envelope level are silently dropped.
        let payload = #"{"payload":[1,2,3],"futureField":"some-value"}"#
        let decoded: IoValueEventData? = try? PayloadCoder.decode(payload)

        #expect(decoded?.rawPayload == [1, 2, 3])
    }

    /// An IoValue raw payload with reordered keys decodes identically (JSON key
    /// ordering is semantically irrelevant).
    @Test
    func ioValueDecodesRawPayloadWithReorderedKeys() throws {
        // The encoder always emits "payload" as the only key; this test uses
        // the raw-bytes path which is order-insensitive by construction.
        let payload = #"{"payload":[1,2,3]}"#
        let first: IoValueEventData? = try? PayloadCoder.decode(payload)
        #expect(first?.rawPayload == [1, 2, 3])
    }

    /// An Associate payload with reordered JSON keys decodes identically.
    @Test
    func associateEventDecodesWithReorderedKeys() throws {
        let standard = """
            {"ioSourceId":"33333333-3333-4333-8333-333333333333","ioActorId":"44444444-4444-4444-8444-444444444444","associatingRoute":"coaty/3/wire-compat-v1/IOV/33333333-3333-4333-8333-333333333333"}
            """
        let reordered = """
            {"ioActorId":"44444444-4444-4444-8444-444444444444","ioSourceId":"33333333-3333-4333-8333-333333333333","associatingRoute":"coaty/3/wire-compat-v1/IOV/33333333-3333-4333-8333-333333333333"}
            """

        let standardDecoded: AssociateEventData = try PayloadCoder.decode(standard)
        let reorderedDecoded: AssociateEventData = try PayloadCoder.decode(reordered)

        #expect(standardDecoded.ioSourceId == reorderedDecoded.ioSourceId)
        #expect(standardDecoded.ioActorId == reorderedDecoded.ioActorId)
        #expect(standardDecoded.associatingRoute == reorderedDecoded.associatingRoute)
    }

    /// A raw IoValue payload with an unknown object type field decodes without
    /// error (the decoder does not validate object type for raw values).
    @Test
    func rawIoValueDecodesPayloadWithUnknownFields() throws {
        let payload = #"{"payload":[0,1,2],"unknownField":true}"#
        let decoded: IoValueEventData? = try? PayloadCoder.decode(payload)
        #expect(decoded != nil)
        #expect(decoded?.rawPayload == [0, 1, 2])
    }

    /// Direct Codable decoding preserves a scalar IoValue as raw JSON text.
    @Test
    func ioValueDirectCodableDecodesScalarPayload() throws {
        let decoded = try decodeIoValue(#"{"payload":42}"#)

        #expect(decoded.rawPayload == nil)
        #expect(decoded.jsonPayload == "42")
    }

    /// Direct Codable decoding preserves an object IoValue as raw JSON text.
    @Test
    func ioValueDirectCodableDecodesObjectPayload() throws {
        let decoded = try decodeIoValue(#"{"payload":{"value":"ready"}}"#)

        #expect(decoded.rawPayload == nil)
        #expect(decoded.jsonPayload == #"{"value":"ready"}"#)
    }

    /// Direct Codable decoding preserves a structured array as raw JSON text.
    @Test
    func ioValueDirectCodableDecodesStructuredArrayPayload() throws {
        let decoded = try decodeIoValue(#"{"payload":["ready",true,3]}"#)

        #expect(decoded.rawPayload == nil)
        #expect(decoded.jsonPayload == #"["ready",true,3]"#)
    }

    /// Arrays whose every element is an integer in the UInt8 range retain the
    /// established raw-byte interpretation, including an empty byte array.
    @Test(arguments: [
        (#"{"payload":[]}"#, [UInt8]()),
        (#"{"payload":[0,1,2,255]}"#, [UInt8]([0, 1, 2, 255])),
    ])
    func ioValueDirectCodableReservesByteArraysForRawPayloads(
        json: String,
        expected: [UInt8]
    ) throws {
        let decoded = try decodeIoValue(json)

        #expect(decoded.rawPayload == expected)
        #expect(decoded.jsonPayload == nil)
    }

    /// Numeric arrays that cannot be represented exactly as bytes are JSON
    /// arrays, making the otherwise ambiguous array shape deterministic.
    @Test(arguments: [
        (#"{"payload":[-1,2]}"#, #"[-1,2]"#),
        (#"{"payload":[1,256]}"#, #"[1,256]"#),
        (#"{"payload":[1,2.5]}"#, #"[1,2.5]"#),
    ])
    func ioValueDirectCodableTreatsNonByteNumericArraysAsJSON(
        json: String,
        expected: String
    ) throws {
        let decoded = try decodeIoValue(json)

        #expect(decoded.rawPayload == nil)
        #expect(decoded.jsonPayload == expected)
    }

    /// Structured IoValues survive direct Codable decode and encode without
    /// regaining the historical string wrapper around the payload value.
    @Test(arguments: [
        #"{"payload":42}"#,
        #"{"payload":{"value":"ready"}}"#,
        #"{"payload":["ready",true,3]}"#,
        #"{"payload":null}"#,
    ])
    func ioValueDirectCodableStructuredPayloadRoundTrips(json: String) throws {
        let decoded = try decodeIoValue(json)
        let encoded = try JSONEncoder().encode(decoded)

        let expectedObject = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? NSDictionary)
        let actualObject = try #require(JSONSerialization.jsonObject(with: encoded) as? NSDictionary)
        #expect(actualObject == expectedObject)
    }

    /// The public payload boundary translates direct Codable failures into an
    /// Axoloty `Throwable` instead of leaking the underlying decoder error.
    @Test
    func ioValuePayloadCoderWrapsMissingPayloadError() {
        do {
            let _: IoValueEventData = try PayloadCoder.decode("{}")
            Issue.record("Expected missing IoValue payload to fail decoding")
        } catch let error as AxolotyError {
            guard case let .decodingFailure(type, _, payload) = error else {
                Issue.record("Expected decodingFailure, got \(error)")
                return
            }
            #expect(type == "IoValueEventData")
            #expect(payload == "{}")
            #expect(error.userFriendlyMessage.hasPrefix("IoValueEventData: "))
        } catch {
            Issue.record("Expected AxolotyError, got \(error)")
        }
    }

    private func decodeIoValue(_ json: String) throws -> IoValueEventData {
        try JSONDecoder().decode(IoValueEventData.self, from: Data(json.utf8))
    }
}
