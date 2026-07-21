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
}
