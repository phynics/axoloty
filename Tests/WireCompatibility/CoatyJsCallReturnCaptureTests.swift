// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@testable import Axoloty
import Foundation
import Testing

/// Verifies the semantic and topic contract of a pinned CoatyJS 2.4.0
/// Call/Return exchange, ported from the `verify_call_return` branch of
/// the former CoatyJS core live verifier.
///
/// This is the fourth and final request/response scenario ported (after
/// Discover/Resolve, Query/Retrieve, and Update/Complete). It exercises
/// correlation-id matching between a Call (CLL:<operationId>, requester)
/// and its Return (RTN, responder). The capture is committed under
/// `Tests/WireCompatibility/Fixtures/coatyjs-2.4.0/coatyjs-call-return.jsonl`.
struct CoatyJsCallReturnCaptureTests {
    private typealias CaptureRecord = WireCaptureFixture.Record

    private struct CallPayload: Decodable {
        struct Parameters: Decodable {
            let operand: Int
            let reference: String
        }
        let parameters: Parameters
    }

    private struct ReturnPayload: Decodable {
        struct Result: Decodable {
            let answer: Int
            let objectId: String
        }
        struct ExecutionInfo: Decodable {
            let executor: String
        }
        let result: Result
        let executionInfo: ExecutionInfo
    }

    private let namespace = "wire-compat-v1"
    private let requesterId = "22222222-2222-4222-8222-222222222222"
    private let responderId = "33333333-3333-4333-8333-333333333333"
    private let fixtureObjectId = "11111111-1111-4111-8111-111111111111"
    private let operationId = "wire-fixture-operation"

    private func records(named name: String) throws -> [CaptureRecord] {
        try WireCaptureFixture.records(named: name)
    }

    private func decoded<E: Decodable>(_ record: CaptureRecord, as type: E.Type) throws -> E {
        try WireCaptureFixture.decode(record, fixtureName: "coatyjs-call-return", as: type)
    }

    /// Splits a correlated topic (`coaty/3/<ns>/<EVENT>/<sourceId>/<correlationId>`)
    /// into (sourceId, correlationId), or nil if the shape doesn't match.
    private func correlatedSourceAndId(_ topic: String, eventLevel: String) -> (sourceId: String, correlationId: String)? {
        guard let parsed = try? WireCaptureFixture.correlatedTopic(
            topic, fixtureName: "coatyjs-call-return", recordNumber: 0, namespace: namespace, eventLevel: eventLevel
        ) else { return nil }
        return (parsed.sourceID, parsed.correlationID)
    }

    @Test
    func coatyJsCallReturnCaptureIsCorrelatedAndCarriesFixtureOperation() throws {
        let captured = try records(named: "coatyjs-call-return")

        // Exactly one Call from the requester, carrying the fixture operation parameters.
        let calls = captured.filter { record in
            guard let (sourceId, _) = correlatedSourceAndId(record.mqtt.topic, eventLevel: "CLL:" + operationId),
                  sourceId == requesterId,
                  let payload = try? decoded(record, as: CallPayload.self) else { return false }
            return payload.parameters.operand == 7 && payload.parameters.reference == "coatyjs-2.4.0"
        }
        #expect(calls.count == 1, "expected one deterministic Call; got \(calls.count)")

        let call = try #require(calls.first)
        let (_, correlationId) = try #require(correlatedSourceAndId(call.mqtt.topic, eventLevel: "CLL:" + operationId))

        // Exactly one Return from the responder, correlated by the same id,
        // carrying the deterministic answer and the executor marker.
        let returns = captured.filter { record in
            guard let (sourceId, cid) = correlatedSourceAndId(record.mqtt.topic, eventLevel: "RTN"),
                  sourceId == responderId, cid == correlationId,
                  let payload = try? decoded(record, as: ReturnPayload.self) else { return false }
            return payload.result.answer == 49
                && payload.result.objectId == fixtureObjectId
                && payload.executionInfo.executor == "coatyjs-2.4.0"
        }
        #expect(returns.count == 1, "expected one correlated deterministic Return for \(correlationId); got \(returns.count)")

        // Both legs must use QoS 0 / no RETAIN (CoatyJS 2.4.0 constraint).
        for record in [call, try #require(returns.first)] {
            #expect(record.mqtt.qos == 0 && record.mqtt.retain == false,
                    "CoatyJS 2.4.0 hardcodes QoS 0 / no RETAIN; got qos=\(record.mqtt.qos) retain=\(record.mqtt.retain) on \(record.mqtt.topic)")
        }
    }
}
