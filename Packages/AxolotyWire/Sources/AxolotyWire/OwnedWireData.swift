// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

/// Owned Advertise payload fields.
public struct OwnedAdvertiseWireData: Sendable, Equatable {
    /// The advertised object as complete bytes in ``profile``'s encoding.
    public let object: [UInt8]
    /// Optional private data as complete bytes in ``profile``'s encoding.
    public let privateData: [UInt8]?
    /// The wire profile whose encoding the raw fields carry.
    public let profile: WireProfile

    init(unchecked object: [UInt8], privateData: [UInt8]?, profile: WireProfile) {
        self.object = object
        self.privateData = privateData
        self.profile = profile
    }

    /// Creates owned Advertise payload fields after validating raw `coaty/3` JSON.
    ///
    /// - Throws: ``WireDecodeError`` if a field is malformed or has the wrong
    ///   JSON shape.
    public init(object: [UInt8], privateData: [UInt8]?) throws(WireDecodeError) {
        try self.init(profile: .coaty3JSON, object: object, privateData: privateData)
    }

    /// Creates owned Advertise payload fields for one profile after validating.
    ///
    /// - Parameters:
    ///   - profile: The profile whose encoding the raw fields carry.
    ///   - object: The complete encoded object.
    ///   - privateData: Optional complete encoded private data.
    /// - Throws: ``WireDecodeError`` if a field is malformed or has the wrong
    ///   shape for `profile`.
    public init(profile: WireProfile, object: [UInt8], privateData: [UInt8]?) throws(WireDecodeError) {
        try validateOwnedValue(object, profile: profile, field: "object", shape: .object)
        try validateOptionalOwnedValue(privateData, profile: profile, field: "privateData", shape: .object)
        self.init(unchecked: object, privateData: privateData, profile: profile)
    }
}

/// Owned Deadvertise payload fields.
public struct OwnedDeadvertiseWireData: Sendable, Equatable {
    /// The deadvertised object identifiers as a complete array in ``profile``'s encoding.
    public let objectIds: [UInt8]
    /// The wire profile whose encoding the raw fields carry.
    public let profile: WireProfile

    init(unchecked objectIds: [UInt8], profile: WireProfile) {
        self.objectIds = objectIds
        self.profile = profile
    }

    /// Creates owned Deadvertise payload fields after validating raw `coaty/3` JSON.
    /// - Throws: ``WireDecodeError`` if `objectIds` is malformed or not an array.
    public init(objectIds: [UInt8]) throws(WireDecodeError) {
        try self.init(profile: .coaty3JSON, objectIds: objectIds)
    }

    /// Creates owned Deadvertise payload fields for one profile after validating.
    ///
    /// - Parameters:
    ///   - profile: The profile whose encoding the raw field carries.
    ///   - objectIds: The complete encoded array.
    /// - Throws: ``WireDecodeError`` if `objectIds` is malformed or not an array.
    public init(profile: WireProfile, objectIds: [UInt8]) throws(WireDecodeError) {
        try validateOwnedValue(objectIds, profile: profile, field: "objectIds", shape: .array)
        self.init(unchecked: objectIds, profile: profile)
    }
}

/// Owned Channel payload fields.
public struct OwnedChannelWireData: Sendable, Equatable {
    /// The optional single object as complete bytes in ``profile``'s encoding.
    public let object: [UInt8]?
    /// The optional object collection as complete bytes in ``profile``'s encoding.
    public let objects: [UInt8]?
    /// Optional private data as complete bytes in ``profile``'s encoding.
    public let privateData: [UInt8]?
    /// The wire profile whose encoding the raw fields carry.
    public let profile: WireProfile

    init(unchecked object: [UInt8]?, objects: [UInt8]?, privateData: [UInt8]?, profile: WireProfile) {
        self.object = object
        self.objects = objects
        self.privateData = privateData
        self.profile = profile
    }

    /// Creates owned Channel payload fields after validating raw `coaty/3` JSON.
    /// - Throws: ``WireDecodeError`` if a field is malformed or has the wrong shape.
    public init(object: [UInt8]?, objects: [UInt8]?, privateData: [UInt8]?) throws(WireDecodeError) {
        try self.init(profile: .coaty3JSON, object: object, objects: objects, privateData: privateData)
    }

    /// Creates owned Channel payload fields for one profile after validating.
    ///
    /// - Parameters:
    ///   - profile: The profile whose encoding the raw fields carry.
    ///   - object: Optional complete encoded object.
    ///   - objects: Optional complete encoded array.
    ///   - privateData: Optional complete encoded private data.
    /// - Throws: ``WireDecodeError`` if a field is malformed or has the wrong shape.
    public init(profile: WireProfile, object: [UInt8]?, objects: [UInt8]?, privateData: [UInt8]?) throws(WireDecodeError) {
        try validateOptionalOwnedValue(object, profile: profile, field: "object", shape: .object)
        try validateOptionalOwnedValue(objects, profile: profile, field: "objects", shape: .array)
        try validateOptionalOwnedValue(privateData, profile: profile, field: "privateData", shape: .object)
        self.init(unchecked: object, objects: objects, privateData: privateData, profile: profile)
    }
}

/// Owned Associate payload fields.
public struct OwnedAssociateWireData: Sendable, Equatable {
    /// The I/O source identifier.
    public let ioSourceId: UUID16
    /// The I/O actor identifier.
    public let ioActorId: UUID16
    /// Optional encoded string content for the route.
    public let associatingRoute: [UInt8]?
    /// Whether the association uses an external route.
    public let isExternalRoute: Bool?
    /// The optional update rate.
    public let updateRate: Int?
    /// The wire profile whose encoding the raw fields carry.
    public let profile: WireProfile

    init(unchecked ioSourceId: UUID16, ioActorId: UUID16, associatingRoute: [UInt8]?, isExternalRoute: Bool?, updateRate: Int?, profile: WireProfile) {
        self.ioSourceId = ioSourceId
        self.ioActorId = ioActorId
        self.associatingRoute = associatingRoute
        self.isExternalRoute = isExternalRoute
        self.updateRate = updateRate
        self.profile = profile
    }

    /// Creates owned Associate payload fields after validating encoded `coaty/3` string content.
    /// - Throws: ``WireDecodeError`` if the route has malformed string content.
    public init(ioSourceId: UUID16, ioActorId: UUID16, associatingRoute: [UInt8]?, isExternalRoute: Bool?, updateRate: Int?) throws(WireDecodeError) {
        try self.init(profile: .coaty3JSON, ioSourceId: ioSourceId, ioActorId: ioActorId, associatingRoute: associatingRoute, isExternalRoute: isExternalRoute, updateRate: updateRate)
    }

    /// Creates owned Associate payload fields for one profile after validating.
    ///
    /// - Parameters:
    ///   - profile: The profile whose encoding the raw field carries.
    ///   - ioSourceId: The I/O source identifier.
    ///   - ioActorId: The I/O actor identifier.
    ///   - associatingRoute: Optional encoded string content.
    ///   - isExternalRoute: Whether the association uses an external route.
    ///   - updateRate: The optional update rate.
    /// - Throws: ``WireDecodeError`` if the route has malformed string content.
    public init(profile: WireProfile, ioSourceId: UUID16, ioActorId: UUID16, associatingRoute: [UInt8]?, isExternalRoute: Bool?, updateRate: Int?) throws(WireDecodeError) {
        try validateOptionalOwnedValue(associatingRoute, profile: profile, field: "associatingRoute", shape: .textContent)
        self.init(unchecked: ioSourceId, ioActorId: ioActorId, associatingRoute: associatingRoute, isExternalRoute: isExternalRoute, updateRate: updateRate, profile: profile)
    }
}

/// Owned IoValue payload fields.
public struct OwnedIoValueWireData: Sendable, Equatable {
    /// The I/O value as complete bytes in ``profile``'s encoding.
    public let payload: [UInt8]
    /// The wire profile whose encoding the raw field carries.
    public let profile: WireProfile

    init(unchecked payload: [UInt8], profile: WireProfile) {
        self.payload = payload
        self.profile = profile
    }

    /// Creates owned IoValue payload fields after validating one complete `coaty/3` JSON value.
    /// - Throws: ``WireDecodeError`` if `payload` is malformed JSON.
    public init(payload: [UInt8]) throws(WireDecodeError) {
        try self.init(profile: .coaty3JSON, payload: payload)
    }

    /// Creates owned IoValue payload fields for one profile after validating.
    ///
    /// - Parameters:
    ///   - profile: The profile whose encoding the raw field carries.
    ///   - payload: One complete encoded value.
    /// - Throws: ``WireDecodeError`` if `payload` is malformed.
    public init(profile: WireProfile, payload: [UInt8]) throws(WireDecodeError) {
        try validateOwnedValue(payload, profile: profile, field: "payload")
        self.init(unchecked: payload, profile: profile)
    }
}

// MARK: - Typed axoloty/1 payload construction

extension OwnedIoValueWireData {
    /// Creates owned `axoloty/1` IoValue payload fields carrying one
    /// floating-point item.
    ///
    /// Floating point is an `axoloty/1`-only lexical kind and the native
    /// carrier for a fractional IO value. The payload is one bare CBOR item, so
    /// it round trips through ``IoValueWireData/floatPayload``.
    ///
    /// - Parameter value: The value to encode.
    /// - Throws: ``WireEncodeError/bufferOverflow`` if the item exceeds
    ///   ``WireBufferConfig/maxPayloadSize``.
    public init(cborFloat value: Double) throws(WireEncodeError) {
        self.init(
            unchecked: try Self.encodeCBORItem { (writer: inout WireWriter) throws(WireEncodeError) in
                try writer.writeFloat64(value)
            },
            profile: .axoloty1CBOR
        )
    }

    /// Creates owned `axoloty/1` IoValue payload fields carrying one byte
    /// string item.
    ///
    /// A byte string is the `axoloty/1` carrier for an opaque binary IO value.
    /// The payload is one bare CBOR item, so it round trips through
    /// ``IoValueWireData/byteStringPayload``.
    ///
    /// - Parameter bytes: The byte-string content, without an encoding head.
    /// - Throws: ``WireEncodeError/bufferOverflow`` if the item exceeds
    ///   ``WireBufferConfig/maxPayloadSize``.
    public init(cborByteString bytes: [UInt8]) throws(WireEncodeError) {
        let encoded = try bytes.withUnsafeBufferPointer { buffer throws(WireEncodeError) -> [UInt8] in
            let slice = buffer.baseAddress.map { ByteSlice(bytes: $0, length: buffer.count) } ?? .empty
            return try Self.encodeCBORItem { (writer: inout WireWriter) throws(WireEncodeError) in
                try writer.writeByteString(slice)
            }
        }
        self.init(unchecked: encoded, profile: .axoloty1CBOR)
    }

    /// Creates owned `axoloty/1` IoValue payload fields carrying one tagged
    /// item.
    ///
    /// A tag labels the item that follows it, such as epoch time (tag 1) or a
    /// UUID (tag 37). The payload is one bare CBOR item, so it round trips
    /// through ``IoValueWireData/tagPayload``.
    ///
    /// - Parameters:
    ///   - tag: The semantic-tag number.
    ///   - taggedItem: One complete encoded `axoloty/1` CBOR item for the tag
    ///     to label.
    /// - Throws: ``WireEncodeError/bufferOverflow`` if the item exceeds
    ///   ``WireBufferConfig/maxPayloadSize`` or ``WireEncodeError/invalidValue``
    ///   if `taggedItem` is not one complete CBOR item.
    public init(cborTag tag: UInt64, taggedItem: [UInt8]) throws(WireEncodeError) {
        let encoded = try taggedItem.withUnsafeBufferPointer { buffer throws(WireEncodeError) -> [UInt8] in
            let slice = buffer.baseAddress.map { ByteSlice(bytes: $0, length: buffer.count) } ?? .empty
            return try Self.encodeCBORItem { (writer: inout WireWriter) throws(WireEncodeError) in
                try writer.writeTag(tag)
                try writer.writeRawValue(slice)
            }
        }
        self.init(unchecked: encoded, profile: .axoloty1CBOR)
    }

    /// Encodes one bare `axoloty/1` CBOR item into a new, exactly sized byte
    /// array through the shared wire facade.
    private static func encodeCBORItem(
        _ body: (inout WireWriter) throws(WireEncodeError) -> Void
    ) throws(WireEncodeError) -> [UInt8] {
        var output = [UInt8](repeating: 0, count: WireBufferConfig.maxPayloadSize)
        var result: Result<Int, WireEncodeError> = .failure(.bufferOverflow)
        output.withUnsafeMutableBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            var writer = WireCodec(profile: .axoloty1CBOR).writer(
                buffer: baseAddress, capacity: buffer.count
            )
            do throws(WireEncodeError) {
                try body(&writer)
                result = .success(writer.position)
            } catch {
                result = .failure(error)
            }
        }
        let length = try result.get()
        output.removeSubrange(length..<output.count)
        return output
    }
}

/// Owned Discover payload fields.
public struct OwnedDiscoverWireData: Sendable, Equatable {
    /// Optional encoded string content for the external identifier.
    public let externalId: [UInt8]?
    /// Optional encoded string content for the object identifier.
    public let objectId: [UInt8]?
    /// Optional object types as a complete array in ``profile``'s encoding.
    public let objectTypes: [UInt8]?
    /// Optional core types as a complete array in ``profile``'s encoding.
    public let coreTypes: [UInt8]?
    /// The wire profile whose encoding the raw fields carry.
    public let profile: WireProfile

    init(unchecked externalId: [UInt8]?, objectId: [UInt8]?, objectTypes: [UInt8]?, coreTypes: [UInt8]?, profile: WireProfile) {
        self.externalId = externalId
        self.objectId = objectId
        self.objectTypes = objectTypes
        self.coreTypes = coreTypes
        self.profile = profile
    }

    /// Creates owned Discover payload fields after validating raw `coaty/3` JSON.
    /// - Throws: ``WireDecodeError`` if a field is malformed or has the wrong shape.
    public init(externalId: [UInt8]?, objectId: [UInt8]?, objectTypes: [UInt8]?, coreTypes: [UInt8]?) throws(WireDecodeError) {
        try self.init(profile: .coaty3JSON, externalId: externalId, objectId: objectId, objectTypes: objectTypes, coreTypes: coreTypes)
    }

    /// Creates owned Discover payload fields for one profile after validating.
    ///
    /// - Parameters:
    ///   - profile: The profile whose encoding the raw fields carry.
    ///   - externalId: Optional encoded string content.
    ///   - objectId: Optional encoded string content.
    ///   - objectTypes: Optional complete encoded array.
    ///   - coreTypes: Optional complete encoded array.
    /// - Throws: ``WireDecodeError`` if a field is malformed or has the wrong shape.
    public init(profile: WireProfile, externalId: [UInt8]?, objectId: [UInt8]?, objectTypes: [UInt8]?, coreTypes: [UInt8]?) throws(WireDecodeError) {
        try validateOptionalOwnedValue(externalId, profile: profile, field: "externalId", shape: .textContent)
        try validateOptionalOwnedValue(objectId, profile: profile, field: "objectId", shape: .textContent)
        try validateOptionalOwnedValue(objectTypes, profile: profile, field: "objectTypes", shape: .array)
        try validateOptionalOwnedValue(coreTypes, profile: profile, field: "coreTypes", shape: .array)
        self.init(unchecked: externalId, objectId: objectId, objectTypes: objectTypes, coreTypes: coreTypes, profile: profile)
    }
}

/// Owned Resolve payload fields.
public struct OwnedResolveWireData: Sendable, Equatable {
    /// The resolved object as a complete object in ``profile``'s encoding.
    public let object: [UInt8]
    /// Optional related objects as a complete array in ``profile``'s encoding.
    public let relatedObjects: [UInt8]?
    /// Optional private data as a complete object in ``profile``'s encoding.
    public let privateData: [UInt8]?
    /// The wire profile whose encoding the raw fields carry.
    public let profile: WireProfile

    init(unchecked object: [UInt8], relatedObjects: [UInt8]?, privateData: [UInt8]?, profile: WireProfile) {
        self.object = object
        self.relatedObjects = relatedObjects
        self.privateData = privateData
        self.profile = profile
    }

    /// Creates owned Resolve payload fields after validating raw `coaty/3` JSON.
    /// - Throws: ``WireDecodeError`` if a field is malformed or has the wrong shape.
    public init(object: [UInt8], relatedObjects: [UInt8]?, privateData: [UInt8]?) throws(WireDecodeError) {
        try self.init(profile: .coaty3JSON, object: object, relatedObjects: relatedObjects, privateData: privateData)
    }

    /// Creates owned Resolve payload fields for one profile after validating.
    ///
    /// - Parameters:
    ///   - profile: The profile whose encoding the raw fields carry.
    ///   - object: The complete encoded object.
    ///   - relatedObjects: Optional complete encoded array.
    ///   - privateData: Optional complete encoded private data.
    /// - Throws: ``WireDecodeError`` if a field is malformed or has the wrong shape.
    public init(profile: WireProfile, object: [UInt8], relatedObjects: [UInt8]?, privateData: [UInt8]?) throws(WireDecodeError) {
        try validateOwnedValue(object, profile: profile, field: "object", shape: .object)
        try validateOptionalOwnedValue(relatedObjects, profile: profile, field: "relatedObjects", shape: .array)
        try validateOptionalOwnedValue(privateData, profile: profile, field: "privateData", shape: .object)
        self.init(unchecked: object, relatedObjects: relatedObjects, privateData: privateData, profile: profile)
    }
}

/// Owned Query payload fields.
public struct OwnedQueryWireData: Sendable, Equatable {
    /// Optional object types as a complete array in ``profile``'s encoding.
    public let objectTypes: [UInt8]?
    /// Optional core types as a complete array in ``profile``'s encoding.
    public let coreTypes: [UInt8]?
    /// Optional object filter as a complete object in ``profile``'s encoding.
    public let objectFilter: [UInt8]?
    /// Optional join conditions as an object or array in ``profile``'s encoding.
    public let objectJoinConditions: [UInt8]?
    /// The wire profile whose encoding the raw fields carry.
    public let profile: WireProfile

    init(unchecked objectTypes: [UInt8]?, coreTypes: [UInt8]?, objectFilter: [UInt8]?, objectJoinConditions: [UInt8]?, profile: WireProfile) {
        self.objectTypes = objectTypes
        self.coreTypes = coreTypes
        self.objectFilter = objectFilter
        self.objectJoinConditions = objectJoinConditions
        self.profile = profile
    }

    /// Creates owned Query payload fields after validating raw `coaty/3` JSON.
    /// - Throws: ``WireDecodeError`` if a field is malformed or has the wrong shape.
    public init(objectTypes: [UInt8]?, coreTypes: [UInt8]?, objectFilter: [UInt8]?, objectJoinConditions: [UInt8]?) throws(WireDecodeError) {
        try self.init(profile: .coaty3JSON, objectTypes: objectTypes, coreTypes: coreTypes, objectFilter: objectFilter, objectJoinConditions: objectJoinConditions)
    }

    /// Creates owned Query payload fields for one profile after validating.
    ///
    /// - Parameters:
    ///   - profile: The profile whose encoding the raw fields carry.
    ///   - objectTypes: Optional complete encoded array.
    ///   - coreTypes: Optional complete encoded array.
    ///   - objectFilter: Optional complete encoded object.
    ///   - objectJoinConditions: Optional complete encoded object or array.
    /// - Throws: ``WireDecodeError`` if a field is malformed or has the wrong shape.
    public init(profile: WireProfile, objectTypes: [UInt8]?, coreTypes: [UInt8]?, objectFilter: [UInt8]?, objectJoinConditions: [UInt8]?) throws(WireDecodeError) {
        try validateOptionalOwnedValue(objectTypes, profile: profile, field: "objectTypes", shape: .array)
        try validateOptionalOwnedValue(coreTypes, profile: profile, field: "coreTypes", shape: .array)
        try validateOptionalOwnedValue(objectFilter, profile: profile, field: "objectFilter", shape: .object)
        try validateOptionalOwnedValue(objectJoinConditions, profile: profile, field: "objectJoinConditions", shape: .objectOrArray)
        self.init(unchecked: objectTypes, coreTypes: coreTypes, objectFilter: objectFilter, objectJoinConditions: objectJoinConditions, profile: profile)
    }
}

/// Owned Retrieve payload fields.
public struct OwnedRetrieveWireData: Sendable, Equatable {
    /// The retrieved objects as a complete array in ``profile``'s encoding, or
    /// the legacy single-object compatibility form accepted by the wire decoder.
    public let objects: [UInt8]
    /// Optional private data as a complete object in ``profile``'s encoding.
    public let privateData: [UInt8]?
    /// The wire profile whose encoding the raw fields carry.
    public let profile: WireProfile

    init(unchecked objects: [UInt8], privateData: [UInt8]?, profile: WireProfile) {
        self.objects = objects
        self.privateData = privateData
        self.profile = profile
    }

    /// Creates owned Retrieve payload fields after validating raw `coaty/3` JSON.
    /// - Throws: ``WireDecodeError`` if a field is malformed or has the wrong shape.
    public init(objects: [UInt8], privateData: [UInt8]?) throws(WireDecodeError) {
        try self.init(profile: .coaty3JSON, objects: objects, privateData: privateData)
    }

    /// Creates owned Retrieve payload fields for one profile after validating.
    ///
    /// - Parameters:
    ///   - profile: The profile whose encoding the raw fields carry.
    ///   - objects: The complete encoded array or legacy single object.
    ///   - privateData: Optional complete encoded private data.
    /// - Throws: ``WireDecodeError`` if a field is malformed or has the wrong shape.
    public init(profile: WireProfile, objects: [UInt8], privateData: [UInt8]?) throws(WireDecodeError) {
        try validateOwnedValue(objects, profile: profile, field: "objects", shape: .objectOrArray)
        try validateOptionalOwnedValue(privateData, profile: profile, field: "privateData", shape: .object)
        self.init(unchecked: objects, privateData: privateData, profile: profile)
    }
}

/// Owned Update payload fields.
public struct OwnedUpdateWireData: Sendable, Equatable {
    /// The updated object as a complete object in ``profile``'s encoding.
    public let object: [UInt8]
    /// The wire profile whose encoding the raw field carries.
    public let profile: WireProfile

    init(unchecked object: [UInt8], profile: WireProfile) {
        self.object = object
        self.profile = profile
    }

    /// Creates owned Update payload fields after validating raw `coaty/3` JSON.
    /// - Throws: ``WireDecodeError`` if `object` is malformed or not an object.
    public init(object: [UInt8]) throws(WireDecodeError) {
        try self.init(profile: .coaty3JSON, object: object)
    }

    /// Creates owned Update payload fields for one profile after validating.
    ///
    /// - Parameters:
    ///   - profile: The profile whose encoding the raw field carries.
    ///   - object: The complete encoded object.
    /// - Throws: ``WireDecodeError`` if `object` is malformed or not an object.
    public init(profile: WireProfile, object: [UInt8]) throws(WireDecodeError) {
        try validateOwnedValue(object, profile: profile, field: "object", shape: .object)
        self.init(unchecked: object, profile: profile)
    }
}

/// Owned Complete payload fields.
public struct OwnedCompleteWireData: Sendable, Equatable {
    /// The optional completed object as a complete object in ``profile``'s encoding.
    public let object: [UInt8]?
    /// Optional private data as a complete object in ``profile``'s encoding.
    public let privateData: [UInt8]?
    /// The wire profile whose encoding the raw fields carry.
    public let profile: WireProfile

    init(unchecked object: [UInt8]?, privateData: [UInt8]?, profile: WireProfile) {
        self.object = object
        self.privateData = privateData
        self.profile = profile
    }

    /// Creates owned Complete payload fields after validating raw `coaty/3` JSON.
    /// - Throws: ``WireDecodeError`` if a field is malformed or has the wrong shape.
    public init(object: [UInt8]?, privateData: [UInt8]?) throws(WireDecodeError) {
        try self.init(profile: .coaty3JSON, object: object, privateData: privateData)
    }

    /// Creates owned Complete payload fields for one profile after validating.
    ///
    /// - Parameters:
    ///   - profile: The profile whose encoding the raw fields carry.
    ///   - object: Optional complete encoded object.
    ///   - privateData: Optional complete encoded private data.
    /// - Throws: ``WireDecodeError`` if a field is malformed or has the wrong shape.
    public init(profile: WireProfile, object: [UInt8]?, privateData: [UInt8]?) throws(WireDecodeError) {
        try validateOptionalOwnedValue(object, profile: profile, field: "object", shape: .object)
        try validateOptionalOwnedValue(privateData, profile: profile, field: "privateData", shape: .object)
        self.init(unchecked: object, privateData: privateData, profile: profile)
    }
}

/// Owned Call payload fields.
public struct OwnedCallWireData: Sendable, Equatable {
    /// Optional operation parameters as an object or array in ``profile``'s encoding.
    public let parameters: [UInt8]?
    /// Optional call filter as a complete object in ``profile``'s encoding.
    public let filter: [UInt8]?
    /// The wire profile whose encoding the raw fields carry.
    public let profile: WireProfile

    init(unchecked parameters: [UInt8]?, filter: [UInt8]?, profile: WireProfile) {
        self.parameters = parameters
        self.filter = filter
        self.profile = profile
    }

    /// Creates owned Call payload fields after validating raw `coaty/3` JSON.
    /// - Throws: ``WireDecodeError`` if a field is malformed or has the wrong shape.
    public init(parameters: [UInt8]?, filter: [UInt8]?) throws(WireDecodeError) {
        try self.init(profile: .coaty3JSON, parameters: parameters, filter: filter)
    }

    /// Creates owned Call payload fields for one profile after validating.
    ///
    /// - Parameters:
    ///   - profile: The profile whose encoding the raw fields carry.
    ///   - parameters: Optional complete encoded object or array.
    ///   - filter: Optional complete encoded object.
    /// - Throws: ``WireDecodeError`` if a field is malformed or has the wrong shape.
    public init(profile: WireProfile, parameters: [UInt8]?, filter: [UInt8]?) throws(WireDecodeError) {
        try validateOptionalOwnedValue(parameters, profile: profile, field: "parameters", shape: .objectOrArray)
        try validateOptionalOwnedValue(filter, profile: profile, field: "filter", shape: .object)
        self.init(unchecked: parameters, filter: filter, profile: profile)
    }
}

/// Owned Return payload fields.
public struct OwnedReturnWireData: Sendable, Equatable {
    /// Optional return result as complete bytes in ``profile``'s encoding.
    public let result: [UInt8]?
    /// Optional execution information as complete bytes in ``profile``'s encoding.
    public let executionInfo: [UInt8]?
    /// Optional remote error as a complete object in ``profile``'s encoding.
    public let error: [UInt8]?
    /// The wire profile whose encoding the raw fields carry.
    public let profile: WireProfile

    init(unchecked result: [UInt8]?, executionInfo: [UInt8]?, error: [UInt8]?, profile: WireProfile) {
        self.result = result
        self.executionInfo = executionInfo
        self.error = error
        self.profile = profile
    }

    /// Creates owned Return payload fields after validating raw `coaty/3` JSON.
    /// - Throws: ``WireDecodeError`` if a field is malformed or has the wrong shape.
    public init(result: [UInt8]?, executionInfo: [UInt8]?, error: [UInt8]?) throws(WireDecodeError) {
        try self.init(profile: .coaty3JSON, result: result, executionInfo: executionInfo, error: error)
    }

    /// Creates owned Return payload fields for one profile after validating.
    ///
    /// - Parameters:
    ///   - profile: The profile whose encoding the raw fields carry.
    ///   - result: Optional complete encoded result.
    ///   - executionInfo: Optional complete encoded execution information.
    ///   - error: Optional complete encoded remote error.
    /// - Throws: ``WireDecodeError`` if a field is malformed or has the wrong shape.
    public init(profile: WireProfile, result: [UInt8]?, executionInfo: [UInt8]?, error: [UInt8]?) throws(WireDecodeError) {
        try validateOptionalOwnedValue(result, profile: profile, field: "result")
        try validateOptionalOwnedValue(executionInfo, profile: profile, field: "executionInfo")
        try validateOptionalOwnedValue(error, profile: profile, field: "error", shape: .object)
        self.init(unchecked: result, executionInfo: executionInfo, error: error, profile: profile)
    }
}
