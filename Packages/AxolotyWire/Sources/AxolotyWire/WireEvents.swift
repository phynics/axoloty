// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

// swiftlint:disable cyclomatic_complexity
/// The complete set of Coaty event payloads accepted by the wire codec.
///
/// Values in this enum borrow the reader's input buffer and are consequently
/// synchronous values. Use ``owned()`` before crossing an asynchronous
/// boundary; it validates and copies every raw field before returning.
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

    /// Copies every borrowed field into an owned event after validating raw JSON.
    ///
    /// - Throws: ``WireDecodeError`` if a raw field is malformed or has the
    ///   semantic shape required by its event field.
    public func owned() throws(WireDecodeError) -> OwnedWireEvent {
        switch self {
        case .advertise(let x): return .advertise(try OwnedAdvertiseWireData(object: copy(x.object), privateData: x.privateData.map(copy)))
        case .deadvertise(let x): return .deadvertise(try OwnedDeadvertiseWireData(objectIds: copy(x.objectIds)))
        case .channel(let x): return .channel(try OwnedChannelWireData(object: x.object.map(copy), objects: x.objects.map(copy), privateData: x.privateData.map(copy)))
        case .associate(let x): return .associate(try OwnedAssociateWireData(ioSourceId: x.ioSourceId, ioActorId: x.ioActorId, associatingRoute: x.associatingRoute.map(copy), isExternalRoute: x.isExternalRoute, updateRate: x.updateRate))
        case .ioValue(let x): return .ioValue(try OwnedIoValueWireData(payload: copy(x.payload)))
        case .discover(let x): return .discover(try OwnedDiscoverWireData(externalId: x.externalId.map(copy), objectId: x.objectId.map(copy), objectTypes: x.objectTypes.map(copy), coreTypes: x.coreTypes.map(copy)))
        case .resolve(let x): return .resolve(try OwnedResolveWireData(object: copy(x.object), relatedObjects: x.relatedObjects.map(copy), privateData: x.privateData.map(copy)))
        case .query(let x): return .query(try OwnedQueryWireData(objectTypes: x.objectTypes.map(copy), coreTypes: x.coreTypes.map(copy), objectFilter: x.objectFilter.map(copy), objectJoinConditions: x.objectJoinConditions.map(copy)))
        case .retrieve(let x): return .retrieve(try OwnedRetrieveWireData(objects: copy(x.objects), privateData: x.privateData.map(copy)))
        case .update(let x): return .update(try OwnedUpdateWireData(object: copy(x.object)))
        case .complete(let x): return .complete(try OwnedCompleteWireData(object: x.object.map(copy), privateData: x.privateData.map(copy)))
        case .call(let x): return .call(try OwnedCallWireData(parameters: x.parameters.map(copy), filter: x.filter.map(copy)))
        case .returnEvent(let x): return .returnEvent(try OwnedReturnWireData(result: x.result.map(copy), executionInfo: x.executionInfo.map(copy), error: x.error.map(copy)))
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

    /// Encodes every owned event through the fixed-buffer wire writer.
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

private func copy(_ slice: ByteSlice) -> [UInt8] {
    slice.withBytes { Array(UnsafeBufferPointer(start: $0.assumingMemoryBound(to: UInt8.self), count: $1)) }
}
// swiftlint:enable cyclomatic_complexity
