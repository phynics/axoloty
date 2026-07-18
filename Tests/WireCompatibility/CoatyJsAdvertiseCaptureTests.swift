// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@testable import Axoloty
import Foundation
import Testing

/// Verifies the semantic and topic contract of a pinned CoatyJS 2.4.0
/// Advertise run, ported from `Tests/WireCompatibility/Live/verify-coatyjs-advertise.py`.
///
/// The capture is committed under
/// `Tests/WireCompatibility/Fixtures/coatyjs-2.4.0/coatyjs-advertise.jsonl`
/// (regenerated from a live `run-coatyjs-advertise.sh` run and pinned, so the
/// contract is asserted deterministically at PR tier rather than only after a
/// live run).
/// Mirrors `LegacyCaptureFixtureTests`, which decodes committed CoatySwift
/// captures the same way.
struct CoatyJsAdvertiseCaptureTests {
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

    private let expectedObjectId = "11111111-1111-4111-8111-111111111111"
    private let expectedObjectType = "com.coaty.test.WireFixture"
    private let expectedName = "wire-fixture"

    private func records(named name: String) throws -> [CaptureRecord] {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "jsonl"))
        let text = try String(contentsOf: url, encoding: .utf8)
        return try text
            .split(separator: "\n")
            .map { try JSONDecoder().decode(CaptureRecord.self, from: Data($0.utf8)) }
    }

    private func decodedAdvertiseEvent(_ record: CaptureRecord) throws -> AdvertiseEvent {
        let bytes = try #require(Data(base64Encoded: record.payload.bytes))
        let payload = try #require(String(data: bytes, encoding: .utf8))
        return try PayloadCoder.decode(payload)
    }

    @Test
    func coatyJsAdvertiseCaptureCarriesTheFixtureObjectOnBothTopicVariants() throws {
        let captured = try records(named: "coatyjs-advertise")
        let matching = captured.filter { record in
            guard let event = try? decodedAdvertiseEvent(record) else { return false }
            let object = event.data.object
            return object.objectId.string == expectedObjectId
                && object.objectType == expectedObjectType
                && object.name == expectedName
        }
        #expect(matching.count >= 2, "expected the deterministic fixture object on at least the two Advertise topic variants")

        let topics = Set(matching.map(\.mqtt.topic))
        #expect(topics.contains { $0.hasPrefix("coaty/3/wire-compat-v1/ADV:CoatyObject/") },
                "missing the coreType-level Advertise topic; got \(sorted(topics))")
        #expect(topics.contains { $0.hasPrefix("coaty/3/wire-compat-v1/ADV::com.coaty.test.WireFixture/") },
                "missing the objectType-level Advertise topic; got \(sorted(topics))")
    }

    @Test
    func coatyJsAdvertiseCaptureUsesQosZeroAndNoRetain() throws {
        let captured = try records(named: "coatyjs-advertise")
        let advertises = captured.filter { $0.mqtt.topic.contains("/ADV") }
        #expect(advertises.isEmpty == false, "expected at least one Advertise publication")
        for record in advertises {
            #expect(record.mqtt.qos == 0, "CoatyJS 2.4.0 hardcodes QoS 0; got \(record.mqtt.qos) on \(record.mqtt.topic)")
            #expect(record.mqtt.retain == false, "Advertise must not set RETAIN; got retain=true on \(record.mqtt.topic)")
        }
    }

    private func sorted(_ topics: Set<String>) -> [String] {
        topics.sorted()
    }
}
