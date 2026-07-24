// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// A value-typed snapshot of an `AdvertiseEvent` suitable for concurrent event streams.
public struct AdvertiseEventSnapshot: Codable, Equatable, Sendable {

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

    /// Application-specific private data associated with the advertisement, as
    /// raw JSON text, if any.
    public let privateData: String?

    /// Creates a snapshot of an Advertise event.
    ///
    /// - Parameters:
    ///   - sourceId: The identifier of the event source.
    ///   - eventTypeFilter: The optional event type filter used for routing.
    ///   - object: The object being advertised.
    ///   - privateData: Optional application-specific private data as raw JSON text.
    public init(
        sourceId: String? = nil,
        eventTypeFilter: String? = nil,
        object: CoatyObjectSnapshot,
        privateData: String? = nil
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

        let objectPayload = WirePayloadExtractor.nestedObjectPayload(from: parsedMQTTMessage.payload, key: "object")
        let privateData = WirePayloadExtractor.nestedPayload(from: parsedMQTTMessage.payload, key: "privateData")

        self.init(
            sourceId: parsedMQTTMessage.sourceId,
            eventTypeFilter: parsedMQTTMessage.eventTypeFilter,
            object: wire.object.withPayload(objectPayload),
            privateData: privateData
        )
    }
}
