// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@testable import Axoloty
import Foundation
import Testing

/// Verifies the semantic and topic contract of a pinned CoatyJS 2.4.0
/// Discover/Resolve exchange, ported from the `verify_discover_resolve`
/// branch of the former CoatyJS core live verifier.
///
/// This is the first request/response scenario ported: it exercises the
/// correlation-id matching between a Discover (DSC, requester) and its
/// Resolve (RSV, responder), which the one-way captures (advertise,
/// deadvertise, channel) do not. The capture is committed under
/// `Tests/WireCompatibility/Fixtures/coatyjs-2.4.0/coatyjs-discover-resolve.jsonl`.
struct CoatyJsDiscoverResolveCaptureTests {
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

    private struct DiscoverPayload: Decodable {
        let objectTypes: [String]
    }

    private struct ResolvePayload: Decodable {
        struct Object: Decodable {
            let objectId: String
            let objectType: String
            let name: String
        }
        let object: Object
        let privateData: [String: String]?
    }

    private let namespace = "wire-compat-v1"
    private let requesterId = "22222222-2222-4222-8222-222222222222"
    private let responderId = "33333333-3333-4333-8333-333333333333"
    private let fixtureObjectId = "11111111-1111-4111-8111-111111111111"
    private let fixtureObjectType = "com.coaty.test.WireFixture"
    private let fixtureName = "wire-fixture"

    private func records(named name: String) throws -> [CaptureRecord] {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "jsonl"))
        let text = try String(contentsOf: url, encoding: .utf8)
        return try text
            .split(separator: "\n")
            .map { try JSONDecoder().decode(CaptureRecord.self, from: Data($0.utf8)) }
    }

    private func decoded<E: Decodable>(_ record: CaptureRecord, as type: E.Type) throws -> E {
        let bytes = try #require(Data(base64Encoded: record.payload.bytes))
        return try JSONDecoder().decode(E.self, from: bytes)
    }

    /// Splits a correlated topic (`coaty/3/<ns>/<EVENT>/<sourceId>/<correlationId>`)
    /// into (sourceId, correlationId), or nil if the shape doesn't match.
    private func correlatedSourceAndId(_ topic: String, eventLevel: String) -> (sourceId: String, correlationId: String)? {
        let levels = topic.split(separator: "/").map(String.init)
        guard levels.count == 6,
              levels[0] == "coaty", levels[1] == "3",
              levels[2] == namespace, levels[3] == eventLevel else { return nil }
        return (levels[4], levels[5])
    }

    @Test
    func coatyJsDiscoverResolveCaptureIsCorrelatedAndCarriesFixtureObject() throws {
        let captured = try records(named: "coatyjs-discover-resolve")

        // Exactly one Discover from the requester, carrying the fixture object type.
        let discovers = captured.filter { record in
            guard let (sourceId, _) = correlatedSourceAndId(record.mqtt.topic, eventLevel: "DSC"),
                  sourceId == requesterId,
                  let payload = try? decoded(record, as: DiscoverPayload.self) else { return false }
            return payload.objectTypes.contains(fixtureObjectType)
        }
        #expect(discovers.count == 1, "expected one deterministic Discover; got \(discovers.count)")

        let discover = try #require(discovers.first)
        let (_, correlationId) = try #require(correlatedSourceAndId(discover.mqtt.topic, eventLevel: "DSC"))

        // Exactly one Resolve from the responder, correlated by the same id,
        // carrying the fixture object and the responder marker.
        let resolves = captured.filter { record in
            guard let (sourceId, cid) = correlatedSourceAndId(record.mqtt.topic, eventLevel: "RSV"),
                  sourceId == responderId, cid == correlationId,
                  let payload = try? decoded(record, as: ResolvePayload.self) else { return false }
            return payload.object.objectId == fixtureObjectId
                && payload.object.objectType == fixtureObjectType
                && payload.object.name == fixtureName
                && payload.privateData?["reference"] == "coatyjs-2.4.0"
        }
        #expect(resolves.count == 1, "expected one correlated deterministic Resolve for \(correlationId); got \(resolves.count)")

        // Both legs must use QoS 0 / no RETAIN (CoatyJS 2.4.0 constraint).
        for record in [discover, try #require(resolves.first)] {
            #expect(record.mqtt.qos == 0 && record.mqtt.retain == false,
                    "CoatyJS 2.4.0 hardcodes QoS 0 / no RETAIN; got qos=\(record.mqtt.qos) retain=\(record.mqtt.retain) on \(record.mqtt.topic)")
        }
    }
}
