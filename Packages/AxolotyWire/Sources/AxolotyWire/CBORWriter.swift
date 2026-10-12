// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

/// A Foundation-free, deterministic CBOR (RFC 8949) writer.
///
/// The writer encodes into a caller-provided fixed-size buffer without
/// allocating. It emits the shortest possible argument form for every integer,
/// length, and container header, which is the core deterministic encoding rule.
///
/// This is a synchronous scoped-borrow primitive. Keep the writer and every
/// value passed to it inside the caller's buffer scope: do not cross `await`,
/// create a `Task`, hop to an actor or another isolation domain, or capture the
/// writer in an escaping closure. Copy output or input data before any such
/// hop.
public struct CBORWriter: ~Sendable {
    /// The destination buffer the writer encodes into.
    @usableFromInline let buffer: UnsafeMutablePointer<UInt8>
    /// The total capacity of ``buffer`` in bytes.
    public let capacity: Int
    /// The current write offset into ``buffer``.
    public private(set) var position: Int

    /// Creates a writer that encodes CBOR into the given buffer.
    ///
    /// The writer holds the pointer without copying; the caller must ensure
    /// the buffer remains valid for the writer's lifetime.
    ///
    /// - Parameters:
    ///   - buffer: A caller-owned byte buffer the writer encodes into.
    ///   - capacity: The number of bytes available at `buffer`.
    public init(buffer: UnsafeMutablePointer<UInt8>, capacity: Int) {
        self.buffer = buffer
        self.capacity = max(0, capacity)
        self.position = 0
    }

    /// Remaining capacity in the buffer.
    public var remaining: Int { capacity - position }

    /// Rewinds a failed transactional encode to a prior position.
    ///
    /// Bytes after the restored position are outside the writer's logical
    /// output and may be overwritten by the next encode.
    ///
    /// - Parameter position: The prior position to restore.
    public mutating func rewind(to position: Int) {
        guard position >= 0, position <= self.position else { return }
        self.position = position
    }
}

extension CBORWriter {
    // MARK: - Primitive writing

    @inline(__always)
    private mutating func writeByte(_ byte: UInt8) throws(WireEncodeError) {
        guard position < capacity else { throw .bufferOverflow }
        buffer[position] = byte
        position += 1
    }

    private mutating func writeBigEndian(_ value: UInt64, _ count: Int) throws(WireEncodeError) {
        guard count >= 0, count <= 8, remaining >= count else { throw .bufferOverflow }
        var shift = (count - 1) * 8
        for _ in 0..<count {
            buffer[position] = UInt8((value >> shift) & 0xFF)
            position += 1
            shift -= 8
        }
    }

    /// Writes a CBOR head: a major type and its shortest-form argument.
    ///
    /// - Parameters:
    ///   - major: The major type, 0 through 7.
    ///   - argument: The argument value to encode.
    /// - Throws: ``WireEncodeError`` when the major type is invalid or the
    ///   buffer is too small.
    public mutating func writeHead(major: UInt8, argument: UInt64) throws(WireEncodeError) {
        guard major < 8 else { throw .invalidValue }
        let tag = major << 5
        if argument < 24 {
            try writeByte(tag | UInt8(argument))
        } else if argument <= 0xFF {
            try writeByte(tag | 24)
            try writeBigEndian(argument, 1)
        } else if argument <= 0xFFFF {
            try writeByte(tag | 25)
            try writeBigEndian(argument, 2)
        } else if argument <= 0xFFFF_FFFF {
            try writeByte(tag | 26)
            try writeBigEndian(argument, 4)
        } else {
            try writeByte(tag | 27)
            try writeBigEndian(argument, 8)
        }
    }

    // MARK: - Integers

    /// Writes an unsigned integer (CBOR major type 0).
    ///
    /// - Parameter value: The value to encode.
    /// - Throws: ``WireEncodeError`` when the buffer is too small.
    public mutating func writeUnsigned(_ value: UInt64) throws(WireEncodeError) {
        try writeHead(major: 0, argument: value)
    }

    /// Writes a negative integer (CBOR major type 1) for the value `-1 - n`.
    ///
    /// - Parameter value: The argument `n`, not the signed value.
    /// - Throws: ``WireEncodeError`` when the buffer is too small.
    public mutating func writeNegative(_ value: UInt64) throws(WireEncodeError) {
        try writeHead(major: 1, argument: value)
    }

    /// Writes a signed integer in its shortest form.
    ///
    /// - Parameter value: The value to encode.
    /// - Throws: ``WireEncodeError`` when the buffer is too small.
    public mutating func writeInteger(_ value: Int64) throws(WireEncodeError) {
        if value >= 0 {
            try writeHead(major: 0, argument: UInt64(value))
        } else {
            try writeHead(major: 1, argument: UInt64(-(value + 1)))
        }
    }

    // MARK: - Strings

    /// Writes a definite-length byte string (CBOR major type 2).
    ///
    /// - Parameter slice: The borrowed bytes to encode.
    /// - Throws: ``WireEncodeError`` when the buffer is too small.
    public mutating func writeByteString(_ slice: ByteSlice) throws(WireEncodeError) {
        try writeHead(major: 2, argument: UInt64(max(0, slice.length)))
        try append(slice)
    }

    /// Writes a definite-length byte string from a raw pointer.
    ///
    /// - Parameters:
    ///   - bytes: A pointer to the bytes to encode.
    ///   - length: The number of bytes to encode.
    /// - Throws: ``WireEncodeError`` when the length is negative or the buffer
    ///   is too small.
    public mutating func writeByteString(
        bytes: UnsafePointer<UInt8>, length: Int
    ) throws(WireEncodeError) {
        guard length >= 0 else { throw .invalidValue }
        try writeHead(major: 2, argument: UInt64(length))
        guard remaining >= length else { throw .bufferOverflow }
        for index in 0..<length {
            buffer[position + index] = bytes[index]
        }
        position += length
    }

    /// Writes a definite-length text string (CBOR major type 3).
    ///
    /// The caller must supply valid UTF-8; this writer does not re-validate it.
    ///
    /// - Parameter slice: The borrowed UTF-8 bytes to encode.
    /// - Throws: ``WireEncodeError`` when the buffer is too small.
    public mutating func writeTextString(_ slice: ByteSlice) throws(WireEncodeError) {
        try writeHead(major: 3, argument: UInt64(max(0, slice.length)))
        try append(slice)
    }

    // MARK: - Simple values

    /// Writes a boolean (CBOR simple values 20 and 21).
    ///
    /// - Parameter value: The boolean to encode.
    /// - Throws: ``WireEncodeError`` when the buffer is too small.
    public mutating func writeBool(_ value: Bool) throws(WireEncodeError) {
        try writeByte(value ? 0xF5 : 0xF4)
    }

    /// Writes a CBOR null (simple value 22).
    ///
    /// - Throws: ``WireEncodeError`` when the buffer is too small.
    public mutating func writeNull() throws(WireEncodeError) {
        try writeByte(0xF6)
    }

    // MARK: - Containers

    /// Writes an array header (CBOR major type 4).
    ///
    /// - Parameter count: The number of items that follow.
    /// - Throws: ``WireEncodeError`` when the count is negative or the buffer
    ///   is too small.
    public mutating func writeArrayHeader(_ count: Int) throws(WireEncodeError) {
        guard count >= 0 else { throw .invalidValue }
        try writeHead(major: 4, argument: UInt64(count))
    }

    /// Writes a map header (CBOR major type 5).
    ///
    /// - Note: The deterministic profile requires map keys to appear in
    ///   ascending order of their encoded bytes (text keys sort by length
    ///   first, then bytewise). The writer emits the header only; the caller
    ///   owns ordering the key/value pairs that follow.
    ///
    /// - Parameter count: The number of key/value pairs that follow.
    /// - Throws: ``WireEncodeError`` when the count is negative or the buffer
    ///   is too small.
    public mutating func writeMapHeader(_ count: Int) throws(WireEncodeError) {
        guard count >= 0 else { throw .invalidValue }
        try writeHead(major: 5, argument: UInt64(count))
    }

    // MARK: - Tags

    /// Writes a semantic tag (CBOR major type 6).
    ///
    /// - Parameter tag: The tag number to encode.
    /// - Throws: ``WireEncodeError`` when the buffer is too small.
    public mutating func writeTag(_ tag: UInt64) throws(WireEncodeError) {
        try writeHead(major: 6, argument: tag)
    }

    /// Writes a UUID as tag 37 followed by its 16-byte byte string.
    ///
    /// - Parameter uuid: The UUID to encode.
    /// - Throws: ``WireEncodeError`` when the buffer is too small.
    public mutating func writeUUID(_ uuid: UUID16) throws(WireEncodeError) {
        try writeHead(major: 6, argument: 37)
        try writeHead(major: 2, argument: 16)
        let bytes = uuid.bytes
        try writeByte(bytes.0); try writeByte(bytes.1)
        try writeByte(bytes.2); try writeByte(bytes.3)
        try writeByte(bytes.4); try writeByte(bytes.5)
        try writeByte(bytes.6); try writeByte(bytes.7)
        try writeByte(bytes.8); try writeByte(bytes.9)
        try writeByte(bytes.10); try writeByte(bytes.11)
        try writeByte(bytes.12); try writeByte(bytes.13)
        try writeByte(bytes.14); try writeByte(bytes.15)
    }

    // MARK: - Floating point

    /// Writes a floating-point value in its shortest lossless form.
    ///
    /// A value that round-trips through `Float` is written as a single-
    /// precision float; every other value is written as a double. Half-
    /// precision is read but never emitted.
    ///
    /// - Parameter value: The value to encode.
    /// - Throws: ``WireEncodeError`` when the buffer is too small.
    public mutating func writeFloat64(_ value: Double) throws(WireEncodeError) {
        if let single = Self.exactSingleBits(value) {
            try writeByte(0xFA)
            try writeBigEndian(UInt64(single), 4)
        } else {
            try writeByte(0xFB)
            try writeBigEndian(value.bitPattern, 8)
        }
    }

    /// Returns the single-precision bit pattern when `value` is exactly
    /// representable as a `Float`, or `nil` when it needs double precision.
    ///
    /// The check uses bit manipulation rather than `Float(value)` so the
    /// portable code stays free of the compiler-rt float helpers that the
    /// Embedded Swift partial link cannot resolve.
    ///
    /// - Parameter value: The value to test.
    /// - Returns: The single-precision bit pattern, or `nil`.
    private static func exactSingleBits(_ value: Double) -> UInt32? {
        let bits = value.bitPattern
        let sign = UInt32((bits >> 63) & 1) << 31
        let exponent = Int((bits >> 52) & 0x7FF)
        let fraction = bits & 0x000F_FFFF_FFFF_FFFF
        if exponent == 0x7FF {
            return fraction == 0 ? (sign | 0x7F80_0000) : nil
        }
        if exponent == 0 {
            return fraction == 0 ? sign : nil
        }
        let unbiased = exponent - 1023
        if unbiased >= -126 && unbiased <= 127 {
            guard fraction & 0x1FFF_FFFF == 0 else { return nil }
            return sign | (UInt32(unbiased + 127) << 23) | UInt32(fraction >> 29)
        }
        if unbiased >= -149 {
            let drop = 29 + (-126 - unbiased)
            let significand = fraction | 0x0010_0000_0000_0000
            guard (significand & ((UInt64(1) << drop) - 1)) == 0 else { return nil }
            return sign | UInt32(significand >> drop)
        }
        return nil
    }

    // MARK: - Helpers

    private mutating func append(_ slice: ByteSlice) throws(WireEncodeError) {
        guard slice.length >= 0, remaining >= slice.length else { throw .bufferOverflow }
        for index in 0..<slice.length {
            buffer[position + index] = slice.byte(at: index) ?? 0
        }
        position += slice.length
    }
}
