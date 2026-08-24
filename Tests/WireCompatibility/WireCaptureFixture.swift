// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// Loads provenance-bound offline wire captures without conflating them with
/// live-wire artifacts.
enum WireCaptureFixture {
    struct Record: Decodable {
        struct MQTT: Decodable {
            let topic: String
            let qos: Int
            let retain: Bool
        }

        struct Payload: Decodable {
            let encoding: String
            let bytes: String
        }

        struct Producer: Decodable {
            let implementation: String
            let version: String
        }

        let format: String
        let producer: Producer
        let scenario: String
        let sequence: Int
        let capturedAt: String
        let mqtt: MQTT
        let payload: Payload
        let normalizationProfile: String
    }

    struct CorrelatedTopic: Equatable {
        let sourceID: String
        let correlationID: String
    }

    enum Error: Swift.Error, LocalizedError {
        case resource(String)
        case record(fixture: String, number: Int, field: String, value: String)

        var errorDescription: String? {
            switch self {
            case .resource(let fixture):
                return "fixture \(fixture): resource not found"
            case .record(let fixture, let number, let field, let value):
                return "fixture \(fixture), record \(number), field \(field): malformed value \(value)"
            }
        }
    }

    let name: String
    let records: [Record]

    init(named name: String) throws {
        guard let url = Bundle.module.url(forResource: name, withExtension: "jsonl") else {
            throw Error.resource(name)
        }
        try self.init(name: name, text: String(contentsOf: url, encoding: .utf8))
    }

    init(name: String, text: String) throws {
        self.name = name
        records = try text.split(separator: "\n", omittingEmptySubsequences: true).enumerated().map { offset, line in
            do {
                return try JSONDecoder().decode(Record.self, from: Data(line.utf8))
            } catch {
                throw Error.record(fixture: name, number: offset + 1, field: "record", value: String(line))
            }
        }
    }

    static func records(named name: String) throws -> [Record] {
        try WireCaptureFixture(named: name).records
    }

    static func decode<T: Decodable>(_ record: Record, fixtureName: String, as type: T.Type) throws -> T {
        try WireCaptureFixture(name: fixtureName, text: "").decode(record, as: type)
    }

    func decode<T: Decodable>(_ record: Record, as type: T.Type) throws -> T {
        let number = record.sequence
        guard record.payload.encoding == "base64" else {
            throw Error.record(fixture: name, number: number, field: "payload.encoding", value: record.payload.encoding)
        }
        guard let bytes = Data(base64Encoded: record.payload.bytes) else {
            throw Error.record(fixture: name, number: number, field: "payload.bytes", value: record.payload.bytes)
        }
        do {
            return try JSONDecoder().decode(type, from: bytes)
        } catch {
            throw Error.record(fixture: name, number: number, field: "payload.bytes", value: record.payload.bytes)
        }
    }

    func payloadText(_ record: Record) throws -> String {
        let number = record.sequence
        guard record.payload.encoding == "base64", let bytes = Data(base64Encoded: record.payload.bytes),
              let text = String(data: bytes, encoding: .utf8) else {
            throw Error.record(fixture: name, number: number, field: "payload.bytes", value: record.payload.bytes)
        }
        return text
    }

    func correlatedTopic(_ record: Record, namespace: String, eventLevel: String) throws -> CorrelatedTopic {
        let levels = record.mqtt.topic.split(separator: "/").map(String.init)
        guard levels.count == 6, levels[0] == "coaty", levels[1] == "3", levels[2] == namespace,
              levels[3] == eventLevel, !levels[4].isEmpty, !levels[5].isEmpty else {
            throw Error.record(fixture: name, number: record.sequence, field: "mqtt.topic", value: record.mqtt.topic)
        }
        return CorrelatedTopic(sourceID: levels[4], correlationID: levels[5])
    }

    static func correlatedTopic(_ topic: String, fixtureName: String, recordNumber: Int, namespace: String, eventLevel: String) throws -> CorrelatedTopic {
        let record = Record(
            format: "",
            producer: .init(implementation: "", version: ""),
            scenario: "",
            sequence: recordNumber,
            capturedAt: "",
            mqtt: .init(topic: topic, qos: 0, retain: false),
            payload: .init(encoding: "base64", bytes: ""),
            normalizationProfile: ""
        )
        return try WireCaptureFixture(name: fixtureName, text: "").correlatedTopic(record, namespace: namespace, eventLevel: eventLevel)
    }
}
