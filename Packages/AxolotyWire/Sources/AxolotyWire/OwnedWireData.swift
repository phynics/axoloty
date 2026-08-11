// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

/// Owned Advertise payload fields.
public struct OwnedAdvertiseWireData: Sendable, Equatable {
    /// The advertised object as complete JSON bytes.
    public let object: [UInt8]
    /// Optional private data as complete JSON bytes.
    public let privateData: [UInt8]?

    init(unchecked object: [UInt8], privateData: [UInt8]?) {
        self.object = object
        self.privateData = privateData
    }

    /// Creates owned Advertise payload fields after validating raw JSON.
    ///
    /// - Throws: ``WireDecodeError`` if a field is malformed or has the wrong
    ///   JSON shape.
    public init(object: [UInt8], privateData: [UInt8]?) throws(WireDecodeError) {
        try validateOwnedJSON(object, field: "object", shape: .object)
        try validateOptionalOwnedJSON(privateData, field: "privateData", shape: .object)
        self.init(unchecked: object, privateData: privateData)
    }
}

/// Owned Deadvertise payload fields.
public struct OwnedDeadvertiseWireData: Sendable, Equatable {
    /// The deadvertised object identifiers as complete JSON array bytes.
    public let objectIds: [UInt8]

    init(unchecked objectIds: [UInt8]) {
        self.objectIds = objectIds
    }

    /// Creates owned Deadvertise payload fields after validating raw JSON.
    /// - Throws: ``WireDecodeError`` if `objectIds` is malformed or not an array.
    public init(objectIds: [UInt8]) throws(WireDecodeError) {
        try validateOwnedJSON(objectIds, field: "objectIds", shape: .array)
        self.init(unchecked: objectIds)
    }
}

/// Owned Channel payload fields.
public struct OwnedChannelWireData: Sendable, Equatable {
    /// The optional single object as complete JSON bytes.
    public let object: [UInt8]?
    /// The optional object collection as complete JSON bytes.
    public let objects: [UInt8]?
    /// Optional private data as complete JSON bytes.
    public let privateData: [UInt8]?

    init(unchecked object: [UInt8]?, objects: [UInt8]?, privateData: [UInt8]?) {
        self.object = object
        self.objects = objects
        self.privateData = privateData
    }

    /// Creates owned Channel payload fields after validating raw JSON.
    /// - Throws: ``WireDecodeError`` if a field is malformed or has the wrong shape.
    public init(object: [UInt8]?, objects: [UInt8]?, privateData: [UInt8]?) throws(WireDecodeError) {
        try validateOptionalOwnedJSON(object, field: "object", shape: .object)
        try validateOptionalOwnedJSON(objects, field: "objects", shape: .array)
        try validateOptionalOwnedJSON(privateData, field: "privateData", shape: .object)
        self.init(unchecked: object, objects: objects, privateData: privateData)
    }
}

/// Owned Associate payload fields.
public struct OwnedAssociateWireData: Sendable, Equatable {
    /// The I/O source identifier.
    public let ioSourceId: UUID16
    /// The I/O actor identifier.
    public let ioActorId: UUID16
    /// Optional encoded JSON string content for the route.
    public let associatingRoute: [UInt8]?
    /// Whether the association uses an external route.
    public let isExternalRoute: Bool?
    /// The optional update rate.
    public let updateRate: Int?

    init(unchecked ioSourceId: UUID16, ioActorId: UUID16, associatingRoute: [UInt8]?, isExternalRoute: Bool?, updateRate: Int?) {
        self.ioSourceId = ioSourceId
        self.ioActorId = ioActorId
        self.associatingRoute = associatingRoute
        self.isExternalRoute = isExternalRoute
        self.updateRate = updateRate
    }

    /// Creates owned Associate payload fields after validating encoded string content.
    /// - Throws: ``WireDecodeError`` if the route has malformed string content.
    public init(ioSourceId: UUID16, ioActorId: UUID16, associatingRoute: [UInt8]?, isExternalRoute: Bool?, updateRate: Int?) throws(WireDecodeError) {
        try validateOptionalEncodedString(associatingRoute, field: "associatingRoute")
        self.init(unchecked: ioSourceId, ioActorId: ioActorId, associatingRoute: associatingRoute, isExternalRoute: isExternalRoute, updateRate: updateRate)
    }
}

/// Owned IoValue payload fields.
public struct OwnedIoValueWireData: Sendable, Equatable {
    /// The I/O value as complete JSON bytes.
    public let payload: [UInt8]

    init(unchecked payload: [UInt8]) {
        self.payload = payload
    }

    /// Creates owned IoValue payload fields after validating one complete JSON value.
    /// - Throws: ``WireDecodeError`` if `payload` is malformed JSON.
    public init(payload: [UInt8]) throws(WireDecodeError) {
        try validateOwnedJSON(payload, field: "payload")
        self.init(unchecked: payload)
    }
}

/// Owned Discover payload fields.
public struct OwnedDiscoverWireData: Sendable, Equatable {
    /// Optional encoded JSON string content for the external identifier.
    public let externalId: [UInt8]?
    /// Optional encoded JSON string content for the object identifier.
    public let objectId: [UInt8]?
    /// Optional object types as complete JSON array bytes.
    public let objectTypes: [UInt8]?
    /// Optional core types as complete JSON array bytes.
    public let coreTypes: [UInt8]?

    init(unchecked externalId: [UInt8]?, objectId: [UInt8]?, objectTypes: [UInt8]?, coreTypes: [UInt8]?) {
        self.externalId = externalId
        self.objectId = objectId
        self.objectTypes = objectTypes
        self.coreTypes = coreTypes
    }

    /// Creates owned Discover payload fields after validating raw JSON.
    /// - Throws: ``WireDecodeError`` if a field is malformed or has the wrong shape.
    public init(externalId: [UInt8]?, objectId: [UInt8]?, objectTypes: [UInt8]?, coreTypes: [UInt8]?) throws(WireDecodeError) {
        try validateOptionalEncodedString(externalId, field: "externalId")
        try validateOptionalEncodedString(objectId, field: "objectId")
        try validateOptionalOwnedJSON(objectTypes, field: "objectTypes", shape: .array)
        try validateOptionalOwnedJSON(coreTypes, field: "coreTypes", shape: .array)
        self.init(unchecked: externalId, objectId: objectId, objectTypes: objectTypes, coreTypes: coreTypes)
    }
}

/// Owned Resolve payload fields.
public struct OwnedResolveWireData: Sendable, Equatable {
    /// The resolved object as complete JSON object bytes.
    public let object: [UInt8]
    /// Optional related objects as complete JSON array bytes.
    public let relatedObjects: [UInt8]?
    /// Optional private data as complete JSON object bytes.
    public let privateData: [UInt8]?

    init(unchecked object: [UInt8], relatedObjects: [UInt8]?, privateData: [UInt8]?) {
        self.object = object
        self.relatedObjects = relatedObjects
        self.privateData = privateData
    }

    /// Creates owned Resolve payload fields after validating raw JSON.
    /// - Throws: ``WireDecodeError`` if a field is malformed or has the wrong shape.
    public init(object: [UInt8], relatedObjects: [UInt8]?, privateData: [UInt8]?) throws(WireDecodeError) {
        try validateOwnedJSON(object, field: "object", shape: .object)
        try validateOptionalOwnedJSON(relatedObjects, field: "relatedObjects", shape: .array)
        try validateOptionalOwnedJSON(privateData, field: "privateData", shape: .object)
        self.init(unchecked: object, relatedObjects: relatedObjects, privateData: privateData)
    }
}

/// Owned Query payload fields.
public struct OwnedQueryWireData: Sendable, Equatable {
    /// Optional object types as complete JSON array bytes.
    public let objectTypes: [UInt8]?
    /// Optional core types as complete JSON array bytes.
    public let coreTypes: [UInt8]?
    /// Optional object filter as complete JSON object bytes.
    public let objectFilter: [UInt8]?
    /// Optional join conditions as a JSON object or array.
    public let objectJoinConditions: [UInt8]?

    init(unchecked objectTypes: [UInt8]?, coreTypes: [UInt8]?, objectFilter: [UInt8]?, objectJoinConditions: [UInt8]?) {
        self.objectTypes = objectTypes
        self.coreTypes = coreTypes
        self.objectFilter = objectFilter
        self.objectJoinConditions = objectJoinConditions
    }

    /// Creates owned Query payload fields after validating raw JSON.
    /// - Throws: ``WireDecodeError`` if a field is malformed or has the wrong shape.
    public init(objectTypes: [UInt8]?, coreTypes: [UInt8]?, objectFilter: [UInt8]?, objectJoinConditions: [UInt8]?) throws(WireDecodeError) {
        try validateOptionalOwnedJSON(objectTypes, field: "objectTypes", shape: .array)
        try validateOptionalOwnedJSON(coreTypes, field: "coreTypes", shape: .array)
        try validateOptionalOwnedJSON(objectFilter, field: "objectFilter", shape: .object)
        try validateOptionalOwnedJSON(objectJoinConditions, field: "objectJoinConditions", shape: .objectOrArray)
        self.init(unchecked: objectTypes, coreTypes: coreTypes, objectFilter: objectFilter, objectJoinConditions: objectJoinConditions)
    }
}

/// Owned Retrieve payload fields.
public struct OwnedRetrieveWireData: Sendable, Equatable {
    /// The retrieved objects as complete JSON array bytes, or the legacy
    /// single-object compatibility form accepted by the wire decoder.
    public let objects: [UInt8]
    /// Optional private data as complete JSON object bytes.
    public let privateData: [UInt8]?

    init(unchecked objects: [UInt8], privateData: [UInt8]?) {
        self.objects = objects
        self.privateData = privateData
    }

    /// Creates owned Retrieve payload fields after validating raw JSON.
    /// - Throws: ``WireDecodeError`` if a field is malformed or has the wrong shape.
    public init(objects: [UInt8], privateData: [UInt8]?) throws(WireDecodeError) {
        try validateOwnedJSON(objects, field: "objects", shape: .objectOrArray)
        try validateOptionalOwnedJSON(privateData, field: "privateData", shape: .object)
        self.init(unchecked: objects, privateData: privateData)
    }
}

/// Owned Update payload fields.
public struct OwnedUpdateWireData: Sendable, Equatable {
    /// The updated object as complete JSON object bytes.
    public let object: [UInt8]

    init(unchecked object: [UInt8]) {
        self.object = object
    }

    /// Creates owned Update payload fields after validating raw JSON.
    /// - Throws: ``WireDecodeError`` if `object` is malformed or not an object.
    public init(object: [UInt8]) throws(WireDecodeError) {
        try validateOwnedJSON(object, field: "object", shape: .object)
        self.init(unchecked: object)
    }
}

/// Owned Complete payload fields.
public struct OwnedCompleteWireData: Sendable, Equatable {
    /// The optional completed object as complete JSON object bytes.
    public let object: [UInt8]?
    /// Optional private data as complete JSON object bytes.
    public let privateData: [UInt8]?

    init(unchecked object: [UInt8]?, privateData: [UInt8]?) {
        self.object = object
        self.privateData = privateData
    }

    /// Creates owned Complete payload fields after validating raw JSON.
    /// - Throws: ``WireDecodeError`` if a field is malformed or has the wrong shape.
    public init(object: [UInt8]?, privateData: [UInt8]?) throws(WireDecodeError) {
        try validateOptionalOwnedJSON(object, field: "object", shape: .object)
        try validateOptionalOwnedJSON(privateData, field: "privateData", shape: .object)
        self.init(unchecked: object, privateData: privateData)
    }
}

/// Owned Call payload fields.
public struct OwnedCallWireData: Sendable, Equatable {
    /// Optional operation parameters as a JSON object or array.
    public let parameters: [UInt8]?
    /// Optional call filter as a complete JSON object.
    public let filter: [UInt8]?

    init(unchecked parameters: [UInt8]?, filter: [UInt8]?) {
        self.parameters = parameters
        self.filter = filter
    }

    /// Creates owned Call payload fields after validating raw JSON.
    /// - Throws: ``WireDecodeError`` if a field is malformed or has the wrong shape.
    public init(parameters: [UInt8]?, filter: [UInt8]?) throws(WireDecodeError) {
        try validateOptionalOwnedJSON(parameters, field: "parameters", shape: .objectOrArray)
        try validateOptionalOwnedJSON(filter, field: "filter", shape: .object)
        self.init(unchecked: parameters, filter: filter)
    }
}

/// Owned Return payload fields.
public struct OwnedReturnWireData: Sendable, Equatable {
    /// Optional return result as complete JSON bytes.
    public let result: [UInt8]?
    /// Optional execution information as complete JSON bytes.
    public let executionInfo: [UInt8]?
    /// Optional remote error as complete JSON object bytes.
    public let error: [UInt8]?

    init(unchecked result: [UInt8]?, executionInfo: [UInt8]?, error: [UInt8]?) {
        self.result = result
        self.executionInfo = executionInfo
        self.error = error
    }

    /// Creates owned Return payload fields after validating raw JSON.
    /// - Throws: ``WireDecodeError`` if a field is malformed or has the wrong shape.
    public init(result: [UInt8]?, executionInfo: [UInt8]?, error: [UInt8]?) throws(WireDecodeError) {
        try validateOptionalOwnedJSON(result, field: "result", shape: .any)
        try validateOptionalOwnedJSON(executionInfo, field: "executionInfo", shape: .any)
        try validateOptionalOwnedJSON(error, field: "error", shape: .object)
        self.init(unchecked: result, executionInfo: executionInfo, error: error)
    }
}
