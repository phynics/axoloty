// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import AxolotyWire

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

extension AdvertiseEventSnapshot {

    /// Decodes an Advertise snapshot from a parsed MQTT message via a single
    /// ``WireReader`` pass, preserving source and filter metadata from the
    /// topic and decoding the object's ``CoatyObjectSnapshot`` from the
    /// borrowed `object` bytes.
    ///
    /// Malformed payloads are surfaced as `nil` so callers can drop them.
    ///
    /// - Parameter parsedMQTTMessage: the parsed transport message.
    init?(parsedMQTTMessage: ParsedMQTTMessage) {
        guard case .advertise(let wire) = parsedMQTTMessage.event,
              let object = try? HostWireAdapter.snapshot(from: wire.object) else { return nil }
        self.init(
            sourceId: parsedMQTTMessage.sourceId,
            eventTypeFilter: parsedMQTTMessage.eventTypeFilter,
            object: object,
            privateData: wire.privateData.flatMap { String(bytes: $0, encoding: .utf8) }
        )
    }
}
