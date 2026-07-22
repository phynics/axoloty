// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@testable import Axoloty
import Foundation
import Testing

/// Verifies the semantic and topic contract of a pinned CoatyJS 2.4.0
/// Update/Complete exchange, ported from the `verify_update_complete`
/// branch of the former CoatyJS core live verifier.
///
/// This is the third request/response scenario ported (after Discover/
/// Resolve and Query/Retrieve). It additionally checks that an Update
/// targeting the object's declared type is routed to both the concrete
/// type topic (`UPD::<objectType>`, which draws a Complete response) and
/// the `CoatyObject` supertype topic (`UPD:CoatyObject`, observational
/// only — CoatyJS 2.4.0 does not complete supertype-routed updates). The
/// capture is committed under
/// `Tests/WireCompatibility/Fixtures/coatyjs-2.4.0/coatyjs-update-complete.jsonl`.
struct CoatyJsUpdateCompleteCaptureTests {
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

    private struct ObjectPayload: Decodable {
        struct Object: Decodable {
            let objectId: String
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
    func coatyJsUpdateCompleteCaptureIsCorrelatedAndCarriesFixtureObject() throws {
        let captured = try records(named: "coatyjs-update-complete")

        // Exactly one concrete-type Update from the requester, carrying the fixture object.
        let concreteUpdates = captured.filter { record in
            guard let (sourceId, _) = correlatedSourceAndId(record.mqtt.topic, eventLevel: "UPD::" + fixtureObjectType),
                  sourceId == requesterId,
                  let payload = try? decoded(record, as: ObjectPayload.self) else { return false }
            return payload.object.objectId == fixtureObjectId && payload.object.name == fixtureName
        }
        #expect(concreteUpdates.count == 1, "expected one deterministic Update; got \(concreteUpdates.count)")

        let update = try #require(concreteUpdates.first)
        let (_, correlationId) = try #require(correlatedSourceAndId(update.mqtt.topic, eventLevel: "UPD::" + fixtureObjectType))

        // Exactly one Complete from the responder, correlated by the same id.
        let completes = captured.filter { record in
            guard let (sourceId, cid) = correlatedSourceAndId(record.mqtt.topic, eventLevel: "CPL"),
                  sourceId == responderId, cid == correlationId,
                  let payload = try? decoded(record, as: ObjectPayload.self) else { return false }
            return payload.object.objectId == fixtureObjectId
                && payload.object.name == "wire-fixture-completed"
                && payload.privateData?["reference"] == "coatyjs-2.4.0"
        }
        #expect(completes.count == 1, "expected one correlated deterministic Complete for \(correlationId); got \(completes.count)")

        // A parallel Update routed to the CoatyObject supertype topic also fired
        // (no Complete response expected for it in this scenario).
        let supertypeUpdates = captured.filter { record in
            guard let (sourceId, _) = correlatedSourceAndId(record.mqtt.topic, eventLevel: "UPD:CoatyObject"),
                  sourceId == requesterId,
                  let payload = try? decoded(record, as: ObjectPayload.self) else { return false }
            return payload.object.objectId == fixtureObjectId && payload.object.name == fixtureName
        }
        #expect(supertypeUpdates.count == 1, "expected one deterministic CoatyObject-routed Update; got \(supertypeUpdates.count)")

        // All three legs must use QoS 0 / no RETAIN (CoatyJS 2.4.0 constraint).
        for record in [update, try #require(completes.first), try #require(supertypeUpdates.first)] {
            #expect(record.mqtt.qos == 0 && record.mqtt.retain == false,
                    "CoatyJS 2.4.0 hardcodes QoS 0 / no RETAIN; got qos=\(record.mqtt.qos) retain=\(record.mqtt.retain) on \(record.mqtt.topic)")
        }
    }
}
