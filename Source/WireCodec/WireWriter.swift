// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

/// A Foundation-free JSON writer that writes into a caller-provided buffer.
///
/// No String or Array is allocated — the caller provides a fixed-size byte
/// buffer and the writer encodes JSON directly into it. Designed for the
/// wire encode hot path.
public struct WireWriter {
    /// The destination buffer the writer encodes into.
    @usableFromInline let buffer: UnsafeMutablePointer<UInt8>
    /// The total capacity of ``buffer`` in bytes.
    public let capacity: Int
    /// The current write offset into ``buffer``.
    public private(set) var position: Int

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
    }

    /// Remaining capacity in the buffer.
    public var remaining: Int { capacity - position }

    // MARK: - Value writing

    /// Writes a JSON object opening brace.
    public mutating func beginObject() throws(WireEncodeError) {
        try writeByte(0x7B)
    }

    /// Writes a JSON object closing brace.
    public mutating func endObject() throws(WireEncodeError) {
        try writeByte(0x7D)
    }

    /// Writes a comma separator.
    public mutating func writeComma() throws(WireEncodeError) {
        try writeByte(0x2C)
    }

    /// Writes a key-value pair where the value is a JSON string.
    public mutating func writeStringField(
        _ key: StaticString, _ value: ByteSlice
    ) throws(WireEncodeError) {
        try writeKey(key)
        try writeByte(0x22) // '"'
        try writeByteSlice(value)
        try writeByte(0x22) // '"'
    }

    /// Writes a key-value pair where the value is a raw JSON fragment
    /// (number, object, array, etc.).
    public mutating func writeRawField(
        _ key: StaticString, _ value: ByteSlice
    ) throws(WireEncodeError) {
        try writeKey(key)
        try writeByteSlice(value)
    }

    /// Writes a key-value pair where the value is an integer.
    public mutating func writeIntField(
        _ key: StaticString, _ value: Int
    ) throws(WireEncodeError) {
        try writeKey(key)
        try writeInt(value)
    }

    /// Writes a key-value pair where the value is a boolean.
    public mutating func writeBoolField(
        _ key: StaticString, _ value: Bool
    ) throws(WireEncodeError) {
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
        try writeKey(key)
        try writeBytes("null")
    }

    /// Writes a key-value pair where the value is a UUID (as a JSON string).
    public mutating func writeUUIDField(
        _ key: StaticString, _ value: UUID16
    ) throws(WireEncodeError) {
        try writeKey(key)
        try writeByte(0x22) // '"'
        try writeUUID(value)
        try writeByte(0x22) // '"'
    }

    // MARK: - Internal

    @inline(__always)
    mutating func writeKey(_ key: StaticString) throws(WireEncodeError) {
        try writeByte(0x22) // '"'
        try writeBytes(key)
        try writeByte(0x22) // '"'
        try writeByte(0x3A) // ':'
    }

    @inline(__always)
    mutating func writeByte(_ byte: UInt8) throws(WireEncodeError) {
        guard position < capacity else { throw .bufferOverflow }
        buffer[position] = byte
        position += 1
    }

    @inline(__always)
    mutating func writeBytes(_ staticString: StaticString) throws(WireEncodeError) {
        let len = staticString.utf8CodeUnitCount
        guard position + len <= capacity else { throw .bufferOverflow }
        for i in 0..<len {
            buffer[position + i] = staticString.utf8Start[i]
        }
        position += len
    }

    @inline(__always)
    mutating func writeByteSlice(_ slice: ByteSlice) throws(WireEncodeError) {
        guard position + slice.length <= capacity else { throw .bufferOverflow }
        for i in 0..<slice.length {
            buffer[position + i] = slice.byte(at: i)!
        }
        position += slice.length
    }

    mutating func writeInt(_ value: Int) throws(WireEncodeError) {
        if value == 0 {
            try writeByte(0x30)
            return
        }
        var v = value
        if v < 0 {
            try writeByte(0x2D) // '-'
            // Handle Int.min: |Int.min| can't be represented as positive Int.
            // Write the absolute value digits manually.
            if v == Int.min {
                // Int.min = -9223372036854775808 (on 64-bit)
                try writeBytes("9223372036854775808")
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
        position += digitCount
    }

    mutating func writeUUID(_ value: UUID16) throws(WireEncodeError) {
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
        position += 36
    }

    @inline(__always)
    private static func hexChar(_ nibble: UInt8) -> UInt8 {
        nibble < 10 ? 0x30 + nibble : 0x61 + (nibble - 10)
    }
}

/// Encode error for the wire writer.
public enum WireEncodeError: Error, Sendable {
    /// The encoded output would exceed the writer's ``WireWriter/capacity``.
    case bufferOverflow
    /// The value cannot be represented in the wire format.
    case invalidValue
}
