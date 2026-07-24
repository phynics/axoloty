// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

/// Zero-allocation topic string builder for constructing Coaty MQTT topics.
///
/// Writes topic bytes directly into a caller-provided fixed-size buffer,
/// mirroring the `WireWriter` pattern. Replaces the 21
/// `CommunicationTopic.createTopicStringByLevels*` call sites that
/// allocate `String` objects via interpolation and `joined(separator:)`.
///
/// Topic format: `coaty/<version>/<namespace>/<eventType>[filter]/<sourceId>[/<correlationId>]`
public struct TopicBuilder {
    private let buffer: UnsafeMutablePointer<UInt8>
    public let capacity: Int
    public private(set) var position: Int

    public init(buffer: UnsafeMutablePointer<UInt8>, capacity: Int) {
        self.buffer = buffer
        self.capacity = capacity
        self.position = 0
    }

    // MARK: - Building blocks

    @inline(__always)
    private mutating func writeByte(_ byte: UInt8) {
        guard position < capacity else { return }
        buffer[position] = byte
        position += 1
    }

    @inline(__always)
    private mutating func writeBytes(_ s: StaticString) {
        let len = s.utf8CodeUnitCount
        for i in 0..<len {
            writeByte(s.utf8Start[i])
        }
    }

    @inline(__always)
    private mutating func writeSeparator() {
        writeByte(0x2F) // '/'
    }

    // MARK: - Topic construction

    /// Writes the protocol prefix: `coaty/3/`
    public mutating func writePrefix() {
        writeBytes("coaty")
        writeSeparator()
        writeByte(0x33) // '3'
        writeSeparator()
    }

    /// Writes the namespace level.
    public mutating func writeNamespace(_ ns: StaticString) {
        writeBytes(ns)
        writeSeparator()
    }

    /// Writes the event type level, with optional filter suffix.
    /// Produces e.g. `ADV-sensors` or `DSC`.
    public mutating func writeEventType(_ type: WireEventType, filter: ByteSlice? = nil) {
        let code: StaticString
        switch type {
        case .advertise: code = "ADV"
        case .deadvertise: code = "DAD"
        case .channel: code = "CHN"
        case .associate: code = "ASC"
        case .ioValue: code = "IOV"
        case .discover: code = "DSC"
        case .resolve: code = "RSV"
        case .query: code = "QRY"
        case .retrieve: code = "RTV"
        case .update: code = "UPD"
        case .complete: code = "CPL"
        case .call: code = "CLL"
        case .returnEvent: code = "RTN"
        }
        writeBytes(code)
        if let filter {
            writeByte(0x3A) // ':'
            for i in 0..<filter.length {
                if let b = filter.byte(at: i) { writeByte(b) }
            }
        }
        writeSeparator()
    }

    /// Writes a UUID source ID.
    public mutating func writeSourceId(_ uuid: UUID16) {
        writeUUID(uuid)
    }

    /// Writes a separator and correlation ID UUID.
    public mutating func writeCorrelationId(_ uuid: UUID16) {
        writeSeparator()
        writeUUID(uuid)
    }

    /// Returns the built topic as a ByteSlice borrowing from the buffer.
    public func build() -> ByteSlice {
        ByteSlice(pointer: UnsafeRawPointer(buffer), length: position)
    }

    // MARK: - Internal

    private mutating func writeUUID(_ uuid: UUID16) {
        let hexChars: [UInt8] = [
            0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37,
            0x38, 0x39, 0x61, 0x62, 0x63, 0x64, 0x65, 0x66
        ]
        let b = uuid.bytes
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
                writeByte(0x2D)
            } else {
                writeByte(hexChars[Int(nibbles[nibIdx])])
                nibIdx += 1
            }
        }
    }
}
