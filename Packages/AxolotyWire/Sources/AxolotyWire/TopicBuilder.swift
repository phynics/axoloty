// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

/// Zero-allocation topic string builder for constructing Coaty MQTT topics.
///
/// Writes topic bytes directly into a caller-provided fixed-size buffer,
/// mirroring the `WireWriter` pattern. The host-runtime (Foundation) builders
/// that allocate owned `String` topics live in an extension in the
/// Communication layer.
///
/// Topic format: `coaty/<version>/<namespace>/<eventType>[filter]/<sourceId>[/<correlationId>]`
public struct TopicBuilder {
    private let buffer: UnsafeMutablePointer<UInt8>
    /// The total capacity of the buffer in bytes.
    public let capacity: Int
    /// The current write offset into the buffer.
    public private(set) var position: Int

    /// Creates a topic builder that writes into the given buffer.
    ///
    /// - Parameters:
    ///   - buffer: A caller-owned byte buffer the builder writes into.
    ///   - capacity: The number of bytes available at `buffer`.
    public init(buffer: UnsafeMutablePointer<UInt8>, capacity: Int) {
        self.buffer = buffer
        self.capacity = capacity
        self.position = 0
    }

    // MARK: - Building blocks

    @inline(__always)
    private mutating func writeByte(_ byte: UInt8) throws(WireEncodeError) {
        guard position < capacity else { throw .bufferOverflow }
        buffer[position] = byte
        position += 1
    }

    @inline(__always)
    private mutating func writeBytes(_ s: StaticString) throws(WireEncodeError) {
        let len = s.utf8CodeUnitCount
        for i in 0..<len {
            try writeByte(s.utf8Start[i])
        }
    }

    @inline(__always)
    private mutating func writeSeparator() throws(WireEncodeError) {
        try writeByte(0x2F) // '/'
    }

    // MARK: - Topic construction

    /// Writes the protocol prefix: `coaty/3/`
    ///
    /// - Throws: ``WireEncodeError`` if the destination buffer is too small.
    public mutating func writePrefix() throws(WireEncodeError) {
        try writeBytes("coaty")
        try writeSeparator()
        try writeByte(0x33) // '3'
        try writeSeparator()
    }

    /// Writes the namespace level.
    ///
    /// - Parameter ns: The namespace as a `StaticString`.
    /// - Throws: ``WireEncodeError`` if the destination buffer is too small.
    public mutating func writeNamespace(_ ns: StaticString) throws(WireEncodeError) {
        try writeBytes(ns)
        try writeSeparator()
    }

    /// Writes the event type level, with optional filter suffix.
    /// Produces e.g. `ADV:sensors` or `DSC`.
    ///
    /// - Parameters:
    ///   - type: The Coaty event type to write.
    ///   - filter: An optional event-type filter suffix.
    /// - Throws: ``WireEncodeError`` if the destination buffer is too small.
    public mutating func writeEventType(
        _ type: WireEventType, filter: ByteSlice? = nil
    ) throws(WireEncodeError) {
        try writeBytes(type.wireCode)
        if let filter {
            try writeByte(0x3A) // ':'
            for i in 0..<filter.length {
                if let b = filter.byte(at: i) { try writeByte(b) }
            }
        }
        try writeSeparator()
    }

    /// Writes a UUID source ID.
    ///
    /// - Parameter uuid: The source identifier UUID.
    /// - Throws: ``WireEncodeError`` if the destination buffer is too small.
    public mutating func writeSourceId(_ uuid: UUID16) throws(WireEncodeError) {
        try writeUUID(uuid)
    }

    /// Writes a separator and correlation ID UUID.
    ///
    /// - Parameter uuid: The correlation identifier UUID.
    /// - Throws: ``WireEncodeError`` if the destination buffer is too small.
    public mutating func writeCorrelationId(_ uuid: UUID16) throws(WireEncodeError) {
        try writeSeparator()
        try writeUUID(uuid)
    }

    /// Returns the built topic as a ByteSlice borrowing from the buffer.
    public func build() -> ByteSlice {
        ByteSlice(pointer: UnsafeRawPointer(buffer), length: position)
    }

    // MARK: - Internal

    private mutating func writeUUID(_ uuid: UUID16) throws(WireEncodeError) {
        guard position + 36 <= capacity else { throw .bufferOverflow }
        let b = uuid.bytes
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
