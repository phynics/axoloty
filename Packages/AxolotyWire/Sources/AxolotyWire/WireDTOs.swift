// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

/// Foundation-free wire DTOs for Coaty communication event data.
///
/// These mirror the Codable `*EventData` types but use `UUID16` and
/// `ByteSlice` instead of `CoatyUUID` and `String`. On the host runtime,
/// they are populated from the same JSON bytes via `WireReader` and
/// compared against the Codable path to prove semantic equivalence.
///
/// The embedded target will consume these DTOs directly — no Foundation
/// dependency, no class hierarchy, no Codable reflection.

// MARK: - AssociateEventData

/// Wire DTO mirroring `AssociateEventData`, decoded from JSON via
/// ``WireReader`` and encoded via ``WireWriter``.
public struct AssociateWireData: WireDecodable, WireEncodable, Equatable {
    /// The UUID of the IO source being associated.
    public let ioSourceId: UUID16
    /// The UUID of the IO actor the source associates with.
    public let ioActorId: UUID16
    /// The optional associating route, as borrowed UTF-8 bytes.
    public let associatingRoute: ByteSlice?
    /// Whether the route is external. Encoded only when `true`.
    public let isExternalRoute: Bool?
    /// The optional update rate in milliseconds.
    public let updateRate: Int?

    /// Decodes an associate event from `reader`.
    ///
    /// `ioSourceId` and `ioActorId` are required; the remaining fields are
    /// optional and default to nil when absent.
    ///
    /// - Parameter reader: A ``WireReader`` over the JSON payload.
    /// - Throws: ``WireDecodeError`` if `ioSourceId` or `ioActorId` is missing.
    public init(from reader: WireReader) throws(WireDecodeError) {
        try reader.validate()
        guard let sourceId = reader.readUUID("ioSourceId") else {
            throw WireDecodeError(.missingField, field: "ioSourceId")
        }
        guard let actorId = reader.readUUID("ioActorId") else {
            throw WireDecodeError(.missingField, field: "ioActorId")
        }
        self.ioSourceId = sourceId
        self.ioActorId = actorId
        self.associatingRoute = reader.readString("associatingRoute")
        self.isExternalRoute = reader.readBool("isExternalRoute")
        self.updateRate = reader.readInt("updateRate")
    }

    /// Encodes this event into `writer` as a JSON object.
    ///
    /// `ioSourceId` and `ioActorId` are always written; the optional fields
    /// are written only when present (`isExternalRoute` only when `true`).
    ///
    /// - Parameter writer: The ``WireWriter`` to encode into.
    /// - Throws: ``WireEncodeError`` if the buffer overflows.
    public func encode(to writer: inout WireWriter) throws(WireEncodeError) {
        try writer.beginObject()
        try writer.writeUUIDField("ioSourceId", ioSourceId)
        try writer.writeComma()
        try writer.writeUUIDField("ioActorId", ioActorId)
        if let route = associatingRoute {
            try writer.writeComma()
            try writer.writeEncodedStringField("associatingRoute", route)
        }
        if let isExternal = isExternalRoute, isExternal {
            try writer.writeComma()
            try writer.writeBoolField("isExternalRoute", isExternal)
        }
        if let rate = updateRate {
            try writer.writeComma()
            try writer.writeIntField("updateRate", rate)
        }
        try writer.endObject()
    }
}

// MARK: - AdvertiseEventData

/// Wire DTO mirroring `AdvertiseEventData`, carrying the advertised object
/// as a raw JSON fragment.
public struct AdvertiseWireData: WireDecodable, WireEncodable, Equatable {
    /// The raw JSON bytes of the advertised object.
    public let object: ByteSlice
    /// The optional private data as raw JSON bytes.
    public let privateData: ByteSlice?

    /// Decodes an advertise event from `reader`.
    ///
    /// `object` is required; `privateData` is optional.
    ///
    /// - Parameter reader: A ``WireReader`` over the JSON payload.
    /// - Throws: ``WireDecodeError`` if the `object` field is missing.
    public init(from reader: WireReader) throws(WireDecodeError) {
        try reader.validate()
        guard let obj = reader.readRaw("object") else {
            throw WireDecodeError(.missingField, field: "object")
        }
        self.object = obj
        self.privateData = reader.readOptionalRaw("privateData")
    }

    /// Encodes this event into `writer` as a JSON object wrapping `object`,
    /// writing `privateData` only when present.
    ///
    /// - Parameter writer: The ``WireWriter`` to encode into.
    /// - Throws: ``WireEncodeError`` if the buffer overflows.
    public func encode(to writer: inout WireWriter) throws(WireEncodeError) {
        try writer.beginObject()
        try writer.writeTrustedRawField("object", object)
        if let pd = privateData {
            try writer.writeComma()
            try writer.writeTrustedRawField("privateData", pd)
        }
        try writer.endObject()
    }
}

// MARK: - DeadvertiseEventData

/// Wire DTO mirroring `DeadvertiseEventData`, carrying the list of object IDs
/// to remove as parsed ``UUID16`` values.
public struct DeadvertiseWireData: WireDecodable, WireEncodable, Equatable {
    /// The raw JSON bytes of the `objectIds` array (a JSON array of
    /// hyphenated UUID strings).
    public let objectIds: ByteSlice

    /// Decodes a deadvertise event from `reader`, capturing the `objectIds`
    /// array as raw JSON bytes so the host can decode the original UUID
    /// strings without normalizing them through ``UUID16``.
    ///
    /// - Parameter reader: A ``WireReader`` over the JSON payload.
    /// - Throws: ``WireDecodeError`` if the `objectIds` field is missing.
    public init(from reader: WireReader) throws(WireDecodeError) {
        try reader.validate()
        guard let ids = reader.readRaw("objectIds") else {
            throw WireDecodeError(.missingField, field: "objectIds")
        }
        self.objectIds = ids
    }

    /// Encodes this event into `writer`, serializing `objectIds` as a JSON
    /// array.
    ///
    /// - Parameter writer: The ``WireWriter`` to encode into.
    /// - Throws: ``WireEncodeError`` if the buffer overflows.
    public func encode(to writer: inout WireWriter) throws(WireEncodeError) {
        try writer.beginObject()
        try writer.writeTrustedRawField("objectIds", objectIds)
        try writer.endObject()
    }
}

// MARK: - IoValueEventData

/// Wire DTO mirroring `IoValueEventData`, carrying the IO value payload as a
/// raw JSON fragment.
public struct IoValueWireData: WireDecodable, WireEncodable, Equatable {
    /// The raw JSON bytes of the IO value payload.
    public let payload: ByteSlice

    /// Decodes an IoValue event from `reader`.
    ///
    /// - Parameter reader: A ``WireReader`` over the JSON payload.
    /// - Throws: ``WireDecodeError`` if the `payload` field is missing.
    public init(from reader: WireReader) throws(WireDecodeError) {
        try reader.validate()
        guard let p = reader.readRaw("payload") else {
            throw WireDecodeError(.missingField, field: "payload")
        }
        self.payload = p
    }

    /// Encodes this event into `writer` as a JSON object wrapping `payload`.
    ///
    /// - Parameter writer: The ``WireWriter`` to encode into.
    /// - Throws: ``WireEncodeError`` if the buffer overflows.
    public func encode(to writer: inout WireWriter) throws(WireEncodeError) {
        try writer.beginObject()
        try writer.writeTrustedRawField("payload", payload)
        try writer.endObject()
    }
}

// MARK: - ChannelEventData

/// Wire DTO mirroring `ChannelEventData`, carrying optional object and
/// private-data fragments.
public struct ChannelWireData: WireDecodable, WireEncodable, Equatable {
    /// The optional channel object as raw JSON bytes.
    public let object: ByteSlice?
    /// The optional array of channel objects as raw JSON bytes.
    public let objects: ByteSlice?
    /// The optional private data as raw JSON bytes.
    public let privateData: ByteSlice?

    /// Decodes a channel event from `reader`.
    ///
    /// `object`, `objects`, and `privateData` are all optional; absent fields
    /// default to nil.
    ///
    /// - Parameter reader: A ``WireReader`` over the JSON payload.
    public init(from reader: WireReader) throws(WireDecodeError) {
        try reader.validate()
        self.object = reader.readOptionalRaw("object")
        self.objects = reader.readOptionalRaw("objects")
        self.privateData = reader.readOptionalRaw("privateData")
    }

    /// Encodes this event into `writer` as a JSON object, writing only the
    /// fields that are present.
    ///
    /// - Parameter writer: The ``WireWriter`` to encode into.
    /// - Throws: ``WireEncodeError`` if the buffer overflows.
    public func encode(to writer: inout WireWriter) throws(WireEncodeError) {
        try writer.beginObject()
        var first = true
        if let obj = object {
            try writer.writeTrustedRawField("object", obj)
            first = false
        }
        if let objs = objects {
            if !first { try writer.writeComma() }; first = false
            try writer.writeTrustedRawField("objects", objs)
        }
        if let pd = privateData {
            if !first { try writer.writeComma() }
            try writer.writeTrustedRawField("privateData", pd)
        }
        try writer.endObject()
    }

    /// Returns `true` if both events carry equal object, objects, and
    /// private-data bytes.
    public static func == (lhs: ChannelWireData, rhs: ChannelWireData) -> Bool {
        lhs.object == rhs.object && lhs.objects == rhs.objects && lhs.privateData == rhs.privateData
    }
}

// MARK: - DiscoverEventData

/// Wire DTO mirroring `DiscoverEventData`, carrying optional filter criteria.
public struct DiscoverWireData: WireDecodable, WireEncodable, Equatable {
    /// The optional external ID as raw JSON bytes (a JSON string).
    public let externalId: ByteSlice?
    /// The optional object UUID as raw JSON bytes (a JSON string).
    public let objectId: ByteSlice?
    /// The optional object types filter as raw JSON bytes (a JSON array).
    public let objectTypes: ByteSlice?
    /// The optional core types filter as raw JSON bytes (a JSON array).
    public let coreTypes: ByteSlice?

    /// Decodes a discover event from `reader`.
    ///
    /// All fields are optional; absent fields default to nil.
    ///
    /// - Parameter reader: A ``WireReader`` over the JSON payload.
    public init(from reader: WireReader) throws(WireDecodeError) {
        try reader.validate()
        self.externalId = reader.readString("externalId")
        self.objectId = reader.readString("objectId")
        self.objectTypes = reader.readOptionalRaw("objectTypes")
        self.coreTypes = reader.readOptionalRaw("coreTypes")
    }

    /// Encodes this event into `writer` as a JSON object, writing only the
    /// fields that are present.
    ///
    /// - Parameter writer: The ``WireWriter`` to encode into.
    /// - Throws: ``WireEncodeError`` if the buffer overflows.
    public func encode(to writer: inout WireWriter) throws(WireEncodeError) {
        try writer.beginObject()
        var first = true
        if let eid = externalId {
            try writer.writeEncodedStringField("externalId", eid)
            first = false
        }
        if let oid = objectId {
            if !first { try writer.writeComma() }; first = false
            try writer.writeEncodedStringField("objectId", oid)
        }
        if let ot = objectTypes {
            if !first { try writer.writeComma() }; first = false
            try writer.writeTrustedRawField("objectTypes", ot)
        }
        if let ct = coreTypes {
            if !first { try writer.writeComma() }
            try writer.writeTrustedRawField("coreTypes", ct)
        }
        try writer.endObject()
    }
}

// MARK: - QueryEventData

/// Wire DTO mirroring `QueryEventData`, carrying optional filter criteria.
public struct QueryWireData: WireDecodable, WireEncodable, Equatable {
    /// The optional object types filter as raw JSON bytes.
    public let objectTypes: ByteSlice?
    /// The optional core types filter as raw JSON bytes.
    public let coreTypes: ByteSlice?
    /// The optional object filter as raw JSON bytes.
    public let objectFilter: ByteSlice?
    /// The optional join conditions as raw JSON bytes (a JSON array of
    /// objects).
    public let objectJoinConditions: ByteSlice?

    /// Decodes a query event from `reader`.
    ///
    /// All fields are optional; absent fields default to nil.
    ///
    /// - Parameter reader: A ``WireReader`` over the JSON payload.
    public init(from reader: WireReader) throws(WireDecodeError) {
        try reader.validate()
        self.objectTypes = reader.readOptionalRaw("objectTypes")
        self.coreTypes = reader.readOptionalRaw("coreTypes")
        self.objectFilter = reader.readOptionalRaw("objectFilter")
        self.objectJoinConditions = reader.readOptionalRaw("objectJoinConditions")
    }

    /// Encodes this event into `writer` as a JSON object, writing only the
    /// fields that are present.
    ///
    /// - Parameter writer: The ``WireWriter`` to encode into.
    /// - Throws: ``WireEncodeError`` if the buffer overflows.
    public func encode(to writer: inout WireWriter) throws(WireEncodeError) {
        try writer.beginObject()
        var first = true
        if let ot = objectTypes {
            first = false
            try writer.writeTrustedRawField("objectTypes", ot)
        }
        if let ct = coreTypes {
            if !first { try writer.writeComma() }; first = false
            try writer.writeTrustedRawField("coreTypes", ct)
        }
        if let of = objectFilter {
            if !first { try writer.writeComma() }; first = false
            try writer.writeTrustedRawField("objectFilter", of)
        }
        if let ojc = objectJoinConditions {
            if !first { try writer.writeComma() }
            try writer.writeTrustedRawField("objectJoinConditions", ojc)
        }
        try writer.endObject()
    }
}

// MARK: - CallEventData

/// Wire DTO mirroring `CallEventData`, carrying a remote operation request.
public struct CallWireData: WireDecodable, WireEncodable, Equatable {
    /// The operation parameters as raw JSON bytes.
    public let parameters: ByteSlice?
    /// The optional context filter as raw JSON bytes.
    public let filter: ByteSlice?

    /// Decodes a call event from `reader`.
    ///
    /// `parameters` and `filter` are optional. The topic carries the operation
    /// name; the legacy `operationType` member is accepted and ignored.
    ///
    /// - Parameter reader: A ``WireReader`` over the JSON payload.
    /// - Throws: ``WireDecodeError`` if the JSON is malformed.
    public init(from reader: WireReader) throws(WireDecodeError) {
        try reader.validate()
        self.parameters = reader.readOptionalRaw("parameters")
        self.filter = reader.readOptionalRaw("filter")
    }

    /// Encodes this event into `writer` using the canonical `parameters` and
    /// `filter` members when present.
    ///
    /// - Parameter writer: The ``WireWriter`` to encode into.
    /// - Throws: ``WireEncodeError`` if the buffer overflows.
    public func encode(to writer: inout WireWriter) throws(WireEncodeError) {
        try writer.beginObject()
        if let params = parameters {
            try writer.writeTrustedRawField("parameters", params)
        }
        if let filter {
            if parameters != nil { try writer.writeComma() }
            try writer.writeTrustedRawField("filter", filter)
        }
        try writer.endObject()
    }
}

// MARK: - ReturnEventData

/// Wire DTO mirroring `ReturnEventData`, carrying a remote operation result.
public struct ReturnWireData: WireDecodable, WireEncodable, Equatable {
    /// The optional result as raw JSON bytes.
    public let result: ByteSlice?
    /// The optional execution info as raw JSON bytes.
    public let executionInfo: ByteSlice?
    /// The optional remote-call error object as raw JSON bytes.
    public let error: ByteSlice?

    /// Decodes a return event from `reader`.
    ///
    /// All fields are optional; absent fields default to nil.
    ///
    /// - Parameter reader: A ``WireReader`` over the JSON payload.
    public init(from reader: WireReader) throws(WireDecodeError) {
        try reader.validate()
        self.result = reader.readOptionalRaw("result")
        self.executionInfo = reader.readOptionalRaw("executionInfo")
        self.error = reader.readOptionalRaw("error")
    }

    /// Encodes this event into `writer` as a JSON object, writing only the
    /// fields that are present.
    ///
    /// - Parameter writer: The ``WireWriter`` to encode into.
    /// - Throws: ``WireEncodeError`` if the buffer overflows.
    public func encode(to writer: inout WireWriter) throws(WireEncodeError) {
        try writer.beginObject()
        var first = true
        if let r = result {
            first = false
            try writer.writeTrustedRawField("result", r)
        }
        if let ei = executionInfo {
            if !first { try writer.writeComma() }; first = false
            try writer.writeTrustedRawField("executionInfo", ei)
        }
        if let e = error {
            if !first { try writer.writeComma() }; first = false
            try writer.writeTrustedRawField("error", e)
        }
        try writer.endObject()
    }
}

// MARK: - ResolveEventData

/// Wire DTO mirroring `ResolveEventData`, carrying a resolved object.
public struct ResolveWireData: WireDecodable, WireEncodable, Equatable {
    /// The resolved object as raw JSON bytes.
    public let object: ByteSlice
    /// Related objects resolved alongside `object`.
    public let relatedObjects: ByteSlice?
    /// The optional private data as raw JSON bytes.
    public let privateData: ByteSlice?

    /// Decodes a resolve event from `reader`.
    ///
    /// `object` is required; `privateData` is optional.
    ///
    /// - Parameter reader: A ``WireReader`` over the JSON payload.
    /// - Throws: ``WireDecodeError`` if the `object` field is missing.
    public init(from reader: WireReader) throws(WireDecodeError) {
        try reader.validate()
        guard let obj = reader.readRaw("object") else {
            throw WireDecodeError(.missingField, field: "object")
        }
        self.object = obj
        self.relatedObjects = reader.readOptionalRaw("relatedObjects")
        self.privateData = reader.readOptionalRaw("privateData")
    }

    /// Encodes this event into `writer` as a JSON object. `object` is always
    /// written; `privateData` only when present.
    ///
    /// - Parameter writer: The ``WireWriter`` to encode into.
    /// - Throws: ``WireEncodeError`` if the buffer overflows.
    public func encode(to writer: inout WireWriter) throws(WireEncodeError) {
        try writer.beginObject()
        try writer.writeTrustedRawField("object", object)
        if let relatedObjects {
            try writer.writeComma()
            try writer.writeTrustedRawField("relatedObjects", relatedObjects)
        }
        if let pd = privateData {
            try writer.writeComma()
            try writer.writeTrustedRawField("privateData", pd)
        }
        try writer.endObject()
    }
}

// MARK: - RetrieveEventData

/// Wire DTO mirroring `RetrieveEventData`, carrying retrieved objects.
public struct RetrieveWireData: WireDecodable, WireEncodable, Equatable {
    /// The retrieved objects array as raw JSON bytes.
    public let objects: ByteSlice
    /// Optional application data.
    public let privateData: ByteSlice?

    /// Decodes a retrieve event from `reader`.
    ///
    /// - Parameter reader: A ``WireReader`` over the JSON payload.
    /// - Throws: ``WireDecodeError`` if the `object` field is missing.
    public init(from reader: WireReader) throws(WireDecodeError) {
        try reader.validate()
        guard let objects = reader.readRaw("objects") ?? reader.readRaw("object") else {
            throw WireDecodeError(.missingField, field: "objects")
        }
        self.objects = objects
        self.privateData = reader.readOptionalRaw("privateData")
    }

    /// Encodes this event into `writer` as a JSON object wrapping `object`.
    ///
    /// - Parameter writer: The ``WireWriter`` to encode into.
    /// - Throws: ``WireEncodeError`` if the buffer overflows.
    public func encode(to writer: inout WireWriter) throws(WireEncodeError) {
        try writer.beginObject()
        try writer.writeTrustedRawField("objects", objects)
        if let privateData {
            try writer.writeComma()
            try writer.writeTrustedRawField("privateData", privateData)
        }
        try writer.endObject()
    }
}

// MARK: - UpdateEventData

/// Wire DTO mirroring `UpdateEventData`, carrying an updated object.
public struct UpdateWireData: WireDecodable, WireEncodable, Equatable {
    /// The updated object as raw JSON bytes.
    public let object: ByteSlice

    /// Decodes an update event from `reader`.
    ///
    /// - Parameter reader: A ``WireReader`` over the JSON payload.
    /// - Throws: ``WireDecodeError`` if the `object` field is missing.
    public init(from reader: WireReader) throws(WireDecodeError) {
        try reader.validate()
        guard let obj = reader.readRaw("object") else {
            throw WireDecodeError(.missingField, field: "object")
        }
        self.object = obj
    }

    /// Encodes this event into `writer` as a JSON object wrapping `object`.
    ///
    /// - Parameter writer: The ``WireWriter`` to encode into.
    /// - Throws: ``WireEncodeError`` if the buffer overflows.
    public func encode(to writer: inout WireWriter) throws(WireEncodeError) {
        try writer.beginObject()
        try writer.writeTrustedRawField("object", object)
        try writer.endObject()
    }
}

// MARK: - CompleteEventData

/// Wire DTO mirroring `CompleteEventData`, carrying completion state.
public struct CompleteWireData: WireDecodable, WireEncodable, Equatable {
    /// The optional object as raw JSON bytes.
    public let object: ByteSlice?
    /// Optional application data.
    public let privateData: ByteSlice?

    /// Decodes a complete event from `reader`.
    ///
    /// Both `object` and `completed` are optional; absent fields default to nil.
    ///
    /// - Parameter reader: A ``WireReader`` over the JSON payload.
    public init(from reader: WireReader) throws(WireDecodeError) {
        try reader.validate()
        self.object = reader.readOptionalRaw("object")
        self.privateData = reader.readOptionalRaw("privateData")
    }

    /// Encodes this event into `writer` as a JSON object, writing only the
    /// fields that are present.
    ///
    /// - Parameter writer: The ``WireWriter`` to encode into.
    /// - Throws: ``WireEncodeError`` if the buffer overflows.
    public func encode(to writer: inout WireWriter) throws(WireEncodeError) {
        try writer.beginObject()
        var first = true
        if let obj = object {
            first = false
            try writer.writeTrustedRawField("object", obj)
        }
        if let privateData {
            if !first { try writer.writeComma() }; first = false
            try writer.writeTrustedRawField("privateData", privateData)
        }
        try writer.endObject()
    }
}

// MARK: - IoStateEventData

/// Wire DTO mirroring `IoStateEventData`, carrying IO association state.
public struct IoStateWireData: WireDecodable, WireEncodable, Equatable {
    /// Whether the IO source currently has associations.
    public let hasAssociations: Bool
    /// The optional update rate in milliseconds.
    public let updateRate: Int?

    /// Decodes an IoState event from `reader`.
    ///
    /// `hasAssociations` is required; `updateRate` is optional.
    ///
    /// - Parameter reader: A ``WireReader`` over the JSON payload.
    /// - Throws: ``WireDecodeError`` if `hasAssociations` is missing.
    public init(from reader: WireReader) throws(WireDecodeError) {
        guard let ha = reader.readBool("hasAssociations") else {
            throw WireDecodeError(.missingField, field: "hasAssociations")
        }
        self.hasAssociations = ha
        self.updateRate = reader.readInt("updateRate")
    }

    /// Encodes this event into `writer` as a JSON object. `hasAssociations`
    /// is always written; `updateRate` only when present.
    ///
    /// - Parameter writer: The ``WireWriter`` to encode into.
    /// - Throws: ``WireEncodeError`` if the buffer overflows.
    public func encode(to writer: inout WireWriter) throws(WireEncodeError) {
        try writer.beginObject()
        try writer.writeBoolField("hasAssociations", hasAssociations)
        if let rate = updateRate {
            try writer.writeComma()
            try writer.writeIntField("updateRate", rate)
        }
        try writer.endObject()
    }
}
