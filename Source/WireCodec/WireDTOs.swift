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

public struct AssociateWireData: WireDecodable, WireEncodable, Equatable {
    public let ioSourceId: UUID16
    public let ioActorId: UUID16
    public let associatingRoute: ByteSlice?
    public let isExternalRoute: Bool?
    public let updateRate: Int?

    public init(from reader: WireReader) throws(WireDecodeError) {
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

    public func encode(to writer: inout WireWriter) throws(WireEncodeError) {
        try writer.beginObject()
        try writer.writeUUIDField("ioSourceId", ioSourceId)
        try writer.writeComma()
        try writer.writeUUIDField("ioActorId", ioActorId)
        if let route = associatingRoute {
            try writer.writeComma()
            try writer.writeStringField("associatingRoute", route)
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

public struct AdvertiseWireData: WireDecodable, WireEncodable, Equatable {
    public let object: ByteSlice

    public init(from reader: WireReader) throws(WireDecodeError) {
        guard let obj = reader.readRaw("object") else {
            throw WireDecodeError(.missingField, field: "object")
        }
        self.object = obj
    }

    public func encode(to writer: inout WireWriter) throws(WireEncodeError) {
        try writer.beginObject()
        try writer.writeRawField("object", object)
        try writer.endObject()
    }
}

// MARK: - DeadvertiseEventData

public struct DeadvertiseWireData: WireDecodable, WireEncodable, Equatable {
    public let objectIds: [UUID16]

    public init(from reader: WireReader) throws(WireDecodeError) {
        guard let idsSlice = reader.readRaw("objectIds") else {
            throw WireDecodeError(.missingField, field: "objectIds")
        }
        var ids: [UUID16] = []
        idsSlice.withBytes { ptr, len in
            var i = 0
            while i < len && ptr.load(fromByteOffset: i, as: UInt8.self) != 0x5B { i += 1 }
            i += 1
            while i < len {
                while i < len {
                    let b = ptr.load(fromByteOffset: i, as: UInt8.self)
                    if b == 0x20 || b == 0x2C || b == 0x0A { i += 1 } else { break }
                }
                if i >= len { break }
                let b = ptr.load(fromByteOffset: i, as: UInt8.self)
                if b == 0x5D { break }
                if b == 0x22 {
                    i += 1
                    let start = i
                    while i < len && ptr.load(fromByteOffset: i, as: UInt8.self) != 0x22 { i += 1 }
                    let uuidSlice = ByteSlice(pointer: ptr.advanced(by: start), length: i - start)
                    if let uuid = UUID16(parsing: uuidSlice) { ids.append(uuid) }
                    i += 1
                } else { i += 1 }
            }
        }
        self.objectIds = ids
    }

    public func encode(to writer: inout WireWriter) throws(WireEncodeError) {
        try writer.beginObject()
        try writer.writeBytes("\"objectIds\":[")
        for (i, id) in objectIds.enumerated() {
            if i > 0 { try writer.writeComma() }
            try writer.writeByte(0x22)
            try writer.writeUUID(id)
            try writer.writeByte(0x22)
        }
        try writer.writeBytes("]")
        try writer.endObject()
    }

    public static func == (lhs: DeadvertiseWireData, rhs: DeadvertiseWireData) -> Bool {
        lhs.objectIds == rhs.objectIds
    }
}

// MARK: - IoValueEventData

public struct IoValueWireData: WireDecodable, WireEncodable, Equatable {
    public let payload: ByteSlice

    public init(from reader: WireReader) throws(WireDecodeError) {
        guard let p = reader.readRaw("payload") else {
            throw WireDecodeError(.missingField, field: "payload")
        }
        self.payload = p
    }

    public func encode(to writer: inout WireWriter) throws(WireEncodeError) {
        try writer.beginObject()
        try writer.writeRawField("payload", payload)
        try writer.endObject()
    }
}

// MARK: - ChannelEventData

public struct ChannelWireData: WireDecodable, WireEncodable, Equatable {
    public let object: ByteSlice?
    public let privateData: ByteSlice?

    public init(from reader: WireReader) throws(WireDecodeError) {
        self.object = reader.readRaw("object")
        self.privateData = reader.readRaw("privateData")
    }

    public func encode(to writer: inout WireWriter) throws(WireEncodeError) {
        try writer.beginObject()
        if let obj = object {
            try writer.writeRawField("object", obj)
        }
        if let pd = privateData {
            if object != nil { try writer.writeComma() }
            try writer.writeRawField("privateData", pd)
        }
        try writer.endObject()
    }

    public static func == (lhs: ChannelWireData, rhs: ChannelWireData) -> Bool {
        lhs.object == rhs.object && lhs.privateData == rhs.privateData
    }
}

// MARK: - DiscoverEventData

public struct DiscoverWireData: WireDecodable, WireEncodable, Equatable {
    public let objectTypes: ByteSlice?
    public let coreTypes: ByteSlice?
    public let objectFilter: ByteSlice?
    public let external: Bool?

    public init(from reader: WireReader) throws(WireDecodeError) {
        self.objectTypes = reader.readRaw("objectTypes")
        self.coreTypes = reader.readRaw("coreTypes")
        self.objectFilter = reader.readRaw("objectFilter")
        self.external = reader.readBool("external")
    }

    public func encode(to writer: inout WireWriter) throws(WireEncodeError) {
        try writer.beginObject()
        var first = true
        if let ot = objectTypes {
            if !first { try writer.writeComma() }; first = false
            try writer.writeRawField("objectTypes", ot)
        }
        if let ct = coreTypes {
            if !first { try writer.writeComma() }; first = false
            try writer.writeRawField("coreTypes", ct)
        }
        if let of = objectFilter {
            if !first { try writer.writeComma() }; first = false
            try writer.writeRawField("objectFilter", of)
        }
        if let ext = external {
            if !first { try writer.writeComma() }; first = false
            try writer.writeBoolField("external", ext)
        }
        try writer.endObject()
    }
}

// MARK: - QueryEventData

public struct QueryWireData: WireDecodable, WireEncodable, Equatable {
    public let objectTypes: ByteSlice?
    public let coreTypes: ByteSlice?
    public let objectFilter: ByteSlice?
    public let external: Bool?

    public init(from reader: WireReader) throws(WireDecodeError) {
        self.objectTypes = reader.readRaw("objectTypes")
        self.coreTypes = reader.readRaw("coreTypes")
        self.objectFilter = reader.readRaw("objectFilter")
        self.external = reader.readBool("external")
    }

    public func encode(to writer: inout WireWriter) throws(WireEncodeError) {
        try writer.beginObject()
        var first = true
        if let ot = objectTypes {
            if !first { try writer.writeComma() }; first = false
            try writer.writeRawField("objectTypes", ot)
        }
        if let ct = coreTypes {
            if !first { try writer.writeComma() }; first = false
            try writer.writeRawField("coreTypes", ct)
        }
        if let of = objectFilter {
            if !first { try writer.writeComma() }; first = false
            try writer.writeRawField("objectFilter", of)
        }
        if let ext = external {
            if !first { try writer.writeComma() }; first = false
            try writer.writeBoolField("external", ext)
        }
        try writer.endObject()
    }
}

// MARK: - CallEventData

public struct CallWireData: WireDecodable, WireEncodable, Equatable {
    public let operationType: ByteSlice
    public let parameters: ByteSlice?
    public let timeout: Int?

    public init(from reader: WireReader) throws(WireDecodeError) {
        guard let opType = reader.readString("operationType") else {
            throw WireDecodeError(.missingField, field: "operationType")
        }
        self.operationType = opType
        self.parameters = reader.readRaw("parameters")
        self.timeout = reader.readInt("timeout")
    }

    public func encode(to writer: inout WireWriter) throws(WireEncodeError) {
        try writer.beginObject()
        try writer.writeStringField("operationType", operationType)
        if let params = parameters {
            try writer.writeComma()
            try writer.writeRawField("parameters", params)
        }
        if let t = timeout {
            try writer.writeComma()
            try writer.writeIntField("timeout", t)
        }
        try writer.endObject()
    }
}

// MARK: - ReturnEventData

public struct ReturnWireData: WireDecodable, WireEncodable, Equatable {
    public let result: ByteSlice?
    public let executionInfo: ByteSlice?
    public let status: ByteSlice?

    public init(from reader: WireReader) throws(WireDecodeError) {
        self.result = reader.readRaw("result")
        self.executionInfo = reader.readRaw("executionInfo")
        self.status = reader.readString("status")
    }

    public func encode(to writer: inout WireWriter) throws(WireEncodeError) {
        try writer.beginObject()
        var first = true
        if let r = result {
            if !first { try writer.writeComma() }; first = false
            try writer.writeRawField("result", r)
        }
        if let ei = executionInfo {
            if !first { try writer.writeComma() }; first = false
            try writer.writeRawField("executionInfo", ei)
        }
        if let s = status {
            if !first { try writer.writeComma() }; first = false
            try writer.writeStringField("status", s)
        }
        try writer.endObject()
    }
}

// MARK: - ResolveEventData

public struct ResolveWireData: WireDecodable, WireEncodable, Equatable {
    public let object: ByteSlice
    public let privateData: ByteSlice?

    public init(from reader: WireReader) throws(WireDecodeError) {
        guard let obj = reader.readRaw("object") else {
            throw WireDecodeError(.missingField, field: "object")
        }
        self.object = obj
        self.privateData = reader.readRaw("privateData")
    }

    public func encode(to writer: inout WireWriter) throws(WireEncodeError) {
        try writer.beginObject()
        try writer.writeRawField("object", object)
        if let pd = privateData {
            try writer.writeComma()
            try writer.writeRawField("privateData", pd)
        }
        try writer.endObject()
    }
}

// MARK: - RetrieveEventData

public struct RetrieveWireData: WireDecodable, WireEncodable, Equatable {
    public let object: ByteSlice

    public init(from reader: WireReader) throws(WireDecodeError) {
        guard let obj = reader.readRaw("object") else {
            throw WireDecodeError(.missingField, field: "object")
        }
        self.object = obj
    }

    public func encode(to writer: inout WireWriter) throws(WireEncodeError) {
        try writer.beginObject()
        try writer.writeRawField("object", object)
        try writer.endObject()
    }
}

// MARK: - UpdateEventData

public struct UpdateWireData: WireDecodable, WireEncodable, Equatable {
    public let object: ByteSlice

    public init(from reader: WireReader) throws(WireDecodeError) {
        guard let obj = reader.readRaw("object") else {
            throw WireDecodeError(.missingField, field: "object")
        }
        self.object = obj
    }

    public func encode(to writer: inout WireWriter) throws(WireEncodeError) {
        try writer.beginObject()
        try writer.writeRawField("object", object)
        try writer.endObject()
    }
}

// MARK: - CompleteEventData

public struct CompleteWireData: WireDecodable, WireEncodable, Equatable {
    public let object: ByteSlice?
    public let completed: Bool?

    public init(from reader: WireReader) throws(WireDecodeError) {
        self.object = reader.readRaw("object")
        self.completed = reader.readBool("completed")
    }

    public func encode(to writer: inout WireWriter) throws(WireEncodeError) {
        try writer.beginObject()
        var first = true
        if let obj = object {
            if !first { try writer.writeComma() }; first = false
            try writer.writeRawField("object", obj)
        }
        if let comp = completed {
            if !first { try writer.writeComma() }; first = false
            try writer.writeBoolField("completed", comp)
        }
        try writer.endObject()
    }
}

// MARK: - IoStateEventData

public struct IoStateWireData: WireDecodable, WireEncodable, Equatable {
    public let hasAssociations: Bool
    public let updateRate: Int?

    public init(from reader: WireReader) throws(WireDecodeError) {
        guard let ha = reader.readBool("hasAssociations") else {
            throw WireDecodeError(.missingField, field: "hasAssociations")
        }
        self.hasAssociations = ha
        self.updateRate = reader.readInt("updateRate")
    }

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
