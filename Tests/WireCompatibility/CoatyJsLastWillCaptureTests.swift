// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@testable import Axoloty
import Foundation
import Testing

/// Verifies the semantic and topic contract of a pinned CoatyJS 2.4.0
/// broker-issued last will exchange, ported from
/// `Tests/WireCompatibility/Lifecycle/Live/verify-coatyjs-last-will.py`.
///
/// The capture spans a CoatyJS subject that advertises its Identity and is
/// then killed with SIGKILL — no clean Deadvertise — so the Deadvertise seen
/// afterward can only be the broker's MQTT last will firing on unexpected
/// disconnect. The capture is committed under
/// `Tests/WireCompatibility/Fixtures/coatyjs-2.4.0/coatyjs-last-will.jsonl`.
struct CoatyJsLastWillCaptureTests {
    private struct CaptureRecord: Decodable {
        struct MQTT: Decodable {
            let topic: String
            let qos: Int
            let retain: Bool
        }

        struct Payload: Decodable {
            let bytes: String
        }

        let sequence: Int
        let mqtt: MQTT
        let payload: Payload
    }

    private let identityId = "33333333-3333-4333-8333-333333333333"

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
    func coatyJsLastWillFiresAfterAdvertiseAndIsUnretainedQos0() throws {
        let captured = try records(named: "coatyjs-last-will")

        let matching = try captured.filter { record in
            let payload = try decodedPayload(record)
            return payload.contains(identityId) || record.mqtt.topic.contains(identityId)
        }

        let advertised = matching.filter { $0.mqtt.topic.contains("/ADV:") }
        let deadvertised = matching.filter { $0.mqtt.topic.contains("/DAD/") }

        #expect(!advertised.isEmpty, "identity advertisement was not observed")
        #expect(!deadvertised.isEmpty, "identity last will was not observed after SIGKILL")

        let firstAdvertiseSequence = try #require(advertised.map(\.sequence).min())
        let firstDeadvertiseSequence = try #require(deadvertised.map(\.sequence).min())
        #expect(firstDeadvertiseSequence > firstAdvertiseSequence,
                "identity last will (sequence \(firstDeadvertiseSequence)) must follow its advertisement (sequence \(firstAdvertiseSequence))")

        for record in advertised + deadvertised {
            #expect(record.mqtt.qos == 0 && record.mqtt.retain == false,
                    "unexpected MQTT flags on \(record.mqtt.topic): qos=\(record.mqtt.qos) retain=\(record.mqtt.retain)")
        }
    }
}
