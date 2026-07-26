// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

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
        var payload = parsedMQTTMessage.payload
        guard let decoded = payload.withUTF8({ buffer -> (String, String, String?, Bool?, Int?)? in
            guard let base = buffer.baseAddress,
                  let wire = try? AssociateWireData(from: WireReader(bytes: base, length: buffer.count)) else {
                return nil
            }
            return (
                Self.uuidString(wire.ioSourceId),
                Self.uuidString(wire.ioActorId),
                wire.associatingRoute?.asString(),
                wire.isExternalRoute,
                wire.updateRate
            )
        }) else { return nil }
        self.init(
            sourceId: parsedMQTTMessage.sourceId,
            ioContextName: parsedMQTTMessage.eventTypeFilter,
            ioSourceId: decoded.0,
            ioActorId: decoded.1,
            associatingRoute: decoded.2,
            isExternalRoute: decoded.3,
            updateRate: decoded.4
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
}
