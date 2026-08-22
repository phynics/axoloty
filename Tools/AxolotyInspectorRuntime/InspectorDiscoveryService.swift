// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyInspectorCore
import Foundation

private struct ResolveResponsePayload: Decodable {
    let object: InspectorObjectPayload?
    let relatedObjects: [InspectorObjectPayload]?
}

/// Decodes all objects carried by a Resolve response.
public enum InspectorResolveObjectDecoder {
    /// Creates inspector objects from the primary and related objects in a
    /// Resolve response.
    ///
    /// Resolve responses may contain only a primary object, only related
    /// objects, or both. A malformed or otherwise undecodable response
    /// returns `nil`; a valid response with no objects returns an empty array.
    ///
    /// - Parameter response: The correlated Resolve response snapshot.
    /// - Returns: Every decoded object in wire order, or `nil` when the
    ///   response payload cannot be decoded.
    public static func objects(from response: InspectorResponseEvent) -> [InspectorObject]? {
        guard let payload = response.decodePayload(ResolveResponsePayload.self) else {
            return nil
        }

        let snapshots = [payload.object].compactMap { $0 } + (payload.relatedObjects ?? [])
        return snapshots.map { object in
            InspectorObject(
                objectId: object.objectId,
                coreType: object.coreType.rawValue,
                objectType: object.objectType,
                name: object.name.isEmpty ? nil : object.name,
                sourceId: response.sourceId
            )
        }
    }
}

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
    /// ``InspectorCoreType`` values. When multiple selectors are supplied, the
    /// existing precedence is preserved: object ID, object type, then core
    /// type.
    ///
    /// - Returns: The event to publish for this request.
    /// - Throws: ``InspectorError/invalidArguments(reason:)`` when a typed
    ///   selector is malformed or unknown.
    public func makeInspectorDiscoverRequest(
        timeout: InspectorDuration = InspectorDuration(value: .seconds(5))
    ) throws(InspectorError) -> InspectorDiscoverRequest {
        guard hasSelector else {
            throw InspectorError.invalidArguments(
                reason: "at least one selector (coreType, objectType, or objectId) is required"
            )
        }

        let uuid: String?
        if let objectId {
            guard UUID(uuidString: objectId) != nil else {
                throw InspectorError.invalidArguments(
                    reason: "objectId must be a valid UUID: \(objectId)"
                )
            }
            uuid = objectId
        } else {
            uuid = nil
        }

        let parsedInspectorCoreType: InspectorCoreType?
        if let coreType {
            let parsed = InspectorCoreType(rawValue: coreType)
            guard [InspectorCoreType.Identity, .Sensor, .Task, .Node, .Device].contains(parsed) else {
                throw InspectorError.invalidArguments(
                    reason: "coreType must be a known core type: \(coreType)"
                )
            }
            parsedInspectorCoreType = parsed
        } else {
            parsedInspectorCoreType = nil
        }

        var fields: [String: Any] = [:]
        if let uuid {
            fields["objectId"] = uuid
        } else if let objectType {
            fields["objectTypes"] = [objectType]
        } else if let parsedInspectorCoreType {
            fields["coreTypes"] = [parsedInspectorCoreType.rawValue]
        } else {
            throw InspectorError.invalidArguments(reason: "discovery selector could not be represented")
        }
        guard JSONSerialization.isValidJSONObject(fields),
              let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]) else {
            throw InspectorError.invalidArguments(reason: "discovery selector could not be encoded")
        }
        return InspectorDiscoverRequest(
            payload: Array(data),
            data: InspectorDiscoverRequest.Data(
                objectId: uuid.map(InspectorDiscoverRequest.InspectorObjectIdentifier.init(string:)),
                objectTypes: uuid == nil ? objectType.map { [$0] } : nil,
                coreTypes: uuid == nil && objectType == nil ? parsedInspectorCoreType.map { [$0.rawValue] } : nil
            ),
            responseTimeout: timeout.value
        )
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
