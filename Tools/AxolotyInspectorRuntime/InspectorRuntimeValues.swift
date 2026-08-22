// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

import AxolotyWire

/// Transport lifecycle observed by inspector consumers.
public enum InspectorTransportState: String, Codable, Sendable, Equatable {
    /// The binding is connected and accepting protocol work.
    case online
    /// The binding is not connected.
    case offline
}

/// The bounded set of core object labels accepted by inspector filters.
public struct InspectorCoreType: RawRepresentable, Codable, Sendable, Equatable, Hashable {
    /// The wire label, including labels unknown to this inspector build.
    public let rawValue: String

    /// Creates a core type label without rejecting future peer values.
    public init(rawValue: String) { self.rawValue = rawValue }

    /// Coaty identity object.
    public static let Identity = Self(rawValue: "Identity")
    /// Sensor object.
    public static let Sensor = Self(rawValue: "Sensor")
    /// Task object.
    public static let Task = Self(rawValue: "Task")
    /// Generic Coaty node.
    public static let Node = Self(rawValue: "Node")
    /// Generic Coaty device.
    public static let Device = Self(rawValue: "Device")
}

/// Dynamic object payload decoded at the inspector boundary.
public struct InspectorObjectPayload: Codable, Equatable, Sendable {
    /// Object identifier as encoded by the peer.
    public let objectId: String
    /// Core object category.
    public let coreType: InspectorCoreType
    /// Application object type.
    public let objectType: String
    /// Human-readable object name.
    public let name: String
    /// Optional opaque object JSON retained for full output.
    public let payload: String?

    /// Creates a dynamic object payload.
    public init(
        objectId: String,
        coreType: InspectorCoreType,
        objectType: String,
        name: String,
        externalId: String? = nil,
        parentObjectId: String? = nil,
        locationId: String? = nil,
        isDeactivated: Bool? = nil,
        payload: String? = nil
    ) {
        self.objectId = objectId
        self.coreType = coreType
        self.objectType = objectType
        self.name = name
        self.payload = payload
    }

    /// Decodes the retained payload into an inspector-owned value.
    public func decodePayload<T: Decodable>(_ type: T.Type) -> T? {
        guard let payload else { return nil }
        return try? JSONDecoder().decode(T.self, from: Data(payload.utf8))
    }
}

/// An owned Advertise event delivered to inspector consumers.
public struct InspectorAdvertiseEvent: Codable, Equatable, Sendable {
    /// Source identity copied from the protocol context.
    public let sourceId: String?
    /// Optional event filter.
    public let eventTypeFilter: String?
    /// Advertised dynamic object.
    public let object: InspectorObjectPayload
    /// Optional private data retained as JSON text.
    public let privateData: String?

    /// Creates an Advertise event.
    public init(
        sourceId: String? = nil,
        eventTypeFilter: String? = nil,
        object: InspectorObjectPayload,
        privateData: String? = nil
    ) {
        self.sourceId = sourceId
        self.eventTypeFilter = eventTypeFilter
        self.object = object
        self.privateData = privateData
    }
}

/// An owned Deadvertise event delivered to inspector consumers.
public struct InspectorDeadvertiseEvent: Codable, Equatable, Sendable {
    /// Source identity copied from the protocol context.
    public let sourceId: String?
    /// Object identifiers removed by the event.
    public let objectIds: [String]

    /// Creates a Deadvertise event.
    public init(sourceId: String? = nil, objectIds: [String]) {
        self.sourceId = sourceId
        self.objectIds = objectIds
    }
}

/// An owned correlated response used by inspector discovery and MCP.
public struct InspectorResponseEvent: Codable, Equatable, Sendable {
    /// Wire family name.
    public let eventType: String
    /// Source identity copied from the protocol context.
    public let sourceId: String?
    /// Correlation identity copied from the protocol context.
    public let correlationId: String?
    /// Raw JSON payload retained for family decoding.
    public let payload: String
    /// Optional decoded primary object.
    public let object: InspectorObjectPayload?

    /// Creates a response event.
    public init(eventType: String, sourceId: String?, correlationId: String?, payload: String, object: InspectorObjectPayload? = nil) {
        self.eventType = eventType
        self.sourceId = sourceId
        self.correlationId = correlationId
        self.payload = payload
        self.object = object
    }

    /// Decodes the response payload into a family-specific value.
    public func decodePayload<T: Decodable>(_ type: T.Type) -> T? {
        try? JSONDecoder().decode(T.self, from: Data(payload.utf8))
    }
}

/// A validated discovery operation handed to the shared runtime processor.
public struct InspectorDiscoverRequest: Sendable, Equatable {
    /// Structured selectors retained for inspector tests and diagnostics.
    public struct Data: Sendable, Equatable {
        /// Object UUID selector, when supplied.
        public let objectId: InspectorObjectIdentifier?
        /// Object-type selectors, when supplied.
        public let objectTypes: [String]?
        /// Core-type selectors, when supplied.
        public let coreTypes: [String]?

        /// Creates the structured selector view.
        public init(
            objectId: InspectorObjectIdentifier?,
            objectTypes: [String]?,
            coreTypes: [String]?
        ) {
            self.objectId = objectId
            self.objectTypes = objectTypes
            self.coreTypes = coreTypes
        }
    }

    /// Foundation-free object identifier view.
    public struct InspectorObjectIdentifier: Sendable, Equatable {
        /// Canonical UUID text.
        public let string: String
    }

    /// Encoded Discover family payload.
    public let payload: [UInt8]
    /// Structured selector view.
    public let data: Data

    /// Creates a request from an already validated family payload.
    public init(payload: [UInt8], data: Data = Data(objectId: nil, objectTypes: nil, coreTypes: nil)) {
        self.payload = payload
        self.data = data
    }
}
