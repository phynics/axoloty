// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import AxolotyWire

/// A value-typed snapshot of an `UpdateEvent` suitable for concurrent event streams.
public struct UpdateEventSnapshot: Codable, Equatable, Sendable {

    /// The identifier of the event source, as derived from the incoming topic.
    public let sourceId: String?

    /// The event type filter used to route the update, if any.
    ///
    /// This corresponds to the `typeFilter` set on a legacy `UpdateEvent`
    /// and is either a core type name or an object type prefixed with the
    /// event type filter separator.
    public let eventTypeFilter: String?

    /// The object whose properties are to be updated.
    public let object: CoatyObjectSnapshot

    /// Creates a snapshot of an Update event.
    ///
    /// - Parameters:
    ///   - sourceId: The identifier of the event source.
    ///   - eventTypeFilter: The optional event type filter used for routing.
    ///   - object: The object with properties to be updated.
    public init(
        sourceId: String? = nil,
        eventTypeFilter: String? = nil,
        object: CoatyObjectSnapshot
    ) {
        self.sourceId = sourceId
        self.eventTypeFilter = eventTypeFilter
        self.object = object
    }
}

extension UpdateEventSnapshot {

    /// Decodes an Update snapshot from a parsed MQTT message via a single
    /// ``WireReader`` pass, decoding the object's ``CoatyObjectSnapshot``
    /// from the borrowed `object` bytes.
    init?(parsedMQTTMessage: ParsedMQTTMessage) {
        guard case .update(let wire) = parsedMQTTMessage.event,
              let object = try? HostWireAdapter.snapshot(from: wire.object) else { return nil }
        self.init(
            sourceId: parsedMQTTMessage.sourceId,
            eventTypeFilter: parsedMQTTMessage.eventTypeFilter,
            object: object
        )
    }
}
