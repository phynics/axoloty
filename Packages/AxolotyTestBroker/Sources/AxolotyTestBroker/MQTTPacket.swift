// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import NIOCore

/// MQTT 3.1.1 control packet types (OASIS section 2.2.1).
enum MQTTPacketType: UInt8 {
    case connect = 1
    case connack = 2
    case publish = 3
    case puback = 4
    case subscribe = 8
    case suback = 9
    case unsubscribe = 10
    case unsuback = 11
    case pingreq = 12
    case pingresp = 13
    case disconnect = 14
}

/// A decoded `CONNECT` packet.
struct MQTTConnectPacket: Sendable, Equatable {
    var clientID: String
    var cleanSession: Bool
    var keepAlive: UInt16
    var will: MQTTWill?
    var username: String?
    var password: [UInt8]?
}

/// The last will and testament carried by a `CONNECT` packet.
struct MQTTWill: Sendable, Equatable {
    var topic: String
    var message: [UInt8]
    var qos: UInt8
    var retain: Bool
}

/// A decoded `PUBLISH` packet.
struct MQTTPublishPacket: Sendable, Equatable {
    var topic: String
    var payload: [UInt8]
    var qos: UInt8
    var retain: Bool
    var duplicate: Bool
    /// Present only when `qos > 0`.
    var packetID: UInt16?
}

/// One topic-filter request inside a `SUBSCRIBE` packet.
struct MQTTSubscriptionRequest: Sendable, Equatable {
    var filter: String
    var qos: UInt8
}

/// A decoded `SUBSCRIBE` packet.
struct MQTTSubscribePacket: Sendable, Equatable {
    var packetID: UInt16
    var requests: [MQTTSubscriptionRequest]
}

/// A decoded `UNSUBSCRIBE` packet.
struct MQTTUnsubscribePacket: Sendable, Equatable {
    var packetID: UInt16
    var filters: [String]
}

/// A decoded inbound packet.
enum MQTTDecodedPacket: Sendable, Equatable {
    case connect(MQTTConnectPacket)
    case publish(MQTTPublishPacket)
    case puback(packetID: UInt16)
    case subscribe(MQTTSubscribePacket)
    case unsubscribe(MQTTUnsubscribePacket)
    case pingreq
    case disconnect
}

/// Raised when a byte stream is not a legal MQTT 3.1.1 packet.
struct MQTTProtocolError: Error, Sendable, Equatable {
    var reason: String
}

/// Decodes MQTT 3.1.1 packets from a `ByteBuffer`.
///
/// `decodeFrame(from:)` returns `nil` when the buffer holds only part of a
/// frame, so the caller can wait for more bytes without losing position. It
/// returns the decoded packet and the number of bytes the frame occupies.
enum MQTTPacketDecoder {
    static func decodeFrame(from buffer: ByteBuffer) -> (packet: MQTTDecodedPacket, consumed: Int)? {
        guard let first = buffer.getInteger(at: buffer.readerIndex, as: UInt8.self) else { return nil }
        guard let type = MQTTPacketType(rawValue: first >> 4) else {
            return nil
        }
        let flags = first & 0x0F
        guard let length = remainingLength(in: buffer, from: buffer.readerIndex + 1) else { return nil }
        let headerSize = 1 + length.byteCount
        let total = headerSize + length.value
        guard buffer.readableBytes >= total else { return nil }
        var slice = buffer.getSlice(at: buffer.readerIndex + headerSize, length: length.value) ?? ByteBuffer()
        let packet = try? decodeBody(type: type, flags: flags, body: &slice)
        guard let packet else { return nil }
        return (packet, total)
    }

    /// Reads the variable-length remaining length starting at `start`.
    ///
    /// Returns `nil` before all continuation bytes of an incomplete integer are
    /// present, and throws-as-`nil` for an over-long or truncated encoding.
    private static func remainingLength(
        in buffer: ByteBuffer,
        from start: Int
    ) -> (value: Int, byteCount: Int)? {
        var multiplier = 1
        var value = 0
        var index = start
        for _ in 0..<4 {
            guard let byte = buffer.getInteger(at: index, as: UInt8.self) else { return nil }
            value += Int(byte & 0x7F) * multiplier
            index += 1
            if byte & 0x80 == 0 {
                return (value, index - start)
            }
            multiplier *= 128
        }
        return nil
    }

    private static func decodeBody(
        type: MQTTPacketType,
        flags: UInt8,
        body: inout ByteBuffer
    ) throws -> MQTTDecodedPacket {
        switch type {
        case .connect:
            return .connect(try decodeConnect(&body))
        case .publish:
            return .publish(try decodePublish(flags: flags, body: &body))
        case .puback:
            return .puback(packetID: try decodePacketID(&body))
        case .subscribe:
            return .subscribe(try decodeSubscribe(&body))
        case .unsubscribe:
            return .unsubscribe(try decodeUnsubscribe(&body))
        case .pingreq:
            return .pingreq
        case .disconnect:
            return .disconnect
        default:
            throw MQTTProtocolError(reason: "unsupported packet type \(type.rawValue)")
        }
    }

    private static func decodeConnect(_ body: inout ByteBuffer) throws -> MQTTConnectPacket {
        let protocolName = try readString(&body)
        guard protocolName == "MQTT" else {
            throw MQTTProtocolError(reason: "unsupported protocol name \(protocolName)")
        }
        guard let level = body.readInteger(as: UInt8.self), level == 4 else {
            throw MQTTProtocolError(reason: "unsupported protocol level")
        }
        guard let connectFlags = body.readInteger(as: UInt8.self) else {
            throw MQTTProtocolError(reason: "missing connect flags")
        }
        guard let keepAlive = body.readInteger(as: UInt16.self) else {
            throw MQTTProtocolError(reason: "missing keep alive")
        }
        let clientID = try readString(&body)
        var will: MQTTWill?
        if connectFlags & 0x04 != 0 {
            let topic = try readString(&body)
            let message = try readBytes(&body)
            will = MQTTWill(
                topic: topic,
                message: message,
                qos: (connectFlags >> 3) & 0x03,
                retain: connectFlags & 0x20 != 0
            )
        }
        var username: String?
        if connectFlags & 0x80 != 0 {
            username = try readString(&body)
        }
        var password: [UInt8]?
        if connectFlags & 0x40 != 0 {
            password = try readBytes(&body)
        }
        return MQTTConnectPacket(
            clientID: clientID,
            cleanSession: connectFlags & 0x02 != 0,
            keepAlive: keepAlive,
            will: will,
            username: username,
            password: password
        )
    }

    private static func decodePublish(flags: UInt8, body: inout ByteBuffer) throws -> MQTTPublishPacket {
        let topic = try readString(&body)
        let qos = (flags >> 1) & 0x03
        var packetID: UInt16?
        if qos > 0 {
            guard let id = body.readInteger(as: UInt16.self) else {
                throw MQTTProtocolError(reason: "missing publish packet identifier")
            }
            packetID = id
        }
        let payload = body.readBytes(length: body.readableBytes) ?? []
        return MQTTPublishPacket(
            topic: topic,
            payload: payload,
            qos: qos,
            retain: flags & 0x01 != 0,
            duplicate: flags & 0x08 != 0,
            packetID: packetID
        )
    }

    private static func decodePacketID(_ body: inout ByteBuffer) throws -> UInt16 {
        guard let id = body.readInteger(as: UInt16.self) else {
            throw MQTTProtocolError(reason: "missing packet identifier")
        }
        return id
    }

    private static func decodeSubscribe(_ body: inout ByteBuffer) throws -> MQTTSubscribePacket {
        let packetID = try decodePacketID(&body)
        var requests: [MQTTSubscriptionRequest] = []
        while body.readableBytes > 0 {
            let filter = try readString(&body)
            guard let qos = body.readInteger(as: UInt8.self) else {
                throw MQTTProtocolError(reason: "subscription is missing its QoS")
            }
            requests.append(MQTTSubscriptionRequest(filter: filter, qos: qos & 0x03))
        }
        guard !requests.isEmpty else {
            throw MQTTProtocolError(reason: "subscription has no topic filters")
        }
        return MQTTSubscribePacket(packetID: packetID, requests: requests)
    }

    private static func decodeUnsubscribe(_ body: inout ByteBuffer) throws -> MQTTUnsubscribePacket {
        let packetID = try decodePacketID(&body)
        var filters: [String] = []
        while body.readableBytes > 0 {
            filters.append(try readString(&body))
        }
        guard !filters.isEmpty else {
            throw MQTTProtocolError(reason: "unsubscribe has no topic filters")
        }
        return MQTTUnsubscribePacket(packetID: packetID, filters: filters)
    }

    /// Reads a two-byte length-prefixed UTF-8 string (OASIS section 1.5.3).
    static func readString(_ body: inout ByteBuffer) throws -> String {
        guard let length = body.readInteger(as: UInt16.self) else {
            throw MQTTProtocolError(reason: "missing string length")
        }
        guard let bytes = body.readBytes(length: Int(length)) else {
            throw MQTTProtocolError(reason: "truncated string")
        }
        guard let string = String(validating: bytes, as: UTF8.self) else {
            throw MQTTProtocolError(reason: "string is not valid UTF-8")
        }
        return string
    }

    private static func readBytes(_ body: inout ByteBuffer) throws -> [UInt8] {
        guard let length = body.readInteger(as: UInt16.self) else {
            throw MQTTProtocolError(reason: "missing binary length")
        }
        guard let bytes = body.readBytes(length: Int(length)) else {
            throw MQTTProtocolError(reason: "truncated binary field")
        }
        return bytes
    }
}
