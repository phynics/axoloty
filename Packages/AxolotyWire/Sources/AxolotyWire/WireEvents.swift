// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

/// The complete set of Coaty event payloads accepted by the wire codec.
///
/// Values in this enum borrow the reader's input buffer and are consequently
/// synchronous values. Use ``owned()`` before crossing an asynchronous
/// boundary.
public enum BorrowedWireEvent {
    case advertise(AdvertiseWireData)
    case deadvertise(DeadvertiseWireData)
    case channel(ChannelWireData)
    case associate(AssociateWireData)
    case ioValue(IoValueWireData)
    case discover(DiscoverWireData)
    case resolve(ResolveWireData)
    case query(QueryWireData)
    case retrieve(RetrieveWireData)
    case update(UpdateWireData)
    case complete(CompleteWireData)
    case call(CallWireData)
    case returnEvent(ReturnWireData)

    /// Decodes and selects an event directly from a validated borrowed message.
    public init(message: BorrowedMessage) throws(WireDecodeError) {
        guard let eventType = message.eventType else {
            throw WireDecodeError(.malformedTopic)
        }
        self = try Self(eventType: eventType, from: message.reader())
    }

    /// Encodes the selected event through the centralized wire dispatch.
    public func encode(to writer: inout WireWriter) throws(WireEncodeError) {
        switch self {
        case .advertise(let value): try value.encode(to: &writer)
        case .deadvertise(let value): try value.encode(to: &writer)
        case .channel(let value): try value.encode(to: &writer)
        case .associate(let value): try value.encode(to: &writer)
        case .ioValue(let value): try value.encode(to: &writer)
        case .discover(let value): try value.encode(to: &writer)
        case .resolve(let value): try value.encode(to: &writer)
        case .query(let value): try value.encode(to: &writer)
        case .retrieve(let value): try value.encode(to: &writer)
        case .update(let value): try value.encode(to: &writer)
        case .complete(let value): try value.encode(to: &writer)
        case .call(let value): try value.encode(to: &writer)
        case .returnEvent(let value): try value.encode(to: &writer)
        }
    }

    /// Copies every borrowed field into an owned, typed event.
    public func owned() -> OwnedWireEvent {
        switch self {
        case .advertise(let x): return .advertise(.init(object: copy(x.object), privateData: x.privateData.map(copy)))
        case .deadvertise(let x): return .deadvertise(.init(objectIds: copy(x.objectIds)))
        case .channel(let x): return .channel(.init(object: x.object.map(copy), objects: x.objects.map(copy), privateData: x.privateData.map(copy)))
        case .associate(let x): return .associate(.init(ioSourceId: x.ioSourceId, ioActorId: x.ioActorId, associatingRoute: x.associatingRoute.map(copy), isExternalRoute: x.isExternalRoute, updateRate: x.updateRate))
        case .ioValue(let x): return .ioValue(.init(payload: copy(x.payload)))
        case .discover(let x): return .discover(.init(externalId: x.externalId.map(copy), objectId: x.objectId.map(copy), objectTypes: x.objectTypes.map(copy), coreTypes: x.coreTypes.map(copy)))
        case .resolve(let x): return .resolve(.init(object: copy(x.object), relatedObjects: x.relatedObjects.map(copy), privateData: x.privateData.map(copy)))
        case .query(let x): return .query(.init(objectTypes: x.objectTypes.map(copy), coreTypes: x.coreTypes.map(copy), objectFilter: x.objectFilter.map(copy), objectJoinConditions: x.objectJoinConditions.map(copy)))
        case .retrieve(let x): return .retrieve(.init(objects: copy(x.objects), privateData: x.privateData.map(copy)))
        case .update(let x): return .update(.init(object: copy(x.object)))
        case .complete(let x): return .complete(.init(object: x.object.map(copy), privateData: x.privateData.map(copy)))
        case .call(let x): return .call(.init(parameters: x.parameters.map(copy), filter: x.filter.map(copy)))
        case .returnEvent(let x): return .returnEvent(.init(result: x.result.map(copy), executionInfo: x.executionInfo.map(copy), error: x.error.map(copy)))
        }
    }

    /// Decodes the payload selected by `eventType`.
    public init(eventType: WireEventType, from reader: WireReader) throws(WireDecodeError) {
        switch eventType {
        case .advertise: self = .advertise(try AdvertiseWireData(from: reader))
        case .deadvertise: self = .deadvertise(try DeadvertiseWireData(from: reader))
        case .channel: self = .channel(try ChannelWireData(from: reader))
        case .associate: self = .associate(try AssociateWireData(from: reader))
        case .ioValue: self = .ioValue(try IoValueWireData(from: reader))
        case .discover: self = .discover(try DiscoverWireData(from: reader))
        case .resolve: self = .resolve(try ResolveWireData(from: reader))
        case .query: self = .query(try QueryWireData(from: reader))
        case .retrieve: self = .retrieve(try RetrieveWireData(from: reader))
        case .update: self = .update(try UpdateWireData(from: reader))
        case .complete: self = .complete(try CompleteWireData(from: reader))
        case .call: self = .call(try CallWireData(from: reader))
        case .returnEvent: self = .returnEvent(try ReturnWireData(from: reader))
        }
    }
}

/// An exhaustive owned event value suitable for asynchronous delivery.
/// Each associated value owns independent copies of every borrowed field.
public enum OwnedWireEvent: Sendable, Equatable {
    case advertise(OwnedAdvertiseWireData), deadvertise(OwnedDeadvertiseWireData), channel(OwnedChannelWireData), associate(OwnedAssociateWireData), ioValue(OwnedIoValueWireData), discover(OwnedDiscoverWireData), resolve(OwnedResolveWireData), query(OwnedQueryWireData), retrieve(OwnedRetrieveWireData), update(OwnedUpdateWireData), complete(OwnedCompleteWireData), call(OwnedCallWireData), returnEvent(OwnedReturnWireData)

    // swiftlint:disable cyclomatic_complexity
    /// Encodes every owned event through the same fixed-buffer writer used by borrowed events.
    public func encode(to writer: inout WireWriter) throws(WireEncodeError) {
        switch self {
        case .advertise(let x):
            try writer.beginObject(); try ownedRaw(&writer, "object", x.object)
            if let value = x.privateData { try writer.writeComma(); try ownedRaw(&writer, "privateData", value) }; try writer.endObject()
        case .deadvertise(let x):
            try writer.beginObject(); try ownedRaw(&writer, "objectIds", x.objectIds); try writer.endObject()
        case .channel(let x):
            try writer.beginObject(); var first = true
            if let value = x.object { try ownedComma(&writer, &first); try ownedRaw(&writer, "object", value) }
            if let value = x.objects { try ownedComma(&writer, &first); try ownedRaw(&writer, "objects", value) }
            if let value = x.privateData { try ownedComma(&writer, &first); try ownedRaw(&writer, "privateData", value) }; try writer.endObject()
        case .associate(let x):
            try writer.beginObject(); try writer.writeUUIDField("ioSourceId", x.ioSourceId); try writer.writeComma(); try writer.writeUUIDField("ioActorId", x.ioActorId)
            if let value = x.associatingRoute { try writer.writeComma(); try ownedString(&writer, "associatingRoute", value) }
            if let value = x.isExternalRoute, value { try writer.writeComma(); try writer.writeBoolField("isExternalRoute", true) }
            if let value = x.updateRate { try writer.writeComma(); try writer.writeIntField("updateRate", value) }; try writer.endObject()
        case .ioValue(let x): try writer.beginObject(); try ownedRaw(&writer, "payload", x.payload); try writer.endObject()
        case .discover(let x):
            try writer.beginObject(); var first = true
            if let value = x.externalId { try ownedComma(&writer, &first); try ownedString(&writer, "externalId", value) }; if let value = x.objectId { try ownedComma(&writer, &first); try ownedString(&writer, "objectId", value) }; if let value = x.objectTypes { try ownedComma(&writer, &first); try ownedRaw(&writer, "objectTypes", value) }; if let value = x.coreTypes { try ownedComma(&writer, &first); try ownedRaw(&writer, "coreTypes", value) }; try writer.endObject()
        case .resolve(let x): try writer.beginObject(); try ownedRaw(&writer, "object", x.object); if let value = x.relatedObjects { try writer.writeComma(); try ownedRaw(&writer, "relatedObjects", value) }; if let value = x.privateData { try writer.writeComma(); try ownedRaw(&writer, "privateData", value) }; try writer.endObject()
        case .query(let x): try writer.beginObject(); var first = true; if let value = x.objectTypes { try ownedComma(&writer, &first); try ownedRaw(&writer, "objectTypes", value) }; if let value = x.coreTypes { try ownedComma(&writer, &first); try ownedRaw(&writer, "coreTypes", value) }; if let value = x.objectFilter { try ownedComma(&writer, &first); try ownedRaw(&writer, "objectFilter", value) }; if let value = x.objectJoinConditions { try ownedComma(&writer, &first); try ownedRaw(&writer, "objectJoinConditions", value) }; try writer.endObject()
        case .retrieve(let x): try writer.beginObject(); try ownedRaw(&writer, "objects", x.objects); if let value = x.privateData { try writer.writeComma(); try ownedRaw(&writer, "privateData", value) }; try writer.endObject()
        case .update(let x): try writer.beginObject(); try ownedRaw(&writer, "object", x.object); try writer.endObject()
        case .complete(let x): try writer.beginObject(); var first = true; if let value = x.object { try ownedComma(&writer, &first); try ownedRaw(&writer, "object", value) }; if let value = x.privateData { try ownedComma(&writer, &first); try ownedRaw(&writer, "privateData", value) }; try writer.endObject()
        case .call(let x): try writer.beginObject(); var first = true; if let value = x.parameters { try ownedComma(&writer, &first); try ownedRaw(&writer, "parameters", value) }; if let value = x.filter { try ownedComma(&writer, &first); try ownedRaw(&writer, "filter", value) }; try writer.endObject()
        case .returnEvent(let x): try writer.beginObject(); var first = true; if let value = x.result { try ownedComma(&writer, &first); try ownedRaw(&writer, "result", value) }; if let value = x.executionInfo { try ownedComma(&writer, &first); try ownedRaw(&writer, "executionInfo", value) }; if let value = x.error { try ownedComma(&writer, &first); try ownedRaw(&writer, "error", value) }; try writer.endObject()
        }
    }
    // swiftlint:enable cyclomatic_complexity
}

private func ownedString(_ writer: inout WireWriter, _ key: StaticString, _ bytes: [UInt8]) throws(WireEncodeError) {
    try bytes.withUnsafeBufferPointer { (buffer) throws(WireEncodeError) in
        guard let address = buffer.baseAddress else { try writer.writeStringField(key, ByteSlice(pointer: UnsafeRawPointer(bitPattern: 1)!, length: 0)); return }
        try writer.writeEncodedStringField(key, ByteSlice(bytes: address, length: buffer.count))
    }
}
private func ownedRaw(_ writer: inout WireWriter, _ key: StaticString, _ bytes: [UInt8]) throws(WireEncodeError) {
    try bytes.withUnsafeBufferPointer { (buffer) throws(WireEncodeError) in
        guard let address = buffer.baseAddress else { throw WireEncodeError.invalidValue }
        try writer.writeTrustedRawField(key, ByteSlice(bytes: address, length: buffer.count))
    }
}

private func ownedComma(_ writer: inout WireWriter, _ first: inout Bool) throws(WireEncodeError) {
    if !first { try writer.writeComma() }; first = false
}

/// Owned Advertise payload fields.
public struct OwnedAdvertiseWireData: Sendable, Equatable {
    /// The advertised object as complete JSON bytes.
    public let object: [UInt8]
    /// Optional private data as complete JSON bytes.
    public let privateData: [UInt8]?

    /// Creates owned Advertise payload fields.
    /// - Parameters:
    ///   - object: The advertised object as complete JSON bytes.
    ///   - privateData: Optional private data as complete JSON bytes.
    public init(object: [UInt8], privateData: [UInt8]?) {
        self.object = object
        self.privateData = privateData
    }
}

/// Owned Deadvertise payload fields.
public struct OwnedDeadvertiseWireData: Sendable, Equatable {
    /// The deadvertised object identifiers as a complete JSON array.
    public let objectIds: [UInt8]

    /// Creates owned Deadvertise payload fields.
    /// - Parameter objectIds: The object identifiers as a complete JSON array.
    public init(objectIds: [UInt8]) {
        self.objectIds = objectIds
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

    /// Creates owned Channel payload fields.
    /// - Parameters:
    ///   - object: The optional single object as complete JSON bytes.
    ///   - objects: The optional object collection as complete JSON bytes.
    ///   - privateData: Optional private data as complete JSON bytes.
    public init(object: [UInt8]?, objects: [UInt8]?, privateData: [UInt8]?) {
        self.object = object
        self.objects = objects
        self.privateData = privateData
    }
}

/// Owned Associate payload fields.
public struct OwnedAssociateWireData: Sendable, Equatable {
    /// The I/O source identifier.
    public let ioSourceId: UUID16
    /// The I/O actor identifier.
    public let ioActorId: UUID16
    /// The optional encoded JSON string content for the associating route.
    public let associatingRoute: [UInt8]?
    /// Whether the association uses an external route.
    public let isExternalRoute: Bool?
    /// The optional update rate.
    public let updateRate: Int?

    /// Creates owned Associate payload fields.
    /// - Parameters:
    ///   - ioSourceId: The I/O source identifier.
    ///   - ioActorId: The I/O actor identifier.
    ///   - associatingRoute: Optional encoded JSON string content for the route.
    ///   - isExternalRoute: Whether the association uses an external route.
    ///   - updateRate: The optional update rate.
    public init(
        ioSourceId: UUID16,
        ioActorId: UUID16,
        associatingRoute: [UInt8]?,
        isExternalRoute: Bool?,
        updateRate: Int?
    ) {
        self.ioSourceId = ioSourceId
        self.ioActorId = ioActorId
        self.associatingRoute = associatingRoute
        self.isExternalRoute = isExternalRoute
        self.updateRate = updateRate
    }
}

/// Owned IoValue payload fields.
public struct OwnedIoValueWireData: Sendable, Equatable {
    /// The I/O value as complete JSON bytes.
    public let payload: [UInt8]

    /// Creates owned IoValue payload fields.
    /// - Parameter payload: The I/O value as complete JSON bytes.
    public init(payload: [UInt8]) {
        self.payload = payload
    }
}

/// Owned Discover payload fields.
public struct OwnedDiscoverWireData: Sendable, Equatable {
    /// Optional encoded JSON string content for the external identifier.
    public let externalId: [UInt8]?
    /// Optional encoded JSON string content for the object identifier.
    public let objectId: [UInt8]?
    /// Optional object types as complete JSON bytes.
    public let objectTypes: [UInt8]?
    /// Optional core types as complete JSON bytes.
    public let coreTypes: [UInt8]?

    /// Creates owned Discover payload fields.
    /// - Parameters:
    ///   - externalId: Optional encoded JSON string content for the external identifier.
    ///   - objectId: Optional encoded JSON string content for the object identifier.
    ///   - objectTypes: Optional object types as complete JSON bytes.
    ///   - coreTypes: Optional core types as complete JSON bytes.
    public init(externalId: [UInt8]?, objectId: [UInt8]?, objectTypes: [UInt8]?, coreTypes: [UInt8]?) {
        self.externalId = externalId
        self.objectId = objectId
        self.objectTypes = objectTypes
        self.coreTypes = coreTypes
    }
}

/// Owned Resolve payload fields.
public struct OwnedResolveWireData: Sendable, Equatable {
    /// The resolved object as complete JSON bytes.
    public let object: [UInt8]
    /// Optional related objects as complete JSON bytes.
    public let relatedObjects: [UInt8]?
    /// Optional private data as complete JSON bytes.
    public let privateData: [UInt8]?

    /// Creates owned Resolve payload fields.
    /// - Parameters:
    ///   - object: The resolved object as complete JSON bytes.
    ///   - relatedObjects: Optional related objects as complete JSON bytes.
    ///   - privateData: Optional private data as complete JSON bytes.
    public init(object: [UInt8], relatedObjects: [UInt8]?, privateData: [UInt8]?) {
        self.object = object
        self.relatedObjects = relatedObjects
        self.privateData = privateData
    }
}

/// Owned Query payload fields.
public struct OwnedQueryWireData: Sendable, Equatable {
    /// Optional object types as complete JSON bytes.
    public let objectTypes: [UInt8]?
    /// Optional core types as complete JSON bytes.
    public let coreTypes: [UInt8]?
    /// Optional object filter as complete JSON bytes.
    public let objectFilter: [UInt8]?
    /// Optional join conditions as complete JSON bytes.
    public let objectJoinConditions: [UInt8]?

    /// Creates owned Query payload fields.
    /// - Parameters:
    ///   - objectTypes: Optional object types as complete JSON bytes.
    ///   - coreTypes: Optional core types as complete JSON bytes.
    ///   - objectFilter: Optional object filter as complete JSON bytes.
    ///   - objectJoinConditions: Optional join conditions as complete JSON bytes.
    public init(
        objectTypes: [UInt8]?,
        coreTypes: [UInt8]?,
        objectFilter: [UInt8]?,
        objectJoinConditions: [UInt8]?
    ) {
        self.objectTypes = objectTypes
        self.coreTypes = coreTypes
        self.objectFilter = objectFilter
        self.objectJoinConditions = objectJoinConditions
    }
}

/// Owned Retrieve payload fields.
public struct OwnedRetrieveWireData: Sendable, Equatable {
    /// The retrieved objects as complete JSON bytes.
    public let objects: [UInt8]
    /// Optional private data as complete JSON bytes.
    public let privateData: [UInt8]?

    /// Creates owned Retrieve payload fields.
    /// - Parameters:
    ///   - objects: The retrieved objects as complete JSON bytes.
    ///   - privateData: Optional private data as complete JSON bytes.
    public init(objects: [UInt8], privateData: [UInt8]?) {
        self.objects = objects
        self.privateData = privateData
    }
}

/// Owned Update payload fields.
public struct OwnedUpdateWireData: Sendable, Equatable {
    /// The updated object as complete JSON bytes.
    public let object: [UInt8]

    /// Creates owned Update payload fields.
    /// - Parameter object: The updated object as complete JSON bytes.
    public init(object: [UInt8]) {
        self.object = object
    }
}

/// Owned Complete payload fields.
public struct OwnedCompleteWireData: Sendable, Equatable {
    /// The optional completed object as complete JSON bytes.
    public let object: [UInt8]?
    /// Optional private data as complete JSON bytes.
    public let privateData: [UInt8]?

    /// Creates owned Complete payload fields.
    /// - Parameters:
    ///   - object: The optional completed object as complete JSON bytes.
    ///   - privateData: Optional private data as complete JSON bytes.
    public init(object: [UInt8]?, privateData: [UInt8]?) {
        self.object = object
        self.privateData = privateData
    }
}

/// Owned Call payload fields.
public struct OwnedCallWireData: Sendable, Equatable {
    /// Optional operation parameters as complete JSON bytes.
    public let parameters: [UInt8]?
    /// Optional call filter as complete JSON bytes.
    public let filter: [UInt8]?

    /// Creates owned Call payload fields.
    /// - Parameters:
    ///   - parameters: Optional operation parameters as complete JSON bytes.
    ///   - filter: Optional call filter as complete JSON bytes.
    public init(parameters: [UInt8]?, filter: [UInt8]?) {
        self.parameters = parameters
        self.filter = filter
    }
}

/// Owned Return payload fields.
public struct OwnedReturnWireData: Sendable, Equatable {
    /// Optional return result as complete JSON bytes.
    public let result: [UInt8]?
    /// Optional execution information as complete JSON bytes.
    public let executionInfo: [UInt8]?
    /// Optional remote error as complete JSON bytes.
    public let error: [UInt8]?

    /// Creates owned Return payload fields.
    /// - Parameters:
    ///   - result: Optional return result as complete JSON bytes.
    ///   - executionInfo: Optional execution information as complete JSON bytes.
    ///   - error: Optional remote error as complete JSON bytes.
    public init(result: [UInt8]?, executionInfo: [UInt8]?, error: [UInt8]?) {
        self.result = result
        self.executionInfo = executionInfo
        self.error = error
    }
}

private func copy(_ slice: ByteSlice) -> [UInt8] { slice.withBytes { Array(UnsafeBufferPointer(start: $0.assumingMemoryBound(to: UInt8.self), count: $1)) } }
