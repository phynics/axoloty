// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@testable import Axoloty
import Foundation
import Testing

/// Decodes real, provenance-bound CoatySwift 2.4.0 captures generated on a
/// macOS host by `Tests/WireCompatibility/Legacy/run_capture_on_macos.sh` and
/// committed under `Tests/WireCompatibility/Fixtures/coatyswift-2.4.0/`.
///
/// Unlike `WireFixtureTests`, which only exercises the harness against a
/// hand-authored `contract-seed` payload, these tests assert that Axoloty
/// decodes the exact bytes an unmodified legacy CoatySwift 2.4.0 process put
/// on the wire, checking the decoded Swift object's semantic fields rather
/// than merely that a payload parses.
struct LegacyCaptureFixtureTests {
    private struct CaptureRecord: Decodable {
        struct MQTT: Decodable {
            let topic: String
            let qos: Int
            let retain: Bool
        }

        struct Payload: Decodable {
            let bytes: String
        }

        let mqtt: MQTT
        let payload: Payload
    }

    private func records(named name: String) throws -> [CaptureRecord] {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "jsonl"))
        let text = try String(contentsOf: url, encoding: .utf8)
        return try text
            .split(separator: "\n")
            .map { try JSONDecoder().decode(CaptureRecord.self, from: Data($0.utf8)) }
    }

    private func decodedPayload(_ record: CaptureRecord) throws -> String {
        let bytes = try #require(Data(base64Encoded: record.payload.bytes))
        return try #require(String(data: bytes, encoding: .utf8))
    }

    @Test
    func legacyAdvertiseCaptureDecodesReferenceObject() throws {
        let captured = try records(named: "advertise")
        let record = try #require(
            captured.first { $0.mqtt.topic.contains("ADV:CoatyObject") },
            "expected the reference-object Advertise publication in the capture"
        )
        #expect((record.mqtt.qos) == 0)
        #expect((record.mqtt.retain) == false)

        let payload = try decodedPayload(record)
        let event: AdvertiseEvent = try PayloadCoder.decode(payload)
        #expect((event.data.object.coreType) == .CoatyObject)
        #expect((event.data.object.objectType) == "org.axoloty.wire.ReferenceObject")
        #expect((event.data.object.objectId.string) == "00000000-0000-4000-8000-000000000101")
        #expect((event.data.object.name) == "wire-compat-reference")
    }

    @Test
    func legacyDeadvertiseCaptureDecodesReferenceObjectId() throws {
        let captured = try records(named: "deadvertise")
        let record = try #require(
            captured.first { $0.mqtt.topic.contains("/DAD/") },
            "expected a Deadvertise publication in the capture"
        )
        #expect((record.mqtt.qos) == 0)
        #expect((record.mqtt.retain) == false)

        let payload = try decodedPayload(record)
        let event: DeadvertiseEvent = try PayloadCoder.decode(payload)
        #expect((event.data.objectIds.map(\.string)) == ["00000000-0000-4000-8000-000000000101"])
    }

    @Test
    func legacyDiscoverResolveCaptureDecodesResolvedObjectAndCorrelatesRequest() throws {
        let captured = try records(named: "discover-resolve")
        let discover = try #require(
            captured.first { $0.mqtt.topic.contains("/DSC/") },
            "expected a Discover publication in the capture"
        )
        let resolve = try #require(
            captured.first { $0.mqtt.topic.contains("/RSV/") },
            "expected a Resolve publication in the capture"
        )

        // Coaty correlates Discover/Resolve pairs via the request's UUID
        // (the trailing topic segment) rather than any payload field, so the
        // Resolve's decoded semantics only count as compatible if it also
        // answers this exact Discover request.
        let discoverCorrelationId = try #require(discover.mqtt.topic.split(separator: "/").last)
        let resolveCorrelationId = try #require(resolve.mqtt.topic.split(separator: "/").last)
        #expect(resolveCorrelationId == discoverCorrelationId)

        let discoverPayload = try decodedPayload(discover)
        let discoverEvent: DiscoverEvent = try PayloadCoder.decode(discoverPayload)
        #expect((discoverEvent.data.objectTypes) == ["org.axoloty.wire.ReferenceObject"])

        let resolvePayload = try decodedPayload(resolve)
        let resolveEvent: ResolveEvent = try PayloadCoder.decode(resolvePayload)
        let object = try #require(resolveEvent.data.object)
        #expect((object.coreType) == .CoatyObject)
        #expect((object.objectType) == "org.axoloty.wire.ReferenceObject")
        #expect((object.objectId.string) == "00000000-0000-4000-8000-000000000101")
        #expect((object.name) == "wire-compat-reference")
    }
}
