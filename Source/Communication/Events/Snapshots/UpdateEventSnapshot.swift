// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// A value-typed snapshot of an `UpdateEvent` suitable for concurrent event streams.
public struct UpdateEventSnapshot: EventSnapshot, Codable, Equatable, Sendable {

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

private struct UpdateEventWirePayload: Codable {
    let object: CoatyObjectSnapshot
}

extension UpdateEventSnapshot {

    /// Decodes an Update snapshot from a parsed MQTT message.
    init?(parsedMQTTMessage: ParsedMQTTMessage) {
        guard let wire: UpdateEventWirePayload = PayloadCoder.decode(parsedMQTTMessage.payload) else {
            return nil
        }
        self.init(
            sourceId: parsedMQTTMessage.sourceId,
            eventTypeFilter: parsedMQTTMessage.eventTypeFilter,
            object: wire.object.withPayload(SnapshotWirePayload.objectPayload(from: parsedMQTTMessage.payload))
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
