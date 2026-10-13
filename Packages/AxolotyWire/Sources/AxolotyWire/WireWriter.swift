// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

/// A Foundation-free, format-neutral wire writer that writes into a
/// caller-provided buffer.
///
/// The default engine emits JSON exactly as before: no String or Array is
/// allocated and the caller provides a fixed-size byte buffer. A writer
/// constructed through ``WireCodec`` with ``WireProfile/axoloty1CBOR`` instead
/// emits deterministic CBOR (RFC 8949 §4.2.1): definite lengths, shortest-form
/// heads, and map keys in ascending order of their encoded bytes. Both
/// engines serve the same writer method names, so every wire DTO encodes
/// both profiles from one implementation.
///
/// This is a synchronous scoped-borrow primitive. Keep the writer and every
/// value passed to it within the caller's buffer scope: do not cross `await`,
/// create a `Task`, hop to an actor or another isolation domain, or capture the
/// writer in an escaping closure. Copy output or input data before any such
/// hop.
public struct WireWriter {
    /// The destination buffer the writer encodes into.
    @usableFromInline let buffer: UnsafeMutablePointer<UInt8>
    /// The total capacity of ``buffer`` in bytes.
    public let capacity: Int
    /// The current write offset into ``buffer``.
    public private(set) var position: Int
    /// Whether this writer emits deterministic CBOR instead of JSON.
    @usableFromInline var isCBOR: Bool

    /// The open CBOR container, if any.
    @usableFromInline var cborContainer: CBORContainer = .none
    /// The offset of the reserved CBOR container head byte.
    @usableFromInline var cborReservedHead = 0
    /// The number of indexed CBOR chunks (map pairs or array items).
    @usableFromInline var cborChunkCount = 0
    /// The destination offset where each CBOR chunk starts.
    ///
    /// `InlineArray` requires a literal count, so this mirrors
    /// ``WireBufferConfig/maxIndexedFields``. ``cborWriteKey(_:)`` enforces
    /// the configuration constant and never indexes past this storage.
    @usableFromInline var cborChunkStarts = InlineArray<24, Int>(repeating: 0)
    /// Whether the open CBOR map awaits its value emission.
    @usableFromInline var cborExpectingValue = false

    /// The CBOR container kinds the facade can build.
    @usableFromInline enum CBORContainer: UInt8 {
        /// No container is open.
        case none
        /// A map opened by ``beginObject()``.
        case map
        /// An array opened by ``beginArray()``.
        case array
    }

    /// Creates a writer that encodes JSON into the given buffer.
    ///
    /// The writer holds the pointer without copying; the caller must ensure
    /// the buffer remains valid for the writer's lifetime.
    ///
    /// - Parameters:
    ///   - buffer: A caller-owned byte buffer the writer encodes into.
    ///   - capacity: The number of bytes available at `buffer`.
    public init(buffer: UnsafeMutablePointer<UInt8>, capacity: Int) {
        self.buffer = buffer
        self.capacity = capacity
        self.position = 0
        self.isCBOR = false
    }

    /// Creates a writer that encodes deterministic CBOR into the given buffer.
    ///
    /// Construct profile-selected writers through ``WireCodec`` rather than
    /// this engine initializer.
    ///
    /// - Parameters:
    ///   - buffer: A caller-owned byte buffer the writer encodes into.
    ///   - capacity: The number of bytes available at `buffer`.
    @usableFromInline
    init(cborBuffer: UnsafeMutablePointer<UInt8>, capacity: Int) {
        self.buffer = cborBuffer
        self.capacity = capacity
        self.position = 0
        self.isCBOR = true
    }

    /// Remaining capacity in the buffer.
    public var remaining: Int { capacity - position }

    /// The wire profile whose encoding this writer emits.
    public var profile: WireProfile { isCBOR ? .axoloty1CBOR : .coaty3JSON }

    /// Rewinds a failed transactional encode to a prior position.
    ///
    /// Bytes after the restored position are outside the writer's logical
    /// output and may be overwritten by the next encode. Rewinding a CBOR
    /// writer also abandons any open container.
    public mutating func rewind(to position: Int) {
        guard position >= 0, position <= self.position else { return }
        self.position = position
        if isCBOR { cborResetContainer() }
    }
}

extension WireWriter {
    // MARK: - Value writing

    /// Writes an object (JSON) or map (CBOR) opening token.
    ///
    /// The CBOR engine reserves the single-byte map head and patches the pair
    /// count at ``endObject()``. Only one container may be open at a time;
    /// nested containers must be pre-encoded and spliced with
    /// ``writeTrustedRawField(_:_:)`` or ``writeRawField(_:_:)``.
    public mutating func beginObject() throws(WireEncodeError) {
        if isCBOR {
            try cborBeginContainer(.map)
            return
        }
        try writeByte(0x7B)
    }

    /// Writes an object (JSON) or map (CBOR) closing token.
    ///
    /// The CBOR engine orders the map's key/value chunks by the deterministic
    /// key order and rejects duplicate keys before patching the map head.
    public mutating func endObject() throws(WireEncodeError) {
        if isCBOR {
            try cborEndContainer(.map)
            return
        }
        try writeByte(0x7D)
    }

    /// Writes an array opening token.
    ///
    /// The CBOR engine reserves the single-byte array head and patches the
    /// item count at ``endArray()``. Array items are emitted one per value
    /// write; field writes are rejected inside an array.
    public mutating func beginArray() throws(WireEncodeError) {
        if isCBOR {
            try cborBeginContainer(.array)
            return
        }
        try writeByte(0x5B)
    }

    /// Writes an array closing token.
    public mutating func endArray() throws(WireEncodeError) {
        if isCBOR {
            try cborEndContainer(.array)
            return
        }
        try writeByte(0x5D)
    }

    /// Writes a comma separator.
    ///
    /// JSON separates members with a comma; CBOR items are self-delimiting,
    /// so the CBOR engine treats this as a no-op.
    public mutating func writeComma() throws(WireEncodeError) {
        if isCBOR { return }
        try writeByte(0x2C)
    }

    // MARK: - Internal

    /// Writes an object member key and leaves the writer ready for its value.
    ///
    /// The JSON engine writes `"key":`. The CBOR engine records the chunk
    /// offset and writes the text-string key item.
    public mutating func writeKey(_ key: StaticString) throws(WireEncodeError) {
        if isCBOR {
            try cborWriteKey(key)
            return
        }
        try writeByte(0x22) // '"'
        try writeBytes(key)
        try writeByte(0x22) // '"'
        try writeByte(0x3A) // ':'
    }

    @inline(__always)
    private mutating func writeByte(_ byte: UInt8) throws(WireEncodeError) {
        guard position < capacity else { throw .bufferOverflow }
        buffer[position] = byte
        position += 1
    }

    @inline(__always)
    private mutating func writeBytes(_ staticString: StaticString) throws(WireEncodeError) {
        let len = staticString.utf8CodeUnitCount
        guard len >= 0, len <= capacity - position else { throw .bufferOverflow }
        for i in 0..<len {
            buffer[position + i] = staticString.utf8Start[i]
        }
        position += len
    }

    @inline(__always)
    private mutating func writeByteSlice(_ slice: ByteSlice) throws(WireEncodeError) {
        guard slice.length >= 0, slice.length <= capacity - position else { throw .bufferOverflow }
        for i in 0..<slice.length {
            buffer[position + i] = slice.byte(at: i)!
        }
        position += slice.length
    }

    @inline(__always)
    private mutating func advancePosition(by count: Int) throws(WireEncodeError) {
        guard count >= 0, count <= capacity - position else { throw .bufferOverflow }
        position += count
    }

    /// Writes one complete, already encoded value.
    ///
    /// The JSON engine validates the fragment as JSON; the CBOR engine
    /// validates it as one complete deterministic CBOR item.
    public mutating func writeRawValue(_ value: ByteSlice) throws(WireEncodeError) {
        if isCBOR {
            try cborValidateCompleteItem(value)
            try cborBeginValueEmission()
            try writeByteSlice(value)
            return
        }
        #if canImport(_JSONCore)
        guard WireReader.isValidJSON(value) else { throw .invalidValue }
        try writeByteSlice(value)
        #else
        throw WireEncodeError.invalidValue
        #endif
    }

    /// Writes one string value from encoded string-content bytes.
    ///
    /// The JSON engine treats the bytes as encoded JSON string content; the
    /// CBOR engine treats them as plain UTF-8 text content.
    public mutating func writeEncodedStringValue(_ value: ByteSlice) throws(WireEncodeError) {
        if isCBOR {
            try cborBeginValueEmission()
            try cborWriteTextString(value)
            return
        }
        guard Self.isValidUTF8(value) else { throw .invalidValue }
        try writeByte(0x22)
        var index = 0
        while index < value.length {
            let byte = value.byte(at: index)!
            try writeEncodedByte(byte, value: value, index: &index)
            index += 1
        }
        try writeByte(0x22)
    }

    /// Writes a key-value pair where the value is a string.
    public mutating func writeStringField(
        _ key: StaticString, _ value: ByteSlice
    ) throws(WireEncodeError) {
        if isCBOR {
            try cborBeginField(key)
            try cborWriteTextString(value)
            return
        }
        try writePlainStringField(key, value)
    }

    /// Writes a key-value pair where the value is a raw fragment
    /// (number, object, array, etc.) in the active profile's format.
    public mutating func writeRawField(
        _ key: StaticString, _ value: ByteSlice
    ) throws(WireEncodeError) {
        if isCBOR {
            try cborValidateCompleteItem(value)
            try cborBeginField(key)
            try writeByteSlice(value)
            return
        }
        #if canImport(_JSONCore)
        guard WireReader.isValidJSON(value) else { throw .invalidValue }
        try writeKey(key)
        try writeByteSlice(value)
        #else
        throw WireEncodeError.invalidValue
        #endif
    }

    /// Writes a raw fragment previously validated by ``WireReader``.
    /// Borrowed DTO fields use this path because their slice may begin at an
    /// unaligned offset inside the caller's input buffer.
    @usableFromInline
    mutating func writeTrustedRawField(_ key: StaticString, _ value: ByteSlice) throws(WireEncodeError) {
        if isCBOR {
            try cborBeginField(key)
            try writeByteSlice(value)
            return
        }
        try writeKey(key)
        try writeByteSlice(value)
    }

    /// Writes a UTF-8 byte slice as a string value, escaping the characters
    /// the active profile requires.
    public mutating func writeEscapedStringField(
        _ key: StaticString, _ value: ByteSlice
    ) throws(WireEncodeError) {
        if isCBOR {
            try cborBeginField(key)
            try cborWriteTextString(value)
            return
        }
        try writePlainStringField(key, value)
    }

    /// Writes already encoded string content as a string field.
    ///
    /// The input must be valid UTF-8 and, on the JSON engine, contain valid
    /// JSON escape sequences. The bytes are consumed synchronously and copied
    /// into the writer's caller-owned output buffer.
    public mutating func writeEncodedStringField(
        _ key: StaticString, _ value: ByteSlice
    ) throws(WireEncodeError) {
        if isCBOR {
            try cborBeginField(key)
            try cborWriteTextString(value)
            return
        }
        try writeKey(key)
        try writeEncodedStringValue(value)
    }

    private mutating func writeEncodedByte(
        _ byte: UInt8, value: ByteSlice, index: inout Int
    ) throws(WireEncodeError) {
        switch byte {
        case 0x08: try writeBytes("\\b")
        case 0x09: try writeBytes("\\t")
        case 0x0A: try writeBytes("\\n")
        case 0x0C: try writeBytes("\\f")
        case 0x0D: try writeBytes("\\r")
        case 0x22: try writeByte(0x5C); try writeByte(byte)
        case 0x5C: try writeEncodedEscape(value, index: &index)
        case 0..<0x20:
            try writeBytes("\\u00")
            try writeByte(Self.hexChar(byte >> 4)); try writeByte(Self.hexChar(byte & 0xF))
        default: try writeByte(byte)
        }
    }

    private mutating func writeEncodedEscape(_ value: ByteSlice, index: inout Int) throws(WireEncodeError) {
        guard index + 1 < value.length else { throw .invalidValue }
        let escaped = value.byte(at: index + 1)!
        guard escaped == 0x22 || escaped == 0x5C || escaped == 0x2F || escaped == 0x62 ||
              escaped == 0x66 || escaped == 0x6E || escaped == 0x72 || escaped == 0x74 || escaped == 0x75
        else { throw .invalidValue }
        try writeByte(0x5C); try writeByte(escaped)
        index += 1
        if escaped == 0x75 { try writeUnicodeEscape(value, index: &index) }
    }

    private mutating func writeUnicodeEscape(_ value: ByteSlice, index: inout Int) throws(WireEncodeError) {
        guard index + 4 < value.length, let first = Self.hexValue(value, start: index + 1) else {
            throw .invalidValue
        }
        for offset in 1...4 { try writeByte(value.byte(at: index + offset)!) }
        index += 4
        guard first < 0xD800 || first > 0xDFFF else {
            if first >= 0xD800 && first <= 0xDBFF {
                try writeSurrogateEscape(value, index: &index)
            } else {
                throw .invalidValue
            }
            return
        }
    }

    private mutating func writeSurrogateEscape(_ value: ByteSlice, index: inout Int) throws(WireEncodeError) {
        guard index + 6 < value.length,
              value.byte(at: index + 1) == 0x5C,
              value.byte(at: index + 2) == 0x75,
              let second = Self.hexValue(value, start: index + 3),
              second >= 0xDC00, second <= 0xDFFF
        else { throw .invalidValue }
        try writeByte(0x5C); try writeByte(0x75)
        for offset in 3...6 { try writeByte(value.byte(at: index + offset)!) }
        index += 6
    }

    private mutating func writePlainStringField(
        _ key: StaticString, _ value: ByteSlice
    ) throws(WireEncodeError) {
        guard Self.isValidUTF8(value) else { throw .invalidValue }
        try writeKey(key); try writeByte(0x22)
        for index in 0..<value.length {
            let byte = value.byte(at: index)!
            switch byte {
            case 0x08: try writeBytes("\\b")
            case 0x09: try writeBytes("\\t")
            case 0x0A: try writeBytes("\\n")
            case 0x0C: try writeBytes("\\f")
            case 0x0D: try writeBytes("\\r")
            case 0x22, 0x5C: try writeByte(0x5C); try writeByte(byte)
            case 0..<0x20: try writeBytes("\\u00"); try writeByte(Self.hexChar(byte >> 4)); try writeByte(Self.hexChar(byte & 0xF))
            default: try writeByte(byte)
            }
        }
        try writeByte(0x22)
    }

    /// Writes a key-value pair where the value is an integer.
    public mutating func writeIntField(
        _ key: StaticString, _ value: Int
    ) throws(WireEncodeError) {
        if isCBOR {
            try cborBeginField(key)
            try cborWriteInteger(Int64(value))
            return
        }
        try writeKey(key)
        try writeInt(value)
    }

    /// Writes a key-value pair where the value is a boolean.
    public mutating func writeBoolField(
        _ key: StaticString, _ value: Bool
    ) throws(WireEncodeError) {
        if isCBOR {
            try cborBeginField(key)
            try writeByte(value ? 0xF5 : 0xF4)
            return
        }
        try writeKey(key)
        if value {
            try writeBytes("true")
        } else {
            try writeBytes("false")
        }
    }

    /// Writes a key-value pair where the value is null.
    public mutating func writeNullField(
        _ key: StaticString
    ) throws(WireEncodeError) {
        if isCBOR {
            try cborBeginField(key)
            try writeByte(0xF6)
            return
        }
        try writeKey(key)
        try writeBytes("null")
    }

    /// Writes a key-value pair where the value is a UUID.
    ///
    /// The JSON engine writes the canonical hyphenated string. The CBOR
    /// engine writes the canonical tag-37 16-byte byte string.
    public mutating func writeUUIDField(
        _ key: StaticString, _ value: UUID16
    ) throws(WireEncodeError) {
        if isCBOR {
            try cborBeginField(key)
            try cborWriteUUID(value)
            return
        }
        try writeKey(key)
        try writeByte(0x22) // '"'
        try writeUUID(value)
        try writeByte(0x22)
    }

    /// Writes an integer value.
    ///
    /// - Parameter value: The integer to encode.
    /// - Throws: ``WireEncodeError`` if the destination buffer is too small.
    public mutating func writeInt(_ value: Int) throws(WireEncodeError) {
        if isCBOR {
            try cborBeginValueEmission()
            try cborWriteInteger(Int64(value))
            return
        }
        if value == 0 {
            try writeByte(0x30)
            return
        }
        var v = value
        if v < 0 {
            try writeByte(0x2D) // '-'
            // Handle Int.min: |Int.min| can't be represented as positive Int.
            // Use unsigned arithmetic to avoid the overflow.
            // On 64-bit: UInt(bitPattern: Int.min) = 9223372036854775808
            // On 32-bit: UInt(bitPattern: Int.min) = 2147483648
            if v == Int.min {
                // Convert to the unsigned representation of the absolute value.
                let absVal = UInt(bitPattern: v)
                try writeUInt(absVal)
                return
            }
            v = -v
        }
        // Count digits
        var temp = v
        var digitCount = 0
        while temp > 0 { temp /= 10; digitCount += 1 }
        guard position + digitCount <= capacity else { throw .bufferOverflow }
        // Write digits in reverse
        for i in stride(from: digitCount - 1, through: 0, by: -1) {
            buffer[position + i] = 0x30 + UInt8(v % 10)
            v /= 10
        }
        try advancePosition(by: digitCount)
    }

    /// Writes an unsigned integer JSON value.
    ///
    /// - Parameter value: The unsigned integer to encode.
    /// - Throws: ``WireEncodeError`` if the destination buffer is too small.
    private mutating func writeUInt(_ value: UInt) throws(WireEncodeError) {
        if value == 0 {
            try writeByte(0x30)
            return
        }
        var v = value
        var digitCount = 0
        var temp = v
        while temp > 0 { temp /= 10; digitCount += 1 }
        guard position + digitCount <= capacity else { throw .bufferOverflow }
        for i in stride(from: digitCount - 1, through: 0, by: -1) {
            buffer[position + i] = 0x30 + UInt8(v % 10)
            v /= 10
        }
        try advancePosition(by: digitCount)
    }

    /// Writes a UUID value.
    ///
    /// - Parameter value: The UUID to encode.
    /// - Throws: ``WireEncodeError`` if the destination buffer is too small.
    public mutating func writeUUID(_ value: UUID16) throws(WireEncodeError) {
        if isCBOR {
            try cborBeginValueEmission()
            try cborWriteUUID(value)
            return
        }
        // Format: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx (36 chars).
        // Unrolled against a static nibble→hex mapping so no Array or Set
        // is allocated on the encode hot path.
        guard position + 36 <= capacity else { throw .bufferOverflow }
        let b = value.bytes
        let p = position
        buffer[p] = Self.hexChar(b.0 >> 4); buffer[p + 1] = Self.hexChar(b.0 & 0xF)
        buffer[p + 2] = Self.hexChar(b.1 >> 4); buffer[p + 3] = Self.hexChar(b.1 & 0xF)
        buffer[p + 4] = Self.hexChar(b.2 >> 4); buffer[p + 5] = Self.hexChar(b.2 & 0xF)
        buffer[p + 6] = Self.hexChar(b.3 >> 4); buffer[p + 7] = Self.hexChar(b.3 & 0xF)
        buffer[p + 8] = 0x2D // '-'
        buffer[p + 9] = Self.hexChar(b.4 >> 4); buffer[p + 10] = Self.hexChar(b.4 & 0xF)
        buffer[p + 11] = Self.hexChar(b.5 >> 4); buffer[p + 12] = Self.hexChar(b.5 & 0xF)
        buffer[p + 13] = 0x2D
        buffer[p + 14] = Self.hexChar(b.6 >> 4); buffer[p + 15] = Self.hexChar(b.6 & 0xF)
        buffer[p + 16] = Self.hexChar(b.7 >> 4); buffer[p + 17] = Self.hexChar(b.7 & 0xF)
        buffer[p + 18] = 0x2D
        buffer[p + 19] = Self.hexChar(b.8 >> 4); buffer[p + 20] = Self.hexChar(b.8 & 0xF)
        buffer[p + 21] = Self.hexChar(b.9 >> 4); buffer[p + 22] = Self.hexChar(b.9 & 0xF)
        buffer[p + 23] = 0x2D
        buffer[p + 24] = Self.hexChar(b.10 >> 4); buffer[p + 25] = Self.hexChar(b.10 & 0xF)
        buffer[p + 26] = Self.hexChar(b.11 >> 4); buffer[p + 27] = Self.hexChar(b.11 & 0xF)
        buffer[p + 28] = Self.hexChar(b.12 >> 4); buffer[p + 29] = Self.hexChar(b.12 & 0xF)
        buffer[p + 30] = Self.hexChar(b.13 >> 4); buffer[p + 31] = Self.hexChar(b.13 & 0xF)
        buffer[p + 32] = Self.hexChar(b.14 >> 4); buffer[p + 33] = Self.hexChar(b.14 & 0xF)
        buffer[p + 34] = Self.hexChar(b.15 >> 4); buffer[p + 35] = Self.hexChar(b.15 & 0xF)
        try advancePosition(by: 36)
    }

    @inline(__always)
    private static func hexChar(_ nibble: UInt8) -> UInt8 {
        nibble < 10 ? 0x30 + nibble : 0x61 + (nibble - 10)
    }

    private static func isValidUTF8(_ value: ByteSlice) -> Bool {
        value.isValidUTF8()
    }

    private static func hexValue(_ value: ByteSlice, start: Int) -> Int? {
        guard start >= 0, start + 4 <= value.length else { return nil }
        var result = 0
        for offset in 0..<4 {
            guard let byte = value.byte(at: start + offset) else { return nil }
            let digit: Int
            switch byte {
            case 0x30...0x39: digit = Int(byte - 0x30)
            case 0x41...0x46: digit = Int(byte - 0x41) + 10
            case 0x61...0x66: digit = Int(byte - 0x61) + 10
            default: return nil
            }
            result = result * 16 + digit
        }
        return result
    }
}

// MARK: - CBOR engine

extension WireWriter {
    /// Opens one CBOR container and reserves its head byte.
    ///
    /// A container of at most ``WireBufferConfig/maxIndexedFields`` chunks
    /// needs a single-byte head, so the head is reserved on open and patched
    /// with the exact count on close. Only one container may be open at a
    /// time; a nested container must be pre-encoded and spliced instead.
    private mutating func cborBeginContainer(_ kind: CBORContainer) throws(WireEncodeError) {
        guard cborContainer == .none else { throw .invalidValue }
        try writeByte(kind == .map ? 0xA0 : 0x80)
        cborReservedHead = position - 1
        cborContainer = kind
        cborChunkCount = 0
        cborExpectingValue = false
    }

    /// Closes the open CBOR container and patches its head.
    ///
    /// Maps are first ordered by the deterministic key order and checked for
    /// duplicate keys. A chunk count above 23 needs the two-byte head, which
    /// shifts the container's chunks one byte to the right.
    private mutating func cborEndContainer(_ kind: CBORContainer) throws(WireEncodeError) {
        guard cborContainer == kind else { throw .invalidValue }
        if kind == .map {
            try cborOrderMapChunks()
        }
        let count = cborChunkCount
        if count < 24 {
            buffer[cborReservedHead] = (kind == .map ? 0xA0 : 0x80) | UInt8(count)
        } else {
            guard position < capacity else { throw .bufferOverflow }
            var index = position - 1
            while index > cborReservedHead {
                buffer[index + 1] = buffer[index]
                index -= 1
            }
            buffer[cborReservedHead] = kind == .map ? 0xB8 : 0x98
            buffer[cborReservedHead + 1] = UInt8(count)
            position += 1
        }
        cborResetContainer()
    }

    /// Abandons the open CBOR container, if any.
    private mutating func cborResetContainer() {
        cborContainer = .none
        cborReservedHead = 0
        cborChunkCount = 0
        cborExpectingValue = false
    }

    /// Writes one CBOR map key and records its chunk offset.
    ///
    /// Keys are invalid inside an array, so a key emission inside an array
    /// container is rejected.
    private mutating func cborWriteKey(_ key: StaticString) throws(WireEncodeError) {
        if cborContainer == .none {
            try cborWriteTextHead(key.utf8CodeUnitCount)
            try writeBytes(key)
            return
        }
        guard cborContainer == .map else { throw .invalidValue }
        guard cborChunkCount < WireBufferConfig.maxIndexedFields else { throw .invalidValue }
        cborChunkStarts[cborChunkCount] = position
        cborChunkCount += 1
        try cborWriteTextHead(key.utf8CodeUnitCount)
        try writeBytes(key)
        cborExpectingValue = true
    }

    /// Opens the value emission of the current chunk.
    ///
    /// Inside a map the emission must follow a key; inside an array every
    /// value emission is one item and starts a new chunk.
    private mutating func cborBeginValueEmission() throws(WireEncodeError) {
        guard cborContainer != .none else { return }
        if cborContainer == .map {
            guard cborExpectingValue else { throw .invalidValue }
            cborExpectingValue = false
        } else {
            guard cborChunkCount < WireBufferConfig.maxIndexedFields else { throw .invalidValue }
            cborChunkStarts[cborChunkCount] = position
            cborChunkCount += 1
        }
    }

    /// Writes one field key and opens its value emission.
    private mutating func cborBeginField(_ key: StaticString) throws(WireEncodeError) {
        try cborWriteKey(key)
        try cborBeginValueEmission()
    }

    /// Writes a CBOR head with its shortest-form argument.
    private mutating func cborWriteHead(major: UInt8, argument: UInt64) throws(WireEncodeError) {
        guard major < 8 else { throw .invalidValue }
        let tag = major << 5
        if argument < 24 {
            try writeByte(tag | UInt8(argument))
        } else if argument <= 0xFF {
            try writeByte(tag | 24)
            try writeByte(UInt8(argument))
        } else if argument <= 0xFFFF {
            try writeByte(tag | 25)
            try writeByte(UInt8((argument >> 8) & 0xFF))
            try writeByte(UInt8(argument & 0xFF))
        } else if argument <= 0xFFFF_FFFF {
            try writeByte(tag | 26)
            for shift in stride(from: 24, through: 0, by: -8) {
                try writeByte(UInt8((argument >> UInt64(shift)) & 0xFF))
            }
        } else {
            try writeByte(tag | 27)
            for shift in stride(from: 56, through: 0, by: -8) {
                try writeByte(UInt8((argument >> UInt64(shift)) & 0xFF))
            }
        }
    }

    /// Writes an integer in its shortest CBOR form.
    private mutating func cborWriteInteger(_ value: Int64) throws(WireEncodeError) {
        if value >= 0 {
            try cborWriteHead(major: 0, argument: UInt64(value))
        } else {
            try cborWriteHead(major: 1, argument: UInt64(-(value + 1)))
        }
    }

    /// Writes a text-string item from plain UTF-8 content bytes.
    private mutating func cborWriteTextString(_ content: ByteSlice) throws(WireEncodeError) {
        guard content.isValidUTF8() else { throw .invalidValue }
        try cborWriteTextHead(max(0, content.length))
        try writeByteSlice(content)
    }

    /// Writes a text-string head with its shortest-form length.
    private mutating func cborWriteTextHead(_ length: Int) throws(WireEncodeError) {
        if length < 24 {
            try writeByte(0x60 | UInt8(length))
        } else if length <= 0xFF {
            try writeByte(0x78)
            try writeByte(UInt8(length))
        } else if length <= 0xFFFF {
            try writeByte(0x79)
            try writeByte(UInt8((length >> 8) & 0xFF))
            try writeByte(UInt8(length & 0xFF))
        } else {
            try writeByte(0x7A)
            let wide = UInt32(length)
            for shift in stride(from: 24, through: 0, by: -8) {
                try writeByte(UInt8((wide >> UInt32(shift)) & 0xFF))
            }
        }
    }

    /// Writes a UUID as its canonical tag-37 16-byte byte string.
    private mutating func cborWriteUUID(_ value: UUID16) throws(WireEncodeError) {
        try cborWriteHead(major: 6, argument: 37)
        try cborWriteHead(major: 2, argument: 16)
        let b = value.bytes
        try writeByte(b.0); try writeByte(b.1)
        try writeByte(b.2); try writeByte(b.3)
        try writeByte(b.4); try writeByte(b.5)
        try writeByte(b.6); try writeByte(b.7)
        try writeByte(b.8); try writeByte(b.9)
        try writeByte(b.10); try writeByte(b.11)
        try writeByte(b.12); try writeByte(b.13)
        try writeByte(b.14); try writeByte(b.15)
    }

    /// Validates that a borrowed fragment is one complete deterministic CBOR item.
    private mutating func cborValidateCompleteItem(_ value: ByteSlice) throws(WireEncodeError) {
        let complete = value.withBytes { pointer, count in
            var reader = CBORReader(bytes: pointer.assumingMemoryBound(to: UInt8.self), length: count)
            guard (try? reader.skipItem()) != nil else { return false }
            return reader.isAtEnd
        }
        guard complete else { throw .invalidValue }
    }

    /// Orders the open map's chunks by the deterministic key order.
    ///
    /// RFC 8949 §4.2.1 orders map keys bytewise over their encoded forms.
    /// The insertion sort swaps adjacent chunks with three in-place reversals,
    /// so no scratch storage is allocated, and rejects duplicate keys.
    private mutating func cborOrderMapChunks() throws(WireEncodeError) {
        guard cborChunkCount > 1 else { return }
        var chunks = InlineArray<24, Range<Int>>(repeating: 0..<0)
        for index in 0..<cborChunkCount {
            let upper = index + 1 < cborChunkCount ? cborChunkStarts[index + 1] : position
            chunks[index] = cborChunkStarts[index]..<upper
        }
        var index = 1
        while index < cborChunkCount {
            var candidate = index
            var settled = false
            while candidate > 0 && !settled {
                switch cborEncodedKeyOrder(chunks[candidate], chunks[candidate - 1]) {
                case .less:
                    cborSwapAdjacentChunks(&chunks, candidate - 1, candidate)
                    candidate -= 1
                case .equal:
                    throw .invalidValue
                case .greater:
                    settled = true
                }
            }
            index += 1
        }
    }

    /// Swaps two adjacent chunks in the destination buffer with three
    /// in-place reversals and updates the recorded chunk ranges.
    private mutating func cborSwapAdjacentChunks(
        _ chunks: inout InlineArray<24, Range<Int>>, _ left: Int, _ right: Int
    ) {
        let leftRange = chunks[left]
        let rightRange = chunks[right]
        cborReverse(leftRange)
        cborReverse(rightRange)
        cborReverse(leftRange.lowerBound..<rightRange.upperBound)
        chunks[left] = leftRange.lowerBound..<(leftRange.lowerBound + rightRange.count)
        chunks[right] = (leftRange.lowerBound + rightRange.count)..<rightRange.upperBound
    }

    /// Reverses one byte range of the destination buffer in place.
    private mutating func cborReverse(_ range: Range<Int>) {
        var left = range.lowerBound
        var right = range.upperBound - 1
        while left < right {
            let temporary = buffer[left]
            buffer[left] = buffer[right]
            buffer[right] = temporary
            left += 1
            right -= 1
        }
    }

    /// The relative order of two encoded map keys.
    private enum CBORKeyOrder {
        case less
        case equal
        case greater
    }

    /// Compares two chunks' encoded key items bytewise.
    ///
    /// A shared prefix orders the shorter key first, which matches RFC 8949
    /// §4.2.1 because the text-string head encodes the content length before
    /// the content. Equal encoded keys are duplicates.
    private func cborEncodedKeyOrder(_ lhs: Range<Int>, _ rhs: Range<Int>) -> CBORKeyOrder {
        guard let leftKey = cborEncodedKeyRange(of: lhs),
              let rightKey = cborEncodedKeyRange(of: rhs) else {
            return .equal
        }
        var offset = 0
        while offset < leftKey.count && offset < rightKey.count {
            let left = buffer[leftKey.lowerBound + offset]
            let right = buffer[rightKey.lowerBound + offset]
            if left != right { return left < right ? .less : .greater }
            offset += 1
        }
        if leftKey.count == rightKey.count { return .equal }
        return leftKey.count < rightKey.count ? .less : .greater
    }

    /// Returns the encoded key range of one chunk.
    ///
    /// Chunks are opened by ``cborWriteKey(_:)``, so the chunk always begins
    /// with a text-string head. A defensive parse failure maps to the
    /// duplicate-key rejection, because the writer's own state is malformed.
    private func cborEncodedKeyRange(of chunk: Range<Int>) -> Range<Int>? {
        let start = chunk.lowerBound
        guard start < chunk.upperBound, start >= 0 else { return nil }
        let initial = buffer[start]
        guard initial >> 5 == 3 else { return nil }
        let additional = initial & 0x1F
        let headLength: Int
        let contentLength: Int
        switch additional {
        case 0...23:
            headLength = 1
            contentLength = Int(additional)
        case 24:
            guard start + 1 < chunk.upperBound else { return nil }
            headLength = 2
            contentLength = Int(buffer[start + 1])
        case 25:
            guard start + 2 < chunk.upperBound else { return nil }
            headLength = 3
            contentLength = (Int(buffer[start + 1]) << 8) | Int(buffer[start + 2])
        case 26:
            guard start + 4 < chunk.upperBound else { return nil }
            let wide = (UInt64(buffer[start + 1]) << 24) | (UInt64(buffer[start + 2]) << 16) |
                (UInt64(buffer[start + 3]) << 8) | UInt64(buffer[start + 4])
            guard wide <= UInt64(Int.max) else { return nil }
            headLength = 5
            contentLength = Int(wide)
        case 27:
            guard start + 8 < chunk.upperBound else { return nil }
            var wide: UInt64 = 0
            for offset in 1...8 {
                wide = (wide << 8) | UInt64(buffer[start + offset])
            }
            guard wide <= UInt64(Int.max) else { return nil }
            headLength = 9
            contentLength = Int(wide)
        default:
            return nil
        }
        guard contentLength >= 0, start + headLength + contentLength <= chunk.upperBound else { return nil }
        return start..<(start + headLength + contentLength)
    }
}

/// Encode error for the wire writer.
public enum WireEncodeError: Error, Sendable, Equatable {
    /// The encoded output would exceed the writer's ``WireWriter/capacity``.
    case bufferOverflow
    /// The value cannot be represented in the wire format.
    case invalidValue
    /// The raw bytes carry a profile other than the one the writer emits, so
    /// re-encoding them would silently transcode or corrupt the payload.
    case profileMismatch
}
