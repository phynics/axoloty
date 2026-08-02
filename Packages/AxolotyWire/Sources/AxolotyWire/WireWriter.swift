// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

/// A Foundation-free JSON writer that writes into a caller-provided buffer.
///
/// No String or Array is allocated — the caller provides a fixed-size byte
/// buffer and the writer encodes JSON directly into it. Designed for the
/// wire encode hot path.
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
        try writePlainStringField(key, value)
    }

    /// Writes a key-value pair where the value is a raw JSON fragment
    /// (number, object, array, etc.).
    public mutating func writeRawField(
        _ key: StaticString, _ value: ByteSlice
    ) throws(WireEncodeError) {
        guard WireReader.isValidJSON(value) else { throw .invalidValue }
        try writeKey(key)
        try writeByteSlice(value)
    }

    /// Writes a raw fragment previously validated by ``WireReader``.
    /// Borrowed DTO fields use this path because their slice may begin at an
    /// unaligned offset inside the caller's input buffer.
    @usableFromInline
    mutating func writeTrustedRawField(_ key: StaticString, _ value: ByteSlice) throws(WireEncodeError) {
        try writeKey(key)
        try writeByteSlice(value)
    }

    /// Writes a UTF-8 byte slice as a JSON string, escaping quotes, reverse
    /// solidus, controls, and the standard JSON control escapes.
    public mutating func writeEscapedStringField(
        _ key: StaticString, _ value: ByteSlice
    ) throws(WireEncodeError) {
        try writePlainStringField(key, value)
    }

    /// Writes validated string content already containing JSON escapes.
    @usableFromInline
    mutating func writeEncodedStringField(
        _ key: StaticString, _ value: ByteSlice
    ) throws(WireEncodeError) {
        guard Self.isValidUTF8(value) else { throw .invalidValue }
        try writeKey(key)
        try writeByte(0x22)
        var index = 0
        while index < value.length {
            let byte = value.byte(at: index)!
            switch byte {
            case 0x08: try writeBytes("\\b")
            case 0x09: try writeBytes("\\t")
            case 0x0A: try writeBytes("\\n")
            case 0x0C: try writeBytes("\\f")
            case 0x0D: try writeBytes("\\r")
            case 0x22:
                try writeByte(0x5C); try writeByte(byte)
            case 0x5C:
                guard index + 1 < value.length else { throw .invalidValue }
                let escaped = value.byte(at: index + 1)!
                guard escaped == 0x22 || escaped == 0x5C || escaped == 0x2F || escaped == 0x62 || escaped == 0x66 || escaped == 0x6E || escaped == 0x72 || escaped == 0x74 || escaped == 0x75 else { throw .invalidValue }
                try writeByte(0x5C); try writeByte(escaped); index += 1
                if escaped == 0x75 {
                    guard index + 4 < value.length,
                          let first = Self.hexValue(value, start: index + 1)
                    else { throw .invalidValue }
                    for offset in 1...4 { try writeByte(value.byte(at: index + offset)!) }
                    index += 4
                    if first >= 0xD800 && first <= 0xDBFF {
                        guard index + 6 < value.length,
                              value.byte(at: index + 1) == 0x5C,
                              value.byte(at: index + 2) == 0x75,
                              let second = Self.hexValue(value, start: index + 3),
                              second >= 0xDC00, second <= 0xDFFF
                        else { throw .invalidValue }
                        try writeByte(0x5C); try writeByte(0x75)
                        for offset in 3...6 { try writeByte(value.byte(at: index + offset)!) }
                        index += 6
                    } else if first >= 0xDC00 && first <= 0xDFFF {
                        throw .invalidValue
                    }
                }
            case 0..<0x20:
                try writeBytes("\\u00")
                try writeByte(Self.hexChar(byte >> 4)); try writeByte(Self.hexChar(byte & 0xF))
            default: try writeByte(byte)
            }
            index += 1
        }
        try writeByte(0x22)
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

    /// Writes an integer JSON value.
    ///
    /// - Parameter value: The integer to encode.
    /// - Throws: ``WireEncodeError`` if the destination buffer is too small.
    public mutating func writeInt(_ value: Int) throws(WireEncodeError) {
        if value == 0 {
            try writeByte(0x30)
            return
        }
        var v = value
        if v < 0 {
            try writeByte(0x2D) // '-'
            // Handle Int.min: |Int.min| can't be represented as positive Int.
            // Use unsigned arithmetic to avoid the overflow.
            if v == Int.min {
                // Convert to the unsigned representation of the absolute value.
                // On 64-bit: UInt(bitPattern: Int.min) = 9223372036854775808
                // On 32-bit: UInt(bitPattern: Int.min) = 2147483648
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
        position += digitCount
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
        position += digitCount
    }

    /// Writes a UUID JSON string value.
    ///
    /// - Parameter value: The UUID to encode.
    /// - Throws: ``WireEncodeError`` if the destination buffer is too small.
    public mutating func writeUUID(_ value: UUID16) throws(WireEncodeError) {
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

    private static func isValidUTF8(_ value: ByteSlice) -> Bool {
        var index = 0
        while index < value.length {
            let lead = value.byte(at: index)!
            let count: Int
            switch lead { case 0..<0x80: count = 1; case 0xC2...0xDF: count = 2; case 0xE0...0xEF: count = 3; case 0xF0...0xF4: count = 4; default: return false }
            guard index + count <= value.length else { return false }
            for offset in 1..<count { guard let byte = value.byte(at: index + offset), byte >= 0x80 && byte <= 0xBF else { return false } }
            if count == 3 && ((lead == 0xE0 && value.byte(at: index + 1)! < 0xA0) || (lead == 0xED && value.byte(at: index + 1)! >= 0xA0)) { return false }
            if count == 4 && ((lead == 0xF0 && value.byte(at: index + 1)! < 0x90) || (lead == 0xF4 && value.byte(at: index + 1)! >= 0x90)) { return false }
            index += count
        }
        return true
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

/// Encode error for the wire writer.
public enum WireEncodeError: Error, Sendable {
    /// The encoded output would exceed the writer's ``WireWriter/capacity``.
    case bufferOverflow
    /// The value cannot be represented in the wire format.
    case invalidValue
}
