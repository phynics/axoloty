// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

/// `axoloty/1`-only lexical primitives on the format-neutral wire writer.
///
/// Byte strings, floating point, and semantic tags are CBOR kinds with no JSON
/// token. These accessors let a firmware or long-lived reader project write
/// them through the same facade that writes the JSON profile. The JSON engine
/// rejects each call with ``WireEncodeError/invalidValue``.
extension WireWriter {
    // MARK: - Floating point

    /// Writes a floating-point value as one standalone CBOR item.
    ///
    /// Floating point is an `axoloty/1`-only lexical kind. The value is emitted
    /// in its shortest lossless form (single precision when it round-trips,
    /// otherwise double precision). Use this inside an array; use
    /// ``writeFloatField(_:_:)`` for an object member. The JSON engine has no
    /// floating-point writer, so it throws.
    ///
    /// - Parameter value: The value to encode.
    /// - Throws: ``WireEncodeError/invalidValue`` when the writer emits JSON,
    ///   or ``WireEncodeError/bufferOverflow`` when the buffer is too small.
    public mutating func writeFloat64(_ value: Double) throws(WireEncodeError) {
        guard isCBOR else { throw .invalidValue }
        try cborBeginValueEmission()
        try cborEmit { try $0.writeFloat64(value) }
    }

    /// Writes a key-value pair where the value is a floating-point item.
    ///
    /// - Parameters:
    ///   - key: The member key to write.
    ///   - value: The value to encode.
    /// - Throws: ``WireEncodeError/invalidValue`` when the writer emits JSON,
    ///   or ``WireEncodeError/bufferOverflow`` when the buffer is too small.
    public mutating func writeFloatField(
        _ key: StaticString, _ value: Double
    ) throws(WireEncodeError) {
        guard isCBOR else { throw .invalidValue }
        try cborBeginField(key)
        try cborEmit { try $0.writeFloat64(value) }
    }

    // MARK: - Byte strings

    /// Writes a byte-string value as one standalone CBOR item.
    ///
    /// Byte strings are an `axoloty/1`-only lexical kind. Use this inside an
    /// array; use ``writeByteStringField(_:_:)`` for an object member. The JSON
    /// engine has no byte-string writer, so it throws.
    ///
    /// - Parameter value: The borrowed bytes to encode.
    /// - Throws: ``WireEncodeError/invalidValue`` when the writer emits JSON,
    ///   or ``WireEncodeError/bufferOverflow`` when the buffer is too small.
    public mutating func writeByteString(
        _ value: ByteSlice
    ) throws(WireEncodeError) {
        guard isCBOR else { throw .invalidValue }
        try cborBeginValueEmission()
        try cborEmit { try $0.writeByteString(value) }
    }

    /// Writes a key-value pair where the value is a byte-string item.
    ///
    /// - Parameters:
    ///   - key: The member key to write.
    ///   - value: The borrowed bytes to encode.
    /// - Throws: ``WireEncodeError/invalidValue`` when the writer emits JSON,
    ///   or ``WireEncodeError/bufferOverflow`` when the buffer is too small.
    public mutating func writeByteStringField(
        _ key: StaticString, _ value: ByteSlice
    ) throws(WireEncodeError) {
        guard isCBOR else { throw .invalidValue }
        try cborBeginField(key)
        try cborEmit { try $0.writeByteString(value) }
    }

    // MARK: - Semantic tags

    /// Writes a semantic-tag head as one CBOR item prefix.
    ///
    /// Tags are an `axoloty/1`-only lexical kind. This writes the tag head and
    /// marks the item as open: the next value write emits the tagged item and
    /// does not open a second array chunk. Use ``writeTagField(_:_:)`` for an
    /// object member. The JSON engine has no tag writer, so it throws.
    ///
    /// - Parameter tag: The tag number to encode.
    /// - Throws: ``WireEncodeError/invalidValue`` when the writer emits JSON,
    ///   or ``WireEncodeError/bufferOverflow`` when the buffer is too small.
    public mutating func writeTag(_ tag: UInt64) throws(WireEncodeError) {
        guard isCBOR else { throw .invalidValue }
        try cborBeginValueEmission()
        try cborEmit { try $0.writeTag(tag) }
        cborTagPending = true
    }

    /// Writes a key-value pair whose value begins with a semantic-tag head.
    ///
    /// The next value write emits the tagged item. The JSON engine has no tag
    /// writer, so it throws.
    ///
    /// - Parameters:
    ///   - key: The member key to write.
    ///   - tag: The tag number to encode.
    /// - Throws: ``WireEncodeError/invalidValue`` when the writer emits JSON,
    ///   or ``WireEncodeError/bufferOverflow`` when the buffer is too small.
    public mutating func writeTagField(
        _ key: StaticString, _ tag: UInt64
    ) throws(WireEncodeError) {
        guard isCBOR else { throw .invalidValue }
        try cborBeginField(key)
        try cborEmit { try $0.writeTag(tag) }
        cborTagPending = true
    }
}
