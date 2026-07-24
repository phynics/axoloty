// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@testable import Axoloty
import Foundation
import Testing

/// Offline wire-format evidence for T-021 scenario 2 (IoValue raw payloads).
///
/// These are deterministic round-trip tests for raw byte payloads through
/// `IoValueEventData` encode/decode, without a live broker. The raw-byte
/// publish path in `CM+Publish.publishIoValue` is the production consumer.
///
/// JSON payload encoding is covered by
/// `AxolotyIoAssociateTests.ioValueJsonPayloadEncodesAsBareValue` and
/// `RawJSONValue.serialize(any:)` tests.
@MainActor
struct AxolotyIoValuePayloadTests {

    /// An empty raw payload round-trips correctly.
    @Test
    func rawEmptyPayloadRoundTrips() throws {
        let sourceId = try #require(CoatyUUID(uuidString: "33333333-3333-4333-8333-333333333333"))
        let source = IoSource(
            valueType: "com.coaty.test.WireIoValue",
            useRawIoValues: true,
            name: "wire-compat-io-source-1",
            objectId: sourceId
        )
        let event = try IoValueEvent.with(ioSource: source, value: [UInt8](), options: [:])
        let data: IoValueEventData = try PayloadCoder.decode(event.json)

        #expect(data.rawPayload == [])
    }

    /// A scalar raw payload round-trips correctly.
    @Test
    func rawScalarPayloadRoundTrips() throws {
        let sourceId = try #require(CoatyUUID(uuidString: "33333333-3333-4333-8333-333333333333"))
        let source = IoSource(
            valueType: "com.coaty.test.WireIoValue",
            useRawIoValues: true,
            name: "wire-compat-io-source-1",
            objectId: sourceId
        )
        let payload: [UInt8] = [0x01, 0x02, 0x03, 0xFF]
        let event = try IoValueEvent.with(ioSource: source, value: payload, options: [:])
        let data: IoValueEventData = try PayloadCoder.decode(event.json)

        #expect(data.rawPayload == payload)
    }

    /// A NUL-containing raw payload round-trips correctly (embedded null byte).
    @Test
    func rawNulContainingPayloadRoundTrips() throws {
        let sourceId = try #require(CoatyUUID(uuidString: "33333333-3333-4333-8333-333333333333"))
        let source = IoSource(
            valueType: "com.coaty.test.WireIoValue",
            useRawIoValues: true,
            name: "wire-compat-io-source-1",
            objectId: sourceId
        )
        let payload: [UInt8] = [0x00, 0x41, 0x00, 0x42, 0x00]
        let event = try IoValueEvent.with(ioSource: source, value: payload, options: [:])
        let data: IoValueEventData = try PayloadCoder.decode(event.json)

        #expect(data.rawPayload == payload)
    }

    /// An invalid-UTF8 raw payload round-trips correctly (bytes that cannot
    /// decode as UTF-8 are preserved in the raw path, not coerced).
    @Test
    func rawInvalidUtf8PayloadRoundTrips() throws {
        let sourceId = try #require(CoatyUUID(uuidString: "33333333-3333-4333-8333-333333333333"))
        let source = IoSource(
            valueType: "com.coaty.test.WireIoValue",
            useRawIoValues: true,
            name: "wire-compat-io-source-1",
            objectId: sourceId
        )
        let payload: [UInt8] = [0xFF, 0xFE, 0x80, 0x00]
        let event = try IoValueEvent.with(ioSource: source, value: payload, options: [:])
        let data: IoValueEventData = try PayloadCoder.decode(event.json)

        #expect(data.rawPayload == payload)
    }
}
