// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// An inspector-owned, immutable representation of a Coaty object observed
/// through Advertise events.
///
/// Created at the runtime boundary by converting ``AdvertiseEventSnapshot``
/// values. The ``payload`` field is populated only when the operator
/// explicitly requests it via `--full`; ``privateData`` is populated only
/// when both `--full` and `--include-private-data` are requested.
public struct InspectorObject: Codable, Equatable, Sendable {
    /// The Coaty object UUID as a string.
    public let objectId: String
    /// The core type name (e.g. `"Identity"`, `"Sensor"`).
    public let coreType: String
    /// The full object type string.
    public let objectType: String
    /// The display name, if provided.
    public let name: String?
    /// The UUID of the advertising source, if known.
    public let sourceId: String?
    /// The complete raw JSON object payload, included only with `--full`.
    public let payload: String?
    /// Private data, included only when both `--full` and
    /// `--include-private-data` are enabled.
    public let privateData: String?

    /// Creates an inspector object.
    public init(
        objectId: String,
        coreType: String,
        objectType: String,
        name: String? = nil,
        sourceId: String? = nil,
        payload: String? = nil,
        privateData: String? = nil
    ) {
        self.objectId = objectId
        self.coreType = coreType
        self.objectType = objectType
        self.name = name
        self.sourceId = sourceId
        self.payload = payload
        self.privateData = privateData
    }
}

/// The immutable catalogue state mapping object IDs to their latest known
/// inspector objects.
public struct ObjectCatalogue: Equatable, Sendable {
    /// The current objects keyed by object ID.
    public internal(set) var objectsById: [String: InspectorObject]

    /// Creates an empty catalogue.
    public init() {
        self.objectsById = [:]
    }

    /// Creates a catalogue from an existing object map.
    public init(objectsById: [String: InspectorObject]) {
        self.objectsById = objectsById
    }
}

/// The result of processing an Advertise or Deadvertise event against the
/// catalogue.
public enum ObjectCatalogueMutation: Equatable, Sendable {
    /// A new object was inserted into the catalogue.
    case inserted(InspectorObject)
    /// An existing object's logical contents changed.
    case updated(previous: InspectorObject, current: InspectorObject)
    /// The event did not change the catalogue (duplicate advertisement).
    case unchanged(InspectorObject)
    /// An existing object was removed from the catalogue.
    case removed(InspectorObject)
    /// A Deadvertise referenced an object ID not in the catalogue.
    case removalOfUnknownObject(objectId: String)
}
