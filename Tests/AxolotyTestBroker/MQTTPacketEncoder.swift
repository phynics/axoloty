// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import NIOCore

/// Encodes the server side of MQTT 3.1.1 (OASIS section 3).
enum MQTTPacketEncoder {
    static func connack(sessionPresent: Bool, returnCode: UInt8 = 0) -> ByteBuffer {
        var body = ByteBuffer()
        body.writeInteger(sessionPresent ? UInt8(1) : UInt8(0))
        body.writeInteger(returnCode)
        return frame(type: .connack, flags: 0, body: body)
    }

    static func suback(packetID: UInt16, returnCodes: [UInt8]) -> ByteBuffer {
        var body = ByteBuffer()
        body.writeInteger(packetID)
        body.writeBytes(returnCodes)
        return frame(type: .suback, flags: 0, body: body)
    }

    static func unsuback(packetID: UInt16) -> ByteBuffer {
        var body = ByteBuffer()
        body.writeInteger(packetID)
        return frame(type: .unsuback, flags: 0, body: body)
    }

    static func puback(packetID: UInt16) -> ByteBuffer {
        var body = ByteBuffer()
        body.writeInteger(packetID)
        return frame(type: .puback, flags: 0, body: body)
    }

    static func pingresp() -> ByteBuffer {
        frame(type: .pingresp, flags: 0, body: ByteBuffer())
    }

    static func publish(
        topic: String,
        payload: [UInt8],
        qos: UInt8,
        retain: Bool,
        duplicate: Bool,
        packetID: UInt16?
    ) -> ByteBuffer {
        var body = ByteBuffer()
        body.writeMQTTString(topic)
        if qos > 0, let packetID {
            body.writeInteger(packetID)
        }
        body.writeBytes(payload)
        var flags: UInt8 = 0
        if retain { flags |= 0x01 }
        flags |= (qos & 0x03) << 1
        if duplicate { flags |= 0x08 }
        return frame(type: .publish, flags: flags, body: body)
    }

    /// Wraps a body in the fixed header and the variable-length remaining length.
    static func frame(type: MQTTPacketType, flags: UInt8, body: ByteBuffer) -> ByteBuffer {
        var out = ByteBuffer()
        out.writeInteger((type.rawValue << 4) | (flags & 0x0F))
        out.writeRemainingLength(body.readableBytes)
        out.writeImmutableBuffer(body)
        return out
    }
}

extension ByteBuffer {
    /// Writes a two-byte length-prefixed UTF-8 string (OASIS section 1.5.3).
    mutating func writeMQTTString(_ string: String) {
        let bytes = Array(string.utf8)
        writeInteger(UInt16(bytes.count))
        writeBytes(bytes)
    }

    /// Writes an MQTT variable-byte integer (OASIS section 2.2.3).
    mutating func writeRemainingLength(_ value: Int) {
        var remaining = value
        repeat {
            var byte = UInt8(remaining % 128)
            remaining /= 128
            if remaining > 0 { byte |= 0x80 }
            writeInteger(byte)
        } while remaining > 0
    }
}
