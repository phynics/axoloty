// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyInspectorCore
import Foundation
import Testing

@Suite
struct InspectorRecordEncodingTests {

    // MARK: - NDJSON encoding

    @Test
    func ndjsonEncodingIsStableAndOneLine() throws {
        let record = InspectorRecord(
            kind: .advertise,
            timestamp: "2026-07-31T17:30:00Z",
            namespace: "example",
            sourceId: "source-uuid",
            objectId: "object-uuid",
            coreType: "Identity",
            objectType: "coaty.object.Identity",
            name: "Agent"
        )
        let line = try NDJSONFormatter().format(record)

        #expect(!line.contains("\n"))
        let json = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        #expect(json["schema"] as? String == "axoloty.inspect/v1")
        #expect(json["kind"] as? String == "advertise")
        #expect(line.contains("\"timestamp\":\"2026-07-31T17:30:00Z\""))
    }

    @Test
    func schemaVersionAlwaysPresent() throws {
        let record = InspectorRecord(
            kind: .sessionStarted,
            timestamp: "2026-07-31T00:00:00Z"
        )
        let line = try NDJSONFormatter().format(record)
        let json = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        #expect(json["schema"] as? String == "axoloty.inspect/v1")
    }

    @Test
    func nilFieldsOmittedFromJSON() throws {
        let record = InspectorRecord(
            kind: .advertise,
            timestamp: "2026-07-31T00:00:00Z",
            objectId: "obj-1",
            coreType: "Sensor"
        )
        let line = try NDJSONFormatter().format(record)

        #expect(!line.contains("\"payload\""))
        #expect(!line.contains("\"privateData\""))
        #expect(!line.contains("\"name\""))
        #expect(!line.contains("\"removedObjectIds\""))
    }

    @Test
    func dictionaryOrderingDoesNotAffectEncoding() throws {
        let obj1 = InspectorObject(objectId: "aaa", coreType: "X", objectType: "Y", name: "A")
        let obj2 = InspectorObject(objectId: "zzz", coreType: "X", objectType: "Y", name: "Z")

        let record1 = InspectorRecord(
            kind: .advertise, timestamp: "t",
            objectId: obj1.objectId, coreType: obj1.coreType,
            objectType: obj1.objectType, name: obj1.name
        )
        let record2 = InspectorRecord(
            kind: .advertise, timestamp: "t",
            objectId: obj2.objectId, coreType: obj2.coreType,
            objectType: obj2.objectType, name: obj2.name
        )

        let line1 = try NDJSONFormatter().format(record1)
        let line2 = try NDJSONFormatter().format(record2)

        let json1 = try #require(JSONSerialization.jsonObject(with: Data(line1.utf8)) as? [String: Any])
        let json2 = try #require(JSONSerialization.jsonObject(with: Data(line2.utf8)) as? [String: Any])

        #expect(json1["schema"] as? String == "axoloty.inspect/v1")
        #expect(json2["schema"] as? String == "axoloty.inspect/v1")
        #expect(json1["kind"] as? String == "advertise")
        #expect(json2["kind"] as? String == "advertise")
    }

    @Test
    func advertiseRecordDecodesCorrectly() throws {
        let original = InspectorRecord(
            kind: .advertise,
            timestamp: "2026-07-31T17:30:00Z",
            namespace: "ns",
            sourceId: "src",
            objectId: "obj",
            coreType: "Identity",
            objectType: "coaty.object.Identity",
            name: "Agent"
        )
        let line = try NDJSONFormatter().format(original)
        let decoded = try JSONDecoder().decode(InspectorRecord.self, from: Data(line.utf8))

        #expect(decoded == original)
    }

    @Test
    func deadvertiseRecordWithRemovedIds() throws {
        let record = InspectorRecord(
            kind: .deadvertise,
            timestamp: "2026-07-31T00:00:00Z",
            namespace: "ns",
            removedObjectIds: ["obj-1", "obj-2"]
        )
        let line = try NDJSONFormatter().format(record)
        let json = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])

        #expect(json["removedObjectIds"] as? [String] == ["obj-1", "obj-2"])
        #expect(json["kind"] as? String == "deadvertise")
    }

    @Test
    func errorRecordEncoding() throws {
        let record = InspectorRecord(
            kind: .error,
            timestamp: "2026-07-31T00:00:00Z",
            namespace: "ns",
            error: "connection refused"
        )
        let line = try NDJSONFormatter().format(record)
        let json = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])

        #expect(json["error"] as? String == "connection refused")
        #expect(json["kind"] as? String == "error")
    }

    @Test
    func discoveryResultEncoding() throws {
        let objects = [
            InspectorObject(objectId: "1", coreType: "Identity", objectType: "t", name: "A"),
            InspectorObject(objectId: "2", coreType: "Sensor", objectType: "t2", name: "B"),
        ]
        let record = InspectorRecord(
            kind: .discoveryResult,
            timestamp: "2026-07-31T00:00:00Z",
            namespace: "ns",
            timedOut: true,
            objects: objects
        )
        let line = try NDJSONFormatter().format(record)
        let json = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])

        #expect(json["kind"] as? String == "discovery-result")
        #expect(json["timedOut"] as? Bool == true)
        #expect((json["objects"] as? [[String: Any]])?.count == 2)
    }

    // MARK: - Human format

    @Test
    func humanSessionStarted() {
        let record = InspectorRecord(
            kind: .sessionStarted,
            timestamp: "2026-07-31T00:00:00Z",
            namespace: "demo"
        )
        let line = HumanFormatter().format(record)
        #expect(line == "CONNECTED  namespace=demo")
    }

    @Test
    func humanAdvertise() {
        let record = InspectorRecord(
            kind: .advertise,
            timestamp: "2026-07-31T00:00:00Z",
            objectId: "abcdef1234567890",
            coreType: "Identity",
            name: "Agent A"
        )
        let line = HumanFormatter().format(record)
        #expect(line.contains("ADD"))
        #expect(line.contains("Identity"))
        #expect(line.contains("Agent A"))
        #expect(line.contains("abcd…7890"))
    }

    @Test
    func humanObjectUpdated() {
        let record = InspectorRecord(
            kind: .objectUpdated,
            timestamp: "2026-07-31T00:00:00Z",
            objectId: "abcdef1234567890",
            coreType: "Sensor",
            name: "Temperature"
        )
        let line = HumanFormatter().format(record)
        #expect(line.contains("UPDATE"))
        #expect(line.contains("Sensor"))
    }

    @Test
    func humanDeadvertise() {
        let record = InspectorRecord(
            kind: .deadvertise,
            timestamp: "2026-07-31T00:00:00Z",
            objectId: "abcdef1234567890",
            coreType: "Identity",
            name: "Agent"
        )
        let line = HumanFormatter().format(record)
        #expect(line.contains("REMOVE"))
    }

    @Test
    func humanSessionEnded() {
        let record = InspectorRecord(
            kind: .sessionEnded,
            timestamp: "2026-07-31T00:00:00Z"
        )
        let line = HumanFormatter().format(record)
        #expect(line == "DISCONNECTED")
    }

    @Test
    func humanError() {
        let record = InspectorRecord(
            kind: .error,
            timestamp: "2026-07-31T00:00:00Z",
            error: "broker unavailable"
        )
        let line = HumanFormatter().format(record)
        #expect(line.contains("ERROR"))
        #expect(line.contains("broker unavailable"))
    }

    // MARK: - Record factory

    @Test
    func factorySessionStarted() {
        let record = InspectorRecordFactory(namespace: "ns")
            .sessionStarted(timestamp: "2026-07-31T00:00:00Z", brokerHost: "localhost", brokerPort: 1883)
        #expect(record.kind == .sessionStarted)
        #expect(record.namespace == "ns")
    }

    @Test
    func factorySessionEnded() {
        let record = InspectorRecordFactory(namespace: "ns")
            .sessionEnded(timestamp: "2026-07-31T00:00:00Z")
        #expect(record.kind == .sessionEnded)
        #expect(record.namespace == "ns")
    }

    @Test
    func factoryError() {
        let record = InspectorRecordFactory(namespace: "ns")
            .error(timestamp: "2026-07-31T00:00:00Z", message: "test error")
        #expect(record.kind == .error)
        #expect(record.error == "test error")
    }
}
