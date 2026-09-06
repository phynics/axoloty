// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// A single output record in the inspector's stable NDJSON schema.
///
/// Every line of NDJSON output is one ``InspectorRecord`` encoded with
/// `JSONEncoder` using sorted keys. Fields that are `nil` are omitted from
/// the JSON, so default records naturally exclude `payload` and
/// `privateData`.
public struct InspectorRecord: Codable, Equatable, Sendable {
    /// The schema version identifier, always `"axoloty.inspect/v1"`.
    public static let schemaVersion = "axoloty.inspect/v1"

    /// The record kind.
    public let schema: String
    /// The event kind.
    public let kind: Kind
    /// The ISO 8601 timestamp.
    public let timestamp: String
    /// The namespace being observed.
    public let namespace: String?
    /// The source (advertiser) UUID.
    public let sourceId: String?
    /// The object UUID.
    public let objectId: String?
    /// The core type name.
    public let coreType: String?
    /// The full object type.
    public let objectType: String?
    /// The display name.
    public let name: String?
    /// The raw JSON payload, included only with `--full`.
    public let payload: String?
    /// Private data, included only when both `--full` and
    /// `--include-private-data` are enabled.
    public let privateData: String?
    /// Object IDs removed by a Deadvertise event.
    public let removedObjectIds: [String]?
    /// Whether a discovery timed out (discovery-result kind only).
    public let timedOut: Bool?
    /// Discovered objects (discovery-result kind only).
    public let objects: [InspectorObject]?
    /// An error message (error kind only).
    public let error: String?

    /// The record kind.
    public enum Kind: String, Codable, Equatable, Sendable {
        case sessionStarted = "session-started"
        case advertise
        case objectUpdated = "object-updated"
        case deadvertise
        case sessionEnded = "session-ended"
        case error
        case discoveryResult = "discovery-result"
    }

    /// Creates a record.
    public init(
        kind: Kind,
        timestamp: String,
        namespace: String? = nil,
        sourceId: String? = nil,
        objectId: String? = nil,
        coreType: String? = nil,
        objectType: String? = nil,
        name: String? = nil,
        payload: String? = nil,
        privateData: String? = nil,
        removedObjectIds: [String]? = nil,
        timedOut: Bool? = nil,
        objects: [InspectorObject]? = nil,
        error: String? = nil
    ) {
        self.schema = Self.schemaVersion
        self.kind = kind
        self.timestamp = timestamp
        self.namespace = namespace
        self.sourceId = sourceId
        self.objectId = objectId
        self.coreType = coreType
        self.objectType = objectType
        self.name = name
        self.payload = payload
        self.privateData = privateData
        self.removedObjectIds = removedObjectIds
        self.timedOut = timedOut
        self.objects = objects
        self.error = error
    }
}
