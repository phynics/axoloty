// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

// Foundation-free wire DTOs for Coaty communication event data.
//
// These are the shared host and static event-data boundary. They use `UUID16`
// and `ByteSlice`, with no Foundation dependency, class hierarchy, or Codable
// reflection. Package tests exercise their exact raw-value preservation and
// structured boundary failures through `WireReader` and `WireWriter`.

// MARK: - AssociateEventData

/// Wire DTO mirroring `AssociateEventData`, decoded via ``WireReader``
/// and encoded via ``WireWriter``.
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
    /// - Parameter reader: A ``WireReader`` over the payload bytes.
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

    /// Encodes this event into `writer` as an object.
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
/// as a raw payload fragment in the active profile's format.
public struct AdvertiseWireData: WireDecodable, WireEncodable, Equatable {
    /// The raw wire bytes of the advertised object.
    public let object: ByteSlice
    /// The optional private data as raw wire bytes.
    public let privateData: ByteSlice?

    /// Decodes an advertise event from `reader`.
    ///
    /// `object` is required; `privateData` is optional.
    ///
    /// - Parameter reader: A ``WireReader`` over the payload bytes.
    /// - Throws: ``WireDecodeError`` if the `object` field is missing.
    public init(from reader: WireReader) throws(WireDecodeError) {
        try reader.validate()
        guard let obj = reader.readField("object") else {
            throw WireDecodeError(.missingField, field: "object")
        }
        self.object = obj
        self.privateData = reader.readOptionalRaw("privateData")
    }

    /// Encodes this event into `writer` as an object wrapping `object`,
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
    /// The raw wire bytes of the `objectIds` array (an array of UUID items
    /// in the active profile's format).
    public let objectIds: ByteSlice

    /// Decodes a deadvertise event from `reader`, capturing the `objectIds`
    /// array as raw wire bytes so the host can decode the original UUID
    /// items without normalizing them through ``UUID16``.
    ///
    /// - Parameter reader: A ``WireReader`` over the payload bytes.
    /// - Throws: ``WireDecodeError`` if the `objectIds` field is missing.
    public init(from reader: WireReader) throws(WireDecodeError) {
        try reader.validate()
        guard let ids = reader.readField("objectIds") else {
            throw WireDecodeError(.missingField, field: "objectIds")
        }
        self.objectIds = ids
    }

    /// Encodes this event into `writer`, serializing `objectIds` as an
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
/// raw payload fragment in the active profile's format.
///
/// The raw `payload` is authoritative and preserves the peer's exact bytes.
/// The typed views below expose the `axoloty/1`-only lexical kinds the JSON
/// profile cannot carry (floating point, byte string, tag) so a first-party
/// caller can consume them without constructing a `CBORReader`. Every view is
/// derived from the same `payload` field and is `nil` under `coaty/3` JSON,
/// which has no such token and leaves the raw bytes untouched.
public struct IoValueWireData: WireDecodable, WireEncodable, Equatable {
    /// The raw wire bytes of the IO value payload.
    public let payload: ByteSlice

    /// The `payload` widened to `Double` when it is an `axoloty/1` CBOR
    /// floating-point item.
    ///
    /// Floating point is `axoloty/1`-only, so this is `nil` for `coaty/3` JSON
    /// and for a non-floating-point CBOR payload.
    public let floatPayload: Double?

    /// The borrowed content of the `payload` when it is an `axoloty/1` CBOR
    /// byte string, without the encoding head.
    ///
    /// Byte strings are `axoloty/1`-only, so this is `nil` for `coaty/3` JSON
    /// and for a non-byte-string CBOR payload. An empty byte string yields
    /// ``ByteSlice/empty`` rather than `nil`.
    public let byteStringPayload: ByteSlice?

    /// The semantic-tag number of a tagged `payload`, when it is an
    /// `axoloty/1` CBOR tagged item.
    ///
    /// This is the tag number, not the tagged item. Tags are `axoloty/1`-only,
    /// so this is `nil` for `coaty/3` JSON and for a non-tagged CBOR payload.
    public let tagPayload: UInt64?

    /// Decodes an IoValue event from `reader`.
    ///
    /// - Parameter reader: A ``WireReader`` over the payload bytes.
    /// - Throws: ``WireDecodeError`` if the `payload` field is missing.
    public init(from reader: WireReader) throws(WireDecodeError) {
        try reader.validate()
        guard let p = reader.readField("payload") else {
            throw WireDecodeError(.missingField, field: "payload")
        }
        self.payload = p
        self.floatPayload = reader.readFloat("payload")
        self.byteStringPayload = reader.readByteString("payload")
        self.tagPayload = reader.readTag("payload")
    }

    /// Encodes this event into `writer` as an object wrapping `payload`.
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
    /// The optional channel object as raw wire bytes.
    public let object: ByteSlice?
    /// The optional array of channel objects as raw wire bytes.
    public let objects: ByteSlice?
    /// The optional private data as raw wire bytes.
    public let privateData: ByteSlice?

    /// Decodes a channel event from `reader`.
    ///
    /// `object`, `objects`, and `privateData` are all optional; absent fields
    /// default to nil.
    ///
    /// - Parameter reader: A ``WireReader`` over the payload bytes.
    public init(from reader: WireReader) throws(WireDecodeError) {
        try reader.validate()
        self.object = reader.readOptionalRaw("object")
        self.objects = reader.readOptionalRaw("objects")
        self.privateData = reader.readOptionalRaw("privateData")
    }

    /// Encodes this event into `writer` as an object, writing only the
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
    /// The optional external ID as raw wire bytes (a string value).
    public let externalId: ByteSlice?
    /// The optional object UUID as raw wire bytes (a string value).
    public let objectId: ByteSlice?
    /// The optional object types filter as raw wire bytes (an array value).
    public let objectTypes: ByteSlice?
    /// The optional core types filter as raw wire bytes (an array value).
    public let coreTypes: ByteSlice?

    /// Decodes a discover event from `reader`.
    ///
    /// All fields are optional; absent fields default to nil.
    ///
    /// - Parameter reader: A ``WireReader`` over the payload bytes.
    public init(from reader: WireReader) throws(WireDecodeError) {
        try reader.validate()
        self.externalId = reader.readString("externalId")
        self.objectId = reader.readString("objectId")
        self.objectTypes = reader.readOptionalRaw("objectTypes")
        self.coreTypes = reader.readOptionalRaw("coreTypes")
    }

    /// Encodes this event into `writer` as an object, writing only the
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
    /// The optional object types filter as raw wire bytes.
    public let objectTypes: ByteSlice?
    /// The optional core types filter as raw wire bytes.
    public let coreTypes: ByteSlice?
    /// The optional object filter as raw wire bytes.
    public let objectFilter: ByteSlice?
    /// The optional join conditions as raw wire bytes (an array of
    /// objects).
    public let objectJoinConditions: ByteSlice?

    /// Decodes a query event from `reader`.
    ///
    /// All fields are optional; absent fields default to nil.
    ///
    /// - Parameter reader: A ``WireReader`` over the payload bytes.
    public init(from reader: WireReader) throws(WireDecodeError) {
        try reader.validate()
        self.objectTypes = reader.readOptionalRaw("objectTypes")
        self.coreTypes = reader.readOptionalRaw("coreTypes")
        self.objectFilter = reader.readOptionalRaw("objectFilter")
        self.objectJoinConditions = reader.readOptionalRaw("objectJoinConditions")
    }

    /// Encodes this event into `writer` as an object, writing only the
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
    /// The operation parameters as raw wire bytes.
    public let parameters: ByteSlice?
    /// The optional context filter as raw wire bytes.
    public let filter: ByteSlice?

    /// Decodes a call event from `reader`.
    ///
    /// `parameters` and `filter` are optional. The topic carries the operation
    /// name; the legacy `operationType` member is accepted and ignored.
    ///
    /// - Parameter reader: A ``WireReader`` over the payload bytes.
    /// - Throws: ``WireDecodeError`` if the payload is malformed.
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
