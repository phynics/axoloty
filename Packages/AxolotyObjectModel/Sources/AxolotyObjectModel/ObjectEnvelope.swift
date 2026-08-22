// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyWire

/// The identity and protocol metadata common to a portable object.
///
/// The two const capacities are part of the type so an application chooses
/// and audits its metadata bounds instead of inheriting an unmeasured global
/// preset. Instantiate this type with the application's measured capacities.
public struct ObjectEnvelope<let nameCapacity: Int, let externalIDCapacity: Int>: Sendable, Equatable {
    /// The object's stable identifier.
    public let objectID: ObjectID
    /// The object's schema/type identifier.
    public let objectType: ObjectType
    /// The required human-readable object name.
    public let name: BoundedEncodedText<nameCapacity>
    /// The object's Coaty core family.
    public let coreType: ObjectCoreType
    /// Optional external identifier.
    public let externalID: BoundedEncodedText<externalIDCapacity>?
    /// Optional parent object identifier.
    public let parentObjectID: ObjectID?
    /// Optional location object identifier.
    public let locationID: ObjectID?
    /// Whether the object is deactivated.
    public let isDeactivated: Bool

    /// Creates an envelope from its portable identity components.
    public init(
        objectID: ObjectID,
        objectType: ObjectType,
        name: BoundedEncodedText<nameCapacity>,
        coreType: ObjectCoreType,
        externalID: BoundedEncodedText<externalIDCapacity>? = nil,
        parentObjectID: ObjectID? = nil,
        locationID: ObjectID? = nil,
        isDeactivated: Bool = false
    ) {
        self.objectID = objectID; self.objectType = objectType; self.name = name; self.coreType = coreType
        self.externalID = externalID; self.parentObjectID = parentObjectID; self.locationID = locationID; self.isDeactivated = isDeactivated
    }

    /// Decodes the standard envelope members from one complete JSON object.
    public init(decoding bytes: ByteSlice) throws(ObjectError) {
        var decodedID: ObjectID?
        var decodedType: ObjectType?
        var decodedName: BoundedEncodedText<nameCapacity>?
        var decodedCore: ObjectCoreType?
        var decodedExternal: BoundedEncodedText<externalIDCapacity>?
        var decodedParent: ObjectID?
        var decodedLocation: ObjectID?
        var decodedDeactivated = false
        var failure = false
        bytes.withBytes { pointer, count in
            let reader = WireReader(bytes: pointer.assumingMemoryBound(to: UInt8.self), length: count)
            do { try reader.validate() } catch { failure = true; return }
            guard let idSlice = reader.readString("objectId"), let objectID = ObjectID(bytes: idSlice),
                  let typeSlice = reader.readString("objectType"), let objectType = ObjectType(bytes: typeSlice),
                  let nameSlice = reader.readString("name"), let name = BoundedEncodedText<nameCapacity>(bytes: nameSlice),
                  let coreSlice = reader.readString("coreType"), let core = ObjectCoreType(bytes: coreSlice)
            else { failure = true; return }
            decodedID = objectID; decodedType = objectType; decodedName = name; decodedCore = core
            if let field = reader.readField("externalId"), !isJSONNull(field) {
                guard let value = reader.readString("externalId"), let bounded = BoundedEncodedText<externalIDCapacity>(bytes: value) else { failure = true; return }
                decodedExternal = bounded
            }
            if let field = reader.readField("parentObjectId"), !isJSONNull(field) {
                guard let value = reader.readString("parentObjectId"), let bounded = ObjectID(bytes: value) else { failure = true; return }
                decodedParent = bounded
            }
            if let field = reader.readField("locationId"), !isJSONNull(field) {
                guard let value = reader.readString("locationId"), let bounded = ObjectID(bytes: value) else { failure = true; return }
                decodedLocation = bounded
            }
            if let field = reader.readField("isDeactivated"), !isJSONNull(field) {
                guard let value = reader.readBool("isDeactivated") else { failure = true; return }
                decodedDeactivated = value
            }
        }
        guard !failure, let objectID = decodedID, let objectType = decodedType, let name = decodedName, let coreType = decodedCore else { throw ObjectError(.invalidEnvelope) }
        self.init(objectID: objectID, objectType: objectType, name: name, coreType: coreType, externalID: decodedExternal, parentObjectID: decodedParent, locationID: decodedLocation, isDeactivated: decodedDeactivated)
    }
}

private func isJSONNull(_ value: ByteSlice) -> Bool { value.length == 4 && value.equals("null") }

@usableFromInline
func validateObjectIdentity(
    decoding bytes: ByteSlice,
    objectType expectedObjectType: ObjectType,
    coreType expectedCoreType: ObjectCoreType
) throws(ObjectError) {
    var matches = false
    bytes.withBytes { pointer, count in
        let reader = WireReader(bytes: pointer.assumingMemoryBound(to: UInt8.self), length: count)
        do { try reader.validate() } catch { return }
        guard let idBytes = reader.readString("objectId"), ObjectID(bytes: idBytes) != nil,
              let nameBytes = reader.readString("name"), nameBytes.length > 0,
              let typeBytes = reader.readString("objectType"),
              let coreBytes = reader.readString("coreType"),
              let objectType = ObjectType(bytes: typeBytes),
              let coreType = ObjectCoreType(bytes: coreBytes) else { return }
        if let external = reader.readField("externalId"), !isJSONNull(external), reader.readString("externalId") == nil { return }
        if let parent = reader.readField("parentObjectId"), !isJSONNull(parent), reader.readUUID("parentObjectId") == nil { return }
        if let location = reader.readField("locationId"), !isJSONNull(location), reader.readUUID("locationId") == nil { return }
        if let deactivated = reader.readField("isDeactivated"), !isJSONNull(deactivated), reader.readBool("isDeactivated") == nil { return }
        matches = objectType == expectedObjectType && coreType == expectedCoreType
    }
    guard matches else { throw ObjectError(.invalidEnvelope) }
}
