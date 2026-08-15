// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

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
    /// `hasAssociations` is required; `updateRate` is optional and, when
    /// present, must be a non-negative integer. Explicit `null` is treated as
    /// absent for wire compatibility with Codable payloads.
    ///
    /// - Parameter reader: A ``WireReader`` over the JSON payload.
    /// - Throws: ``WireDecodeError`` if `hasAssociations` is missing.
    public init(from reader: WireReader) throws(WireDecodeError) {
        try reader.validate()
        guard reader.readField("hasAssociations") != nil else {
            throw WireDecodeError(.missingField, field: "hasAssociations")
        }
        guard let hasAssociations = reader.readBool("hasAssociations") else {
            throw WireDecodeError(.typeMismatch(expected: "boolean"), field: "hasAssociations")
        }

        let updateRate: Int?
        if let rawUpdateRate = reader.readField("updateRate") {
            if rawUpdateRate.equals("null") {
                updateRate = nil
            } else {
                guard let decodedRate = reader.readInt("updateRate"), decodedRate >= 0 else {
                    throw WireDecodeError(.invalidValue, field: "updateRate")
                }
                updateRate = decodedRate
            }
        } else {
            updateRate = nil
        }

        self.hasAssociations = hasAssociations
        self.updateRate = updateRate
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
