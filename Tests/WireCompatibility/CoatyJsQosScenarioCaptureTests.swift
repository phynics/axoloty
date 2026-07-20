// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@testable import Axoloty
import Foundation
import Testing

/// Verifies the semantic contract for the qos-0 and graceful-deadvertise
/// lifecycle scenarios, ported from
/// `Tests/WireCompatibility/Lifecycle/Live/verify-coatyjs-qos-scenario.py`.
///
/// The captures are committed under
/// `Tests/WireCompatibility/Fixtures/coatyjs-2.4.0/coatyjs-qos-0.jsonl` and
/// `coatyjs-graceful-deadvertise.jsonl`.
struct CoatyJsQosScenarioCaptureTests {
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

    private struct ObjectEnvelope: Decodable {
        struct Object: Decodable {
            let objectId: String
        }
        let object: Object
    }

    private func records(named name: String) throws -> [CaptureRecord] {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "jsonl"))
        let text = try String(contentsOf: url, encoding: .utf8)
        return try text
            .split(separator: "\n")
            .map { try JSONDecoder().decode(CaptureRecord.self, from: Data($0.utf8)) }
    }

    /// Every publication of a given object, decoded and matched by objectId,
    /// must use the expected QoS -- CoatyJS 2.4.0 publishes everything at
    /// QoS 0, so this pins that constraint rather than merely observing it.
    @Test
    func coatyJsPublishesEveryObjectRepresentationAtQos0() throws {
        let objectId = "55555555-5555-4555-8555-000000000000"
        let captured = try records(named: "coatyjs-qos-0")

        let matching = captured.filter { record in
            guard record.mqtt.topic.hasPrefix("coaty/3/"),
                  let bytes = Data(base64Encoded: record.payload.bytes),
                  let envelope = try? JSONDecoder().decode(ObjectEnvelope.self, from: bytes) else { return false }
            return envelope.object.objectId == objectId
        }

        #expect(!matching.isEmpty, "no publication of object \(objectId) was observed")
        for record in matching {
            #expect(record.mqtt.qos == 0, "expected QoS 0 on \(record.mqtt.topic), got \(record.mqtt.qos)")
        }
    }

    /// A clean shutdown (as opposed to the last-will path in
    /// CoatyJsLastWillCaptureTests) still yields a Deadvertise following the
    /// identity's Advertise, unretained, at QoS 0.
    @Test
    func coatyJsGracefulShutdownDeadvertisesAfterAdvertise() throws {
        let identityId = "44444444-4444-4444-8444-000000000000"
        let captured = try records(named: "coatyjs-graceful-deadvertise")

        let advertised = captured.filter { $0.mqtt.topic.contains("/ADV:Identity/") && $0.mqtt.topic.contains(identityId) }
        let deadvertised = captured.filter { $0.mqtt.topic.contains("/DAD/") && $0.mqtt.topic.contains(identityId) }

        #expect(!advertised.isEmpty, "identity advertisement was not observed")
        #expect(!deadvertised.isEmpty, "graceful Deadvertise was not observed")

        let firstAdvertiseSequence = try #require(advertised.map(\.sequence).min())
        let firstDeadvertiseSequence = try #require(deadvertised.map(\.sequence).min())
        #expect(firstDeadvertiseSequence > firstAdvertiseSequence,
                "Deadvertise (sequence \(firstDeadvertiseSequence)) must follow its Advertise (sequence \(firstAdvertiseSequence))")

        for record in advertised + deadvertised {
            #expect(record.mqtt.qos == 0 && record.mqtt.retain == false,
                    "unexpected MQTT flags on \(record.mqtt.topic): qos=\(record.mqtt.qos) retain=\(record.mqtt.retain)")
        }
    }
}
