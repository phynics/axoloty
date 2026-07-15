// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// A value-typed snapshot of a `CoatyObject` suitable for concurrent event streams.
public struct CoatyObjectSnapshot: EventSnapshot, Codable, Equatable, Sendable {

    /// The unique identifier of the object.
    public let objectId: String

    /// The core type of the object, as transmitted on the wire.
    public let coreType: String

    /// The concrete application-specific type of the object.
    public let objectType: String

    /// The human-readable name of the object.
    public let name: String

    /// An external identifier associated with the object, if available.
    public let externalId: String?

    /// The identifier of the parent or superordinate object, if available.
    public let parentObjectId: String?

    /// The identifier of the associated location object, if available.
    public let locationId: String?

    /// Indicates whether the object has been marked as deactivated.
    public let isDeactivated: Bool?

    /// The raw wire payload of the object, preserving any custom or application-specific
    /// fields that are not captured in the typed properties above.
    public let payload: Data?

    /// Creates a snapshot from the typed fields of a Coaty object.
    ///
    /// - Parameters:
    ///   - objectId: The unique object identifier.
    ///   - coreType: The core type of the object.
    ///   - objectType: The concrete object type.
    ///   - name: The human-readable name.
    ///   - externalId: An optional external identifier.
    ///   - parentObjectId: An optional parent object identifier.
    ///   - locationId: An optional location object identifier.
    ///   - isDeactivated: An optional deactivation flag.
    ///   - payload: An optional wire payload for the full encoded object.
    public init(
        objectId: String,
        coreType: String,
        objectType: String,
        name: String,
        externalId: String? = nil,
        parentObjectId: String? = nil,
        locationId: String? = nil,
        isDeactivated: Bool? = nil,
        payload: Data? = nil
    ) {
        self.objectId = objectId
        self.coreType = coreType
        self.objectType = objectType
        self.name = name
        self.externalId = externalId
        self.parentObjectId = parentObjectId
        self.locationId = locationId
        self.isDeactivated = isDeactivated
        self.payload = payload
    }
}
