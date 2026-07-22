// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@testable import Axoloty
import Foundation
import Testing

/// Verifies the semantic and topic contract of a pinned CoatyJS 2.4.0
/// Query/Retrieve exchange, ported from the `verify_query_retrieve` branch
/// of the former CoatyJS core live verifier.
///
/// This is the second request/response scenario ported (after Discover/
/// Resolve): it exercises correlation-id matching between a Query (QRY,
/// requester) and its Retrieve (RTV, responder). The capture is committed
/// under `Tests/WireCompatibility/Fixtures/coatyjs-2.4.0/coatyjs-query-retrieve.jsonl`.
struct CoatyJsQueryRetrieveCaptureTests {
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

    private struct QueryPayload: Decodable {
        let objectTypes: [String]
    }

    private struct RetrievePayload: Decodable {
        struct Object: Decodable {
            let objectId: String
        }
        let objects: [Object]
        let privateData: [String: String]?
    }

    private let namespace = "wire-compat-v1"
    private let requesterId = "22222222-2222-4222-8222-222222222222"
    private let responderId = "33333333-3333-4333-8333-333333333333"
    private let fixtureObjectId = "11111111-1111-4111-8111-111111111111"
    private let fixtureObjectType = "com.coaty.test.WireFixture"

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
    func coatyJsQueryRetrieveCaptureIsCorrelatedAndCarriesFixtureObject() throws {
        let captured = try records(named: "coatyjs-query-retrieve")

        // Exactly one Query from the requester, carrying the fixture object type.
        let queries = captured.filter { record in
            guard let (sourceId, _) = correlatedSourceAndId(record.mqtt.topic, eventLevel: "QRY"),
                  sourceId == requesterId,
                  let payload = try? decoded(record, as: QueryPayload.self) else { return false }
            return payload.objectTypes.contains(fixtureObjectType)
        }
        #expect(queries.count == 1, "expected one deterministic Query; got \(queries.count)")

        let query = try #require(queries.first)
        let (_, correlationId) = try #require(correlatedSourceAndId(query.mqtt.topic, eventLevel: "QRY"))

        // Exactly one Retrieve from the responder, correlated by the same id,
        // carrying the fixture object and the deterministic-result marker.
        let retrieves = captured.filter { record in
            guard let (sourceId, cid) = correlatedSourceAndId(record.mqtt.topic, eventLevel: "RTV"),
                  sourceId == responderId, cid == correlationId,
                  let payload = try? decoded(record, as: RetrievePayload.self) else { return false }
            return payload.objects.contains { $0.objectId == fixtureObjectId }
                && payload.privateData?["reference"] == "coatyjs-2.4.0"
                && payload.privateData?["resultSet"] == "deterministic"
        }
        #expect(retrieves.count == 1, "expected one correlated deterministic Retrieve for \(correlationId); got \(retrieves.count)")

        // Both legs must use QoS 0 / no RETAIN (CoatyJS 2.4.0 constraint).
        for record in [query, try #require(retrieves.first)] {
            #expect(record.mqtt.qos == 0 && record.mqtt.retain == false,
                    "CoatyJS 2.4.0 hardcodes QoS 0 / no RETAIN; got qos=\(record.mqtt.qos) retain=\(record.mqtt.retain) on \(record.mqtt.topic)")
        }
    }
}
