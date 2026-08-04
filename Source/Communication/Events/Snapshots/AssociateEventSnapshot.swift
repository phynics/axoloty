// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyWire

/// A value-typed snapshot of an Associate event suitable for concurrent event streams.
public struct AssociateEventSnapshot: Codable, Equatable, Sendable {
    /// The identifier of the event source, as derived from the incoming topic.
    public let sourceId: String?
    /// The IO context name from the Associate topic filter.
    public let ioContextName: String?
    /// The IO source identifier being associated or disassociated.
    public let ioSourceId: String
    /// The IO actor identifier being associated or disassociated.
    public let ioActorId: String
    /// The route used for association, or nil for disassociation.
    public let associatingRoute: String?
    /// Whether the associating route is external.
    public let isExternalRoute: Bool?
    /// The recommended IO source publish rate in milliseconds.
    public let updateRate: Int?

    /// Creates an Associate event snapshot.
    public init(
        sourceId: String? = nil,
        ioContextName: String? = nil,
        ioSourceId: String,
        ioActorId: String,
        associatingRoute: String? = nil,
        isExternalRoute: Bool? = nil,
        updateRate: Int? = nil
    ) {
        self.sourceId = sourceId
        self.ioContextName = ioContextName
        self.ioSourceId = ioSourceId
        self.ioActorId = ioActorId
        self.associatingRoute = associatingRoute
        self.isExternalRoute = isExternalRoute
        self.updateRate = updateRate
    }
}

extension AssociateEventSnapshot {
    /// Decodes an Associate snapshot from a parsed MQTT message via a single
    /// ``WireReader`` pass.
    init?(parsedMQTTMessage: ParsedMQTTMessage) {
        guard case .associate(let wire) = parsedMQTTMessage.event else { return nil }
        self.init(
            sourceId: parsedMQTTMessage.sourceId,
            ioContextName: parsedMQTTMessage.eventTypeFilter,
            ioSourceId: Self.uuidString(wire.ioSourceId),
            ioActorId: Self.uuidString(wire.ioActorId),
            associatingRoute: wire.associatingRoute.map { Self.decodeJSONString($0) },
            isExternalRoute: wire.isExternalRoute,
            updateRate: wire.updateRate
        )
    }

    private static func uuidString(_ uuid: UUID16) -> String {
        let bytes = [
            uuid.bytes.0, uuid.bytes.1, uuid.bytes.2, uuid.bytes.3,
            uuid.bytes.4, uuid.bytes.5, uuid.bytes.6, uuid.bytes.7,
            uuid.bytes.8, uuid.bytes.9, uuid.bytes.10, uuid.bytes.11,
            uuid.bytes.12, uuid.bytes.13, uuid.bytes.14, uuid.bytes.15
        ]
        let hex = Array("0123456789abcdef".utf8)
        var result = [UInt8]()
        result.reserveCapacity(36)
        for (index, byte) in bytes.enumerated() {
            if index == 4 || index == 6 || index == 8 || index == 10 { result.append(0x2D) }
            result.append(hex[Int(byte >> 4)])
            result.append(hex[Int(byte & 0x0F)])
        }
        return String(decoding: result, as: UTF8.self)
    }

    /// Decodes the JSON escapes relevant to an associating route.
    private static func decodeJSONString(_ bytes: [UInt8]) -> String {
        let input = bytes
        var output = [UInt8]()
        output.reserveCapacity(input.count)
        var index = 0

        while index < input.count {
            guard input[index] == 0x5C, index + 1 < input.count else {
                output.append(input[index])
                index += 1
                continue
            }

            if let byte = unescapedByte(for: input[index + 1]) {
                output.append(byte)
            } else {
                output.append(input[index])
                output.append(input[index + 1])
            }
            index += 2
        }

        return String(bytes: output, encoding: .utf8) ?? ""
    }

    private static func unescapedByte(for escaped: UInt8) -> UInt8? {
        switch escaped {
        case 0x22: return 0x22
        case 0x5C: return 0x5C
        case 0x2F: return 0x2F
        case 0x62: return 0x08
        case 0x66: return 0x0C
        case 0x6E: return 0x0A
        case 0x72: return 0x0D
        case 0x74: return 0x09
        default: return nil
        }
    }
}
