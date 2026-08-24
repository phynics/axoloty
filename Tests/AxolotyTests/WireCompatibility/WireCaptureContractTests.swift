// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyWire
import Foundation
import Testing

/// Replays provenance-bound captures through the current Foundation-free wire
/// decoder. These tests deliberately inspect the owned DTOs produced by
/// `BorrowedWireEvent`, rather than re-creating the retired host Codable model.
@Suite("offline wire capture contracts")
struct WireCaptureContractTests {
    private static let namespace = "wire-compat-v1"
    private static let fixtureID = "11111111-1111-4111-8111-111111111111"
    private static let fixtureType = "com.coaty.test.WireFixture"

    @Test("CoatyJS Advertise preserves both topic variants and object fields")
    func coatyJSAdvertise() throws {
        let records = try captures("coatyjs-advertise")
        let matches = try records.compactMap { record -> Captured? in
            guard record.mqtt.topic.contains("/ADV") else { return nil }
            let capture = try decode(record)
            guard case let .advertise(data) = capture.event,
                  let object = jsonObject(data.object),
                  object["objectId"] as? String == Self.fixtureID,
                  object["objectType"] as? String == Self.fixtureType,
                  object["name"] as? String == "wire-fixture" else { return nil }
            return capture
        }

        #expect(matches.count >= 2)
        let topics = Set(matches.map(\.record.mqtt.topic))
        #expect(topics.contains { $0.contains("ADV:CoatyObject/") })
        #expect(topics.contains { $0.contains("ADV::\(Self.fixtureType)/") })
        try expectQosZero(matches)
    }

    @Test("CoatyJS core captures preserve decoded event families")
    func coatyJSCoreEvents() throws {
        let deadvertise = try captures("coatyjs-deadvertise").map(decode)
        let deadadvertise = deadvertise.filter { $0.record.mqtt.topic.contains("/DAD/") }
        #expect(deadadvertise.contains { capture in
            guard case let .deadvertise(data) = capture.event else { return false }
            return jsonArray(data.objectIds).contains(Self.fixtureID)
        })

        let channel = try captures("coatyjs-channel").map(decode).first {
            $0.record.mqtt.topic.contains("/CHN:wire-fixture-channel/")
        }
        let channelData = try #require(channel)
        guard case let .channel(data) = channelData.event else {
            Issue.record("channel capture did not decode as ChannelWireData")
            return
        }
        let object = try #require(data.object.flatMap(jsonObject))
        let privateData = try #require(data.privateData.flatMap(jsonObject))
        #expect(object["objectId"] as? String == Self.fixtureID)
        #expect(object["objectType"] as? String == Self.fixtureType)
        #expect(privateData["sequence"] as? Int == 7)
        #expect(privateData["reference"] as? String == "coatyjs-2.4.0")
        try expectQosZero([channelData])
    }

    @Test("CoatyJS request and response captures retain correlation IDs")
    func coatyJSRequestResponse() throws {
        try assertCorrelated(
            fixture: "coatyjs-discover-resolve",
            request: .discover,
            response: .resolve,
            requestField: "objectTypes",
            responseObjectField: "object"
        )
        try assertCorrelated(
            fixture: "coatyjs-query-retrieve",
            request: .query,
            response: .retrieve,
            requestField: "objectTypes",
            responseObjectField: "objects"
        )
        try assertCorrelated(
            fixture: "coatyjs-update-complete",
            request: .update,
            response: .complete,
            requestField: "object",
            responseObjectField: "object"
        )
        try assertCorrelated(
            fixture: "coatyjs-call-return",
            request: .call,
            response: .returnEvent,
            requestField: "parameters",
            responseObjectField: "result"
        )
    }

    @Test("CoatyJS lifecycle captures preserve last-will and QoS evidence")
    func coatyJSLifecycle() throws {
        let lastWill = try captures("coatyjs-last-will").map(decode)
        #expect(lastWill.contains { $0.record.mqtt.topic.contains("/ADV:") })
        #expect(lastWill.contains { $0.record.mqtt.topic.contains("/DAD/") })
        try expectQosZero(lastWill)

        let qos = try captures("coatyjs-qos-0").map(decode)
        #expect(qos.contains { $0.record.mqtt.topic.contains("/ADV:") })
        try expectQosZero(qos)

        let graceful = try captures("coatyjs-graceful-deadvertise").map(decode)
        #expect(graceful.contains { $0.record.mqtt.topic.contains("/DAD/") })
        try expectQosZero(graceful)
    }

    @Test("legacy captures decode through the shared wire DTOs")
    func legacyCaptures() throws {
        let advertise = try captures("advertise", directory: "coatyswift-2.4.0").map(decode)
        #expect(advertise.contains { capture in
            guard case let .advertise(data) = capture.event,
                  let object = jsonObject(data.object) else { return false }
            return object["objectType"] as? String == "org.axoloty.wire.ReferenceObject"
                && object["objectId"] as? String == "00000000-0000-4000-8000-000000000101"
        })

        let deadvertise = try captures("deadvertise", directory: "coatyswift-2.4.0").map(decode)
        #expect(deadvertise.contains { capture in
            guard case let .deadvertise(data) = capture.event else { return false }
            return jsonArray(data.objectIds).contains("00000000-0000-4000-8000-000000000101")
        })

        let discoverResolve = try captures("discover-resolve", directory: "coatyswift-2.4.0").map(decode)
        try assertPair(discoverResolve, request: .discover, response: .resolve)
    }

    private enum EventFamily {
        case discover, resolve, query, retrieve, update, complete, call, returnEvent
    }

    private struct Captured {
        let record: WireCaptureFixture.Record
        let event: OwnedWireEvent
    }

    private func captures(_ name: String, directory: String = "coatyjs-2.4.0") throws -> [WireCaptureFixture.Record] {
        try WireCaptureFixture.records(named: "\(directory)/\(name)")
    }

    private func decode(_ record: WireCaptureFixture.Record) throws -> Captured {
        let payload = try #require(Data(base64Encoded: record.payload.bytes))
        let topic = Array(record.mqtt.topic.utf8)
        let bytes = Array(payload)
        let event = try topic.withUnsafeBufferPointer { topicBuffer in
            try bytes.withUnsafeBufferPointer { payloadBuffer in
                let message = try BorrowedMessage.validated(
                    topicBytes: topicBuffer.baseAddress!, topicLength: topicBuffer.count,
                    payloadBytes: payloadBuffer.baseAddress!, payloadLength: payloadBuffer.count
                )
                return try BorrowedWireEvent(message: message).owned()
            }
        }
        return Captured(record: record, event: event)
    }

    private func assertCorrelated(
        fixture: String,
        request: EventFamily,
        response: EventFamily,
        requestField: String,
        responseObjectField: String
    ) throws {
        let captures = try captures(fixture).map(decode)
        try assertPair(captures, request: request, response: response)
        let requests = captures.filter { family(of: $0.event) == request }
        let responses = captures.filter { family(of: $0.event) == response }
        let responseCapture = try #require(responses.first)
        let responseTopic = responseCapture.record.mqtt.topic.split(separator: "/")
        let requestCapture = try #require(requests.first {
            $0.record.mqtt.topic.split(separator: "/").last == responseTopic.last
        })
        try assertPayload(requestCapture, field: requestField)
        try assertPayload(responseCapture, field: responseObjectField)
        try expectQosZero([requestCapture, responseCapture])
    }

    private func assertPair(_ captures: [Captured], request: EventFamily, response: EventFamily) throws {
        let requests = captures.filter { family(of: $0.event) == request }
        let responses = captures.filter { family(of: $0.event) == response }
        #expect(!requests.isEmpty)
        #expect(!responses.isEmpty)
        let responseTopics = Set(responses.compactMap { $0.record.mqtt.topic.split(separator: "/").last })
        #expect(requests.contains {
            guard let topic = $0.record.mqtt.topic.split(separator: "/").last else { return false }
            return responseTopics.contains(topic)
        })
    }

    private func family(of event: OwnedWireEvent) -> EventFamily? {
        switch event {
        case .discover: return .discover
        case .resolve: return .resolve
        case .query: return .query
        case .retrieve: return .retrieve
        case .update: return .update
        case .complete: return .complete
        case .call: return .call
        case .returnEvent: return .returnEvent
        default: return nil
        }
    }

    private func assertPayload(_ capture: Captured, field: String) throws {
        switch capture.event {
        case let .discover(data) where field == "objectTypes":
            let types = try #require(data.objectTypes.flatMap(jsonArray))
            #expect(types.contains(Self.fixtureType))
        case let .query(data) where field == "objectTypes":
            let types = try #require(data.objectTypes.flatMap(jsonArray))
            #expect(types.contains(Self.fixtureType))
            #expect(data.objectFilter.flatMap(jsonObject) != nil)
        case let .call(data) where field == "parameters":
            let parameters = try #require(data.parameters.flatMap(jsonObject))
            #expect(parameters["operand"] as? Int == 7)
            #expect(parameters["reference"] as? String == "coatyjs-2.4.0")
        case let .update(data) where field == "object":
            let object = try #require(jsonObject(data.object))
            #expect(object["objectId"] as? String == Self.fixtureID)
        case let .resolve(data) where field == "object":
            let object = try #require(jsonObject(data.object))
            #expect(object["objectId"] as? String == Self.fixtureID)
        case let .retrieve(data) where field == "objects":
            let objects = try #require(jsonArrayOfObjects(data.objects))
            #expect(objects.contains { $0["objectId"] as? String == Self.fixtureID })
        case let .complete(data) where field == "object":
            let object = try #require(data.object.flatMap(jsonObject))
            #expect(object["objectId"] as? String == Self.fixtureID)
        case let .returnEvent(data) where field == "result":
            let result = try #require(data.result.flatMap(jsonObject))
            #expect(result["answer"] as? Int == 49)
            #expect(result["objectId"] as? String == Self.fixtureID)
        default:
            Issue.record("unexpected (field) payload for (capture.record.mqtt.topic)")
        }
    }

    private func expectQosZero(_ captures: [Captured]) throws {
        for capture in captures {
            #expect(capture.record.mqtt.qos == 0)
            #expect(capture.record.mqtt.retain == false)
        }
    }

    private func jsonObject(_ bytes: [UInt8]) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any]
    }

    private func jsonArray(_ bytes: [UInt8]) -> [String] {
        (try? JSONSerialization.jsonObject(with: Data(bytes)) as? [String]) ?? []
    }

    private func jsonArrayOfObjects(_ bytes: [UInt8]) -> [[String: Any]]? {
        try? JSONSerialization.jsonObject(with: Data(bytes)) as? [[String: Any]]
    }
}
