// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// A value-typed snapshot of an `AdvertiseEvent` suitable for concurrent event streams.
public struct AdvertiseEventSnapshot: EventSnapshot, Codable, Equatable, Sendable {

    /// The identifier of the event source, as derived from the incoming topic.
    public let sourceId: String?

    /// The event type filter used to route the advertisement, if any.
    ///
    /// This corresponds to the `typeFilter` set on a legacy `AdvertiseEvent`
    /// and is either a core type name or an object type prefixed with the
    /// event type filter separator.
    public let eventTypeFilter: String?

    /// The object being advertised.
    public let object: CoatyObjectSnapshot

    /// Application-specific private data associated with the advertisement, if any.
    public let privateData: Data?

    /// Creates a snapshot of an Advertise event.
    ///
    /// - Parameters:
    ///   - sourceId: The identifier of the event source.
    ///   - eventTypeFilter: The optional event type filter used for routing.
    ///   - object: The object being advertised.
    ///   - privateData: Optional application-specific private data.
    public init(
        sourceId: String? = nil,
        eventTypeFilter: String? = nil,
        object: CoatyObjectSnapshot,
        privateData: Data? = nil
    ) {
        self.sourceId = sourceId
        self.eventTypeFilter = eventTypeFilter
        self.object = object
        self.privateData = privateData
    }
}

// MARK: - Wire decoding

private struct AdvertiseEventWirePayload: Codable {
    let object: CoatyObjectSnapshot
    let privateData: AnyCodable?
}

extension AdvertiseEventSnapshot {

    /// Decodes an Advertise snapshot from a parsed MQTT message, preserving
    /// source and filter metadata from the topic.
    ///
    /// Malformed payloads are surfaced as `nil` so callers can drop them.
    ///
    /// - Parameter parsedMQTTMessage: the parsed transport message.
    init?(parsedMQTTMessage: ParsedMQTTMessage) {
        guard let wire: AdvertiseEventWirePayload = try? PayloadCoder.decode(parsedMQTTMessage.payload) else {
            return nil
        }

        let privateData: Data? = wire.privateData.flatMap { value in
            try? JSONEncoder().encode(value)
        }
        let objectPayload = SnapshotWirePayload.objectPayload(from: parsedMQTTMessage.payload)

        self.init(
            sourceId: parsedMQTTMessage.sourceId,
            eventTypeFilter: parsedMQTTMessage.eventTypeFilter,
            object: wire.object.withPayload(objectPayload),
            privateData: privateData
        )
    }
}

private enum SnapshotWirePayload {
    static func objectPayload(from payload: String) -> Data? {
        guard let data = payload.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let object = root["object"],
              JSONSerialization.isValidJSONObject(object) else {
            return nil
        }
        return try? JSONSerialization.data(withJSONObject: object)
    }
}
