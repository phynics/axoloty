// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import AxolotyInspectorCore
import Foundation

/// A request for active object discovery.
public struct InspectorDiscoveryRequest: Sendable, Equatable {
    /// Filter by core type name, if specified.
    public let coreType: String?
    /// Filter by full object type, if specified.
    public let objectType: String?
    /// Filter by object UUID, if specified.
    public let objectId: String?
    /// Maximum time to wait for responses, in milliseconds.
    public let timeoutMilliseconds: Int

    /// Creates a discovery request.
    public init(coreType: String? = nil, objectType: String? = nil, objectId: String? = nil, timeoutMilliseconds: Int = 5000) {
        self.coreType = coreType
        self.objectType = objectType
        self.objectId = objectId
        self.timeoutMilliseconds = timeoutMilliseconds
    }

    /// Whether at least one selector is provided.
    public var hasSelector: Bool {
        coreType != nil || objectType != nil || objectId != nil
    }

    /// Builds the Coaty Discover event after validating its typed selectors.
    ///
    /// Object IDs must be valid Coaty UUIDs and core types must be known
    /// ``CoreType`` values. When multiple selectors are supplied, the
    /// existing precedence is preserved: object ID, object type, then core
    /// type.
    ///
    /// - Returns: The event to publish for this request.
    /// - Throws: ``InspectorError/invalidArguments(reason:)`` when a typed
    ///   selector is malformed or unknown.
    public func makeDiscoverEvent() throws(InspectorError) -> DiscoverEvent {
        guard hasSelector else {
            throw InspectorError.invalidArguments(
                reason: "at least one selector (coreType, objectType, or objectId) is required"
            )
        }

        let uuid: CoatyUUID?
        if let objectId {
            guard let parsedUUID = CoatyUUID(uuidString: objectId) else {
                throw InspectorError.invalidArguments(
                    reason: "objectId must be a valid UUID: \(objectId)"
                )
            }
            uuid = parsedUUID
        } else {
            uuid = nil
        }

        let parsedCoreType: CoreType?
        if let coreType {
            guard let parsed = CoreType(rawValue: coreType) else {
                throw InspectorError.invalidArguments(
                    reason: "coreType must be a known core type: \(coreType)"
                )
            }
            parsedCoreType = parsed
        } else {
            parsedCoreType = nil
        }

        if let uuid {
            return DiscoverEvent.with(objectId: uuid)
        }
        if let objectType {
            return DiscoverEvent.with(objectTypes: [objectType])
        }
        if let parsedCoreType {
            return DiscoverEvent.with(coreTypes: [parsedCoreType])
        }
        throw InspectorError.invalidArguments(reason: "discovery selector could not be represented")
    }
}

/// The result of an active discovery operation.
public struct InspectorDiscoveryResult: Codable, Sendable, Equatable {
    /// Whether the discovery timed out before all expected responses arrived.
    public let timedOut: Bool
    /// The discovered objects, deduplicated by object ID.
    public let objects: [InspectorObject]

    /// Creates a discovery result.
    public init(timedOut: Bool, objects: [InspectorObject]) {
        self.timedOut = timedOut
        self.objects = objects
    }
}

/// Protocol for performing active discovery.
public protocol InspectorDiscovering: Sendable {
    /// Performs discovery for the objects matching the given request.
    ///
    /// - Parameter request: The discovery selectors and timeout.
    /// - Returns: The discovery result, including any matched objects and
    ///   whether the operation timed out.
    func discover(request: InspectorDiscoveryRequest) async throws -> InspectorDiscoveryResult
}
