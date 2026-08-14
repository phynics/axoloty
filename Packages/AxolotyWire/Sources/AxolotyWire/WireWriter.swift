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

    @inline(__always)
    mutating func advancePosition(by count: Int) {
        precondition(count >= 0 && count <= capacity - position)
        position += count
    }

}

/// Encode error for the wire writer.
public enum WireEncodeError: Error, Sendable {
    /// The encoded output would exceed the writer's ``WireWriter/capacity``.
    case bufferOverflow
    /// The value cannot be represented in the wire format.
    case invalidValue
}
