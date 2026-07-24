// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

/// A Foundation-free JSON writer that writes into a caller-provided buffer.
///
/// No String or Array is allocated — the caller provides a fixed-size byte
/// buffer and the writer encodes JSON directly into it. Designed for the
/// wire encode hot path.
public struct WireWriter {
    @usableFromInline let buffer: UnsafeMutablePointer<UInt8>
    public let capacity: Int
    public private(set) var position: Int

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
                try writeBytes("-9223372036854775808")
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
        // Format: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx (36 chars)
        guard position + 36 <= capacity else { throw .bufferOverflow }
        let hexChars: [UInt8] = [
            0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37,
            0x38, 0x39, 0x61, 0x62, 0x63, 0x64, 0x65, 0x66
        ]
        let b = value.bytes
        let nibbles: [UInt8] = [
            b.0 >> 4, b.0 & 0xF, b.1 >> 4, b.1 & 0xF,
            b.2 >> 4, b.2 & 0xF, b.3 >> 4, b.3 & 0xF,
            b.4 >> 4, b.4 & 0xF, b.5 >> 4, b.5 & 0xF,
            b.6 >> 4, b.6 & 0xF, b.7 >> 4, b.7 & 0xF,
            b.8 >> 4, b.8 & 0xF, b.9 >> 4, b.9 & 0xF,
            b.10 >> 4, b.10 & 0xF, b.11 >> 4, b.11 & 0xF,
            b.12 >> 4, b.12 & 0xF, b.13 >> 4, b.13 & 0xF,
            b.14 >> 4, b.14 & 0xF, b.15 >> 4, b.15 & 0xF,
        ]
        let dashes: Set<Int> = [8, 13, 18, 23]
        var nibIdx = 0
        for i in 0..<36 {
            if dashes.contains(i) {
                buffer[position + i] = 0x2D // '-'
            } else {
                buffer[position + i] = hexChars[Int(nibbles[nibIdx])]
                nibIdx += 1
            }
        }
        position += 36
    }
}

/// Encode error for the wire writer.
public enum WireEncodeError: Error, Sendable {
    case bufferOverflow
    case invalidValue
}
