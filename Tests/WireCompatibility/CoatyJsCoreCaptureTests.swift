// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@testable import Axoloty
import Foundation
import Testing

/// Verifies the semantic and topic contract of pinned CoatyJS 2.4.0 one-way
/// core event captures (Deadvertise, Channel), ported from the corresponding
/// branches of `Tests/WireCompatibility/Live/verify-coatyjs-core.py`.
///
/// Captures are committed under
/// `Tests/WireCompatibility/Fixtures/coatyjs-2.4.0/coatyjs-{deadvertise,channel}.jsonl`
/// (pinned from live `run-coatyjs-core.sh` runs), so the contracts are
/// asserted deterministically at PR tier. Mirrors `CoatyJsAdvertiseCaptureTests`
/// and `LegacyCaptureFixtureTests` (Codable capture record, `Bundle.module`
/// resource, base64 payload decode, typed semantic assertions).
struct CoatyJsCoreCaptureTests {
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

    private let requesterId = "22222222-2222-4222-8222-222222222222"
    private let fixtureObjectId = "11111111-1111-4111-8111-111111111111"
    private let namespace = "wire-compat-v1"

    private func records(named name: String) throws -> [CaptureRecord] {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "jsonl"))
        let text = try String(contentsOf: url, encoding: .utf8)
        return try text
            .split(separator: "\n")
            .map { try JSONDecoder().decode(CaptureRecord.self, from: Data($0.utf8)) }
    }

    private func decodedPayload<E: Decodable>(_ record: CaptureRecord, as type: E.Type) throws -> E {
        let bytes = try #require(Data(base64Encoded: record.payload.bytes))
        return try JSONDecoder().decode(E.self, from: bytes)
    }

    @Test
    func coatyJsDeadvertiseCaptureCarriesTheFixtureObjectId() throws {
        let captured = try records(named: "coatyjs-deadvertise")
        let deadvertises = captured.filter { $0.mqtt.topic.hasPrefix("coaty/3/\(namespace)/DAD/") }
        #expect(deadvertises.isEmpty == false, "expected at least one Deadvertise publication")

        let matching = deadvertises.filter { record in
            guard let event = try? decodedPayload(record, as: DeadvertiseEvent.self) else { return false }
            return event.data.objectIds.map(\.string).contains(fixtureObjectId)
        }
        #expect(matching.count == 1, "expected exactly one Deadvertise carrying the fixture objectId; got \(matching.count)")

        let record = try #require(matching.first)
        #expect(record.mqtt.topic == "coaty/3/\(namespace)/DAD/\(requesterId)",
                "Deadvertise topic must be source-routed to the requester; got \(record.mqtt.topic)")
        #expect(record.mqtt.qos == 0 && record.mqtt.retain == false,
                "CoatyJS 2.4.0 hardcodes QoS 0 / no RETAIN")
    }

    @Test
    func coatyJsChannelCaptureCarriesTheFixtureObjectAndPrivateData() throws {
        let captured = try records(named: "coatyjs-channel")
        let channels = captured.filter { $0.mqtt.topic.hasPrefix("coaty/3/\(namespace)/CHN:wire-fixture-channel/") }
        #expect(channels.isEmpty == false, "expected at least one Channel publication")

        let matching = channels.filter { record in
            guard let event = try? decodedPayload(record, as: ChannelEvent.self),
                  let object = event.data.object else { return false }
            return object.objectId.string == fixtureObjectId
                && object.objectType == "com.coaty.test.WireFixture"
                && object.name == "wire-fixture"
                && event.data.privateData?["sequence"] as? Double == 7
                && event.data.privateData?["reference"] as? String == "coatyjs-2.4.0"
        }
        #expect(matching.count == 1, "expected exactly one Channel carrying the fixture object + privateData; got \(matching.count)")

        let record = try #require(matching.first)
        #expect(record.mqtt.topic == "coaty/3/\(namespace)/CHN:wire-fixture-channel/\(requesterId)",
                "Channel topic must be source-routed to the requester; got \(record.mqtt.topic)")
        #expect(record.mqtt.qos == 0 && record.mqtt.retain == false,
                "CoatyJS 2.4.0 hardcodes QoS 0 / no RETAIN")
    }
}
