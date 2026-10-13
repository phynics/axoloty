// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyProtocol
import AxolotyWire

/// Builds the host runtime's generated wire envelopes through the
/// profile-aware `AxolotyWire` encoder.
///
/// The host object model stores endpoint metadata as sealed `coaty/3` JSON.
/// A transport bound to `axoloty/1` must publish deterministic CBOR, and
/// Axoloty never transcodes a raw field between profiles
/// (`docs/wire-value-mapping.md`). This type therefore rebuilds each
/// host-generated envelope from typed values through ``WireWriter``: UUIDs
/// become canonical tag-37 byte strings, strings are emitted as UTF-8 text,
/// and integers keep their exact value.
///
/// `coaty/3` JSON is the sealed MQTT byte contract, so
/// ``RuntimeLifecyclePayload`` keeps its existing JSON byte order. The
/// profile-aware ``advertiseEnvelope(object:profile:)`` and
/// ``deadvertise(uuid:profile:)`` serve both profiles, and the JSON forms are
/// byte-identical to the previous literals. The remaining builders produce
/// the `axoloty/1` form directly.
enum RuntimeWirePayload {
    // MARK: - Identity advertise

    /// Builds the `axoloty/1` advertise payload for the runtime identity.
    ///
    /// - Parameter identity: The runtime identity to advertise.
    /// - Returns: The canonical CBOR advertise payload.
    /// - Throws: ``ProtocolError`` when the value cannot be encoded.
    static func cborAdvertise(identity: RuntimeIdentity) throws(ProtocolError) -> [UInt8] {
        let object = try encode(profile: .axoloty1CBOR) { writer in
            try writer.beginObject()
            try writeStringField(&writer, "coreType", "Identity")
            try writer.writeComma()
            try writeStringField(&writer, "name", identity.name)
            try writer.writeComma()
            try writer.writeUUIDField("objectId", identity.id)
            try writer.writeComma()
            try writeStringField(&writer, "objectType", "coaty.Identity")
            try writer.endObject()
        }
        return try advertiseEnvelope(object: object, profile: .axoloty1CBOR)
    }

    // MARK: - Deadvertise

    /// Builds the deadvertise payload for `profile`.
    ///
    /// The single-element identifier array is written through ``WireWriter``,
    /// so the JSON form stays byte-identical to the sealed `coaty/3` literal
    /// and the CBOR form carries a canonical tag-37 byte string.
    ///
    /// - Parameters:
    ///   - uuid: The object identifier to deadvertise.
    ///   - profile: The bound transport profile.
    /// - Returns: The deadvertise payload bytes.
    /// - Throws: ``ProtocolError`` when the value cannot be encoded.
    static func deadvertise(uuid: UUID16, profile: WireProfile) throws(ProtocolError) -> [UInt8] {
        let objectIds = try encode(profile: profile, capacity: 64) { writer in
            try writer.beginArray()
            try writer.writeUUIDValue(uuid)
            try writer.endArray()
        }
        let fields: OwnedDeadvertiseWireData
        do throws(WireDecodeError) {
            fields = try OwnedDeadvertiseWireData(profile: profile, objectIds: objectIds)
        } catch {
            throw ProtocolError(.malformedPayload)
        }
        do throws(WireEncodeError) {
            return try OwnedWireEvent.deadvertise(fields).encodedBytes(capacity: 128)
        } catch {
            throw protocolError(error)
        }
    }

    // MARK: - Advertise envelope

    /// Wraps one complete object in the advertise envelope for `profile`.
    ///
    /// - Parameters:
    ///   - object: The complete object bytes in `profile`'s encoding.
    ///   - profile: The bound transport profile.
    /// - Returns: The advertise payload bytes.
    /// - Throws: ``ProtocolError`` when the object is malformed or too large.
    static func advertiseEnvelope(object: [UInt8], profile: WireProfile) throws(ProtocolError) -> [UInt8] {
        let fields: OwnedAdvertiseWireData
        do throws(WireDecodeError) {
            fields = try OwnedAdvertiseWireData(profile: profile, object: object, privateData: nil)
        } catch {
            throw ProtocolError(.malformedPayload)
        }
        do throws(WireEncodeError) {
            return try OwnedWireEvent.advertise(fields).encodedBytes()
        } catch {
            throw protocolError(error)
        }
    }

    // MARK: - Conformance payloads

    /// Builds an empty object in `profile`'s encoding.
    ///
    /// - Parameter profile: The bound transport profile.
    /// - Returns: `{}` for JSON or the empty CBOR map.
    /// - Throws: ``ProtocolError`` when the value cannot be encoded.
    static func emptyObject(profile: WireProfile) throws(ProtocolError) -> [UInt8] {
        try encode(profile: profile, capacity: 8) { writer in
            try writer.beginObject()
            try writer.endObject()
        }
    }

    /// Builds an empty array in `profile`'s encoding.
    ///
    /// - Parameter profile: The bound transport profile.
    /// - Returns: `[]` for JSON or the empty CBOR array.
    /// - Throws: ``ProtocolError`` when the value cannot be encoded.
    static func emptyArray(profile: WireProfile) throws(ProtocolError) -> [UInt8] {
        try encode(profile: profile, capacity: 8) { writer in
            try writer.beginArray()
            try writer.endArray()
        }
    }

    /// Builds the `axoloty/1` conformance error object.
    ///
    /// - Parameters:
    ///   - code: The numeric remote-error code.
    ///   - message: The remote-error message.
    /// - Returns: A canonical CBOR object with `code` and `message`.
    /// - Throws: ``ProtocolError`` when the value cannot be encoded.
    static func cborErrorObject(code: UInt16, message: String) throws(ProtocolError) -> [UInt8] {
        try encode(profile: .axoloty1CBOR) { writer in
            try writer.beginObject()
            try writer.writeIntField("code", Int(code))
            try writer.writeComma()
            try writeStringField(&writer, "message", message)
            try writer.endObject()
        }
    }

    // MARK: - IO endpoint metadata object

    /// Rebuilds one host-owned IO endpoint metadata object as deterministic
    /// CBOR from its sealed `coaty/3` JSON bytes.
    ///
    /// The encoder walks the stored object's top-level fields and writes each
    /// known envelope or IO metadata field through ``WireWriter``. It rejects
    /// an unknown field with ``ProtocolError/Code/malformedPayload`` instead of
    /// dropping it: silently losing a caller field would change the advertised
    /// object. The IO metadata schema is fixed and first-party, so an unknown
    /// field is a caller defect, not a peer shape to tolerate.
    ///
    /// - Parameter storedJSON: The endpoint metadata object as canonical JSON.
    /// - Returns: The canonical CBOR object.
    /// - Throws: ``ProtocolError`` when the object is malformed, carries an
    ///   unknown field, or does not fit the bounded payload buffer.
    static func cborIoEndpointObject(storedJSON: BoundedIoBytes<2048>) throws(ProtocolError) -> [UInt8] {
        return try encode(profile: .axoloty1CBOR) { writer in
            try writer.beginObject()
            var failure: WireEncodeError?
            storedJSON.withBytes { bytes in
                bytes.withBytes { pointer, count in
                    let reader = WireCodec(profile: .coaty3JSON).reader(
                        bytes: pointer.assumingMemoryBound(to: UInt8.self),
                        length: count
                    )
                    do throws(WireDecodeError) { try reader.validate() } catch {
                        failure = .invalidValue
                        return
                    }
                    do throws(WireDecodeError) {
                        try reader.withObjectFields { field in
                            guard failure == nil else { return }
                            do throws(WireEncodeError) {
                                try writeIOField(field, reader: reader, writer: &writer)
                            } catch {
                                failure = error
                            }
                        }
                    } catch {
                        failure = failure ?? .invalidValue
                    }
                }
            }
            if let failure { throw failure }
            try writer.endObject()
        }
    }

    // MARK: - Private encoding

    /// Encodes one value into a new, exactly sized byte array.
    private static func encode(
        profile: WireProfile,
        capacity: Int = WireBufferConfig.maxPayloadSize,
        _ body: (inout WireWriter) throws -> Void
    ) throws(ProtocolError) -> [UInt8] {
        var output = [UInt8](repeating: 0, count: capacity)
        var length = 0
        var failure: WireEncodeError?
        output.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else {
                failure = .bufferOverflow
                return
            }
            var writer = WireCodec(profile: profile).writer(buffer: base, capacity: buffer.count)
            do {
                try body(&writer)
                length = writer.position
            } catch let error as WireEncodeError {
                failure = error
            } catch {
                failure = .invalidValue
            }
        }
        if let failure { throw protocolError(failure) }
        output.removeSubrange(length..<output.count)
        return output
    }

    /// Writes one plain UTF-8 string field from a Swift string.
    private static func writeStringField(
        _ writer: inout WireWriter,
        _ key: StaticString,
        _ value: String
    ) throws(WireEncodeError) {
        let utf8 = Array(value.utf8)
        var failure: WireEncodeError?
        utf8.withUnsafeBufferPointer { buffer in
            do throws(WireEncodeError) {
                if let base = buffer.baseAddress {
                    try writer.writeStringField(key, ByteSlice(bytes: base, length: buffer.count))
                } else {
                    try writer.writeStringField(key, ByteSlice.empty)
                }
            } catch {
                failure = error
            }
        }
        if let failure { throw failure }
    }

    /// Writes one known envelope or IO metadata field.
    private static func writeIOField(
        _ field: borrowing WireObjectField,
        reader: WireReader,
        writer: inout WireWriter
    ) throws(WireEncodeError) {
        if field.kind == .null {
            if field.keyEquals("externalId") { try writer.writeNullField("externalId") }
            else if field.keyEquals("parentObjectId") { try writer.writeNullField("parentObjectId") }
            else if field.keyEquals("locationId") { try writer.writeNullField("locationId") }
            else if field.keyEquals("isDeactivated") { try writer.writeNullField("isDeactivated") }
            else if field.keyEquals("updateStrategy") { try writer.writeNullField("updateStrategy") }
            else if field.keyEquals("useRawIoValues") { try writer.writeNullField("useRawIoValues") }
            else if field.keyEquals("updateRate") { try writer.writeNullField("updateRate") }
            else if field.keyEquals("externalRoute") { try writer.writeNullField("externalRoute") }
            else { throw .invalidValue }
            return
        }
        if field.keyEquals("objectId") {
            guard let value = reader.readUUID("objectId") else { throw .invalidValue }
            try writer.writeUUIDField("objectId", value)
        } else if field.keyEquals("parentObjectId") {
            guard let value = reader.readUUID("parentObjectId") else { throw .invalidValue }
            try writer.writeUUIDField("parentObjectId", value)
        } else if field.keyEquals("locationId") {
            guard let value = reader.readUUID("locationId") else { throw .invalidValue }
            try writer.writeUUIDField("locationId", value)
        } else if field.keyEquals("isDeactivated") {
            guard let value = reader.readBool("isDeactivated") else { throw .invalidValue }
            try writer.writeBoolField("isDeactivated", value)
        } else if field.keyEquals("useRawIoValues") {
            guard let value = reader.readBool("useRawIoValues") else { throw .invalidValue }
            try writer.writeBoolField("useRawIoValues", value)
        } else if field.keyEquals("updateStrategy") {
            guard let value = reader.readInt("updateStrategy") else { throw .invalidValue }
            try writer.writeIntField("updateStrategy", value)
        } else if field.keyEquals("updateRate") {
            guard let value = reader.readInt("updateRate") else { throw .invalidValue }
            try writer.writeIntField("updateRate", value)
        } else if field.keyEquals("objectType") {
            try writeDecodedStringField(&writer, "objectType", reader: reader)
        } else if field.keyEquals("name") {
            try writeDecodedStringField(&writer, "name", reader: reader)
        } else if field.keyEquals("coreType") {
            try writeDecodedStringField(&writer, "coreType", reader: reader)
        } else if field.keyEquals("externalId") {
            try writeDecodedStringField(&writer, "externalId", reader: reader)
        } else if field.keyEquals("valueType") {
            try writeDecodedStringField(&writer, "valueType", reader: reader)
        } else if field.keyEquals("externalRoute") {
            try writeDecodedStringField(&writer, "externalRoute", reader: reader)
        } else {
            throw .invalidValue
        }
    }

    /// Decodes one JSON string field and writes it as plain UTF-8 text.
    private static func writeDecodedStringField(
        _ writer: inout WireWriter,
        _ key: StaticString,
        reader: WireReader
    ) throws(WireEncodeError) {
        guard let content = reader.readString(key) else { throw .invalidValue }
        var decoded = InlineArray<2048, UInt8>(repeating: 0)
        let count: Int
        do throws(WireDecodeError) {
            count = try WireCodec(profile: .coaty3JSON).copyDecodedString(content, into: &decoded)
        } catch {
            throw .invalidValue
        }
        var failure: WireEncodeError?
        withUnsafeBytes(of: &decoded) { raw in
            guard let base = raw.baseAddress else {
                failure = .invalidValue
                return
            }
            do throws(WireEncodeError) {
                try writer.writeStringField(
                    key,
                    ByteSlice(bytes: base.assumingMemoryBound(to: UInt8.self), length: count)
                )
            } catch {
                failure = error
            }
        }
        if let failure { throw failure }
    }

    /// Maps one writer failure onto the structured protocol error.
    private static func protocolError(_ error: WireEncodeError) -> ProtocolError {
        switch error {
        case .bufferOverflow: return ProtocolError(.capacityExceeded)
        case .invalidValue, .profileMismatch: return ProtocolError(.malformedPayload)
        }
    }
}
