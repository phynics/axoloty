// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// Formats ``InspectorRecord`` values as NDJSON lines (one self-contained
/// JSON object per line).
public struct NDJSONFormatter: Sendable {
    /// Creates a formatter.
    public init() {}

    /// Encodes a record as a single-line JSON string.
    ///
    /// - Throws: A `EncodingError` if the record cannot be encoded.
    public func format(_ record: InspectorRecord) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(record)
        return String(decoding: data, as: UTF8.self)
    }
}

/// Formats ``InspectorRecord`` values as concise human-readable lines
/// suitable for terminal output.
public struct HumanFormatter: Sendable {
    /// Creates a formatter.
    public init() {}

    /// Formats a record as a single human-readable line.
    public func format(_ record: InspectorRecord) -> String {
        switch record.kind {
        case .sessionStarted:
            return formatSessionStarted(record)
        case .advertise:
            return formatAdvertise(record, verb: "ADD")
        case .objectUpdated:
            return formatAdvertise(record, verb: "UPDATE")
        case .deadvertise:
            return formatDeadvertise(record)
        case .sessionEnded:
            return "DISCONNECTED"
        case .error:
            return "ERROR      \(record.error ?? "")"
        case .discoveryResult:
            return formatDiscoveryResult(record)
        }
    }

    private func formatSessionStarted(_ record: InspectorRecord) -> String {
        let ns = record.namespace ?? "-"
        return "CONNECTED  namespace=\(ns)"
    }

    private func formatAdvertise(_ record: InspectorRecord, verb: String) -> String {
        let coreType = record.coreType ?? "Unknown"
        let name = record.name ?? ""
        let objectId = truncateId(record.objectId)
        let privateData = record.privateData.map { " privateData=\($0)" } ?? ""
        return "\(pad(verb, width: 10)) \(pad(coreType, width: 12)) \(pad(name, width: 16)) \(objectId)\(privateData)"
    }

    private func formatDeadvertise(_ record: InspectorRecord) -> String {
        if let ids = record.removedObjectIds {
            let idStr = ids.map { truncateId($0) }.joined(separator: " ")
            return "\(pad("REMOVE", width: 10)) \(idStr)"
        }
        let objectId = truncateId(record.objectId)
        let coreType = record.coreType ?? ""
        return "\(pad("REMOVE", width: 10)) \(pad(coreType, width: 12)) \(objectId)"
    }

    private func formatDiscoveryResult(_ record: InspectorRecord) -> String {
        let count = record.objects?.count ?? 0
        let timed = record.timedOut == true ? " (timed out)" : ""
        return "DISCOVERY  \(count) object\(count == 1 ? "" : "s")\(timed)"
    }

    private func pad(_ s: String, width: Int) -> String {
        if s.count >= width { return s }
        return s + String(repeating: " ", count: width - s.count)
    }

    private func truncateId(_ id: String?) -> String {
        guard let id, !id.isEmpty else { return "" }
        if id.count <= 8 { return id }
        let prefix = id.prefix(4)
        let suffix = id.suffix(4)
        return "\(prefix)…\(suffix)"
    }
}

/// Creates ``InspectorRecord`` values from ``ObjectCatalogueMutation`` values
/// and session lifecycle events.
public struct InspectorRecordFactory: Sendable {
    /// The namespace being observed.
    public let namespace: String
    /// Whether to include the raw JSON payload in records.
    public let includePayload: Bool
    /// Whether to include private data in records when the full payload is included.
    public let includePrivateData: Bool

    /// Creates a factory.
    public init(namespace: String, includePayload: Bool = false, includePrivateData: Bool = false) {
        self.namespace = namespace
        self.includePayload = includePayload
        self.includePrivateData = includePrivateData
    }

    private func payload(from object: InspectorObject) -> String? {
        includePayload ? object.payload : nil
    }

    private func privateData(from object: InspectorObject) -> String? {
        includePayload && includePrivateData ? object.privateData : nil
    }

    /// Creates a record for a catalogue mutation, or `nil` if the mutation
    /// should not produce output (`.unchanged` or `.removalOfUnknownObject`
    /// in non-verbose mode).
    public func record(
        for mutation: ObjectCatalogueMutation,
        timestamp: String,
        verbose: Bool = false
    ) -> InspectorRecord? {
        switch mutation {
        case let .inserted(object):
            return InspectorRecord(
                kind: .advertise,
                timestamp: timestamp,
                namespace: namespace,
                sourceId: object.sourceId,
                objectId: object.objectId,
                coreType: object.coreType,
                objectType: object.objectType,
                name: object.name,
                payload: payload(from: object),
                privateData: privateData(from: object)
            )
        case let .updated(_, current):
            return InspectorRecord(
                kind: .objectUpdated,
                timestamp: timestamp,
                namespace: namespace,
                sourceId: current.sourceId,
                objectId: current.objectId,
                coreType: current.coreType,
                objectType: current.objectType,
                name: current.name,
                payload: payload(from: current),
                privateData: privateData(from: current)
            )
        case .unchanged:
            return nil
        case let .removed(object):
            return InspectorRecord(
                kind: .deadvertise,
                timestamp: timestamp,
                namespace: namespace,
                sourceId: object.sourceId,
                objectId: object.objectId,
                coreType: object.coreType,
                objectType: object.objectType,
                name: object.name
            )
        case let .removalOfUnknownObject(objectId):
            guard verbose else { return nil }
            return InspectorRecord(
                kind: .deadvertise,
                timestamp: timestamp,
                namespace: namespace,
                removedObjectIds: [objectId]
            )
        }
    }

    /// Creates a session-started record.
    public func sessionStarted(timestamp: String, brokerHost: String, brokerPort: UInt16) -> InspectorRecord {
        InspectorRecord(
            kind: .sessionStarted,
            timestamp: timestamp,
            namespace: namespace
        )
    }

    /// Creates a session-ended record.
    public func sessionEnded(timestamp: String) -> InspectorRecord {
        InspectorRecord(
            kind: .sessionEnded,
            timestamp: timestamp,
            namespace: namespace
        )
    }

    /// Creates an error record.
    public func error(timestamp: String, message: String) -> InspectorRecord {
        InspectorRecord(
            kind: .error,
            timestamp: timestamp,
            namespace: namespace,
            error: message
        )
    }
}
