// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// A value-typed, concurrency-safe representation of a parsed MQTT `PUBLISH`
/// that carries enough topic metadata for manager-level routing without passing
/// the reference-typed ``CommunicationTopic`` across isolation boundaries.
struct ParsedMQTTMessage: Sendable, Hashable {

    /// The Coaty event type carried on the topic's event level.
    let eventType: CommunicationEventType

    /// The optional event type filter parsed from the topic's event level.
    let eventTypeFilter: String?

    /// The namespace level of the incoming topic.
    let namespace: String

    /// The source identifier from the topic, as a string.
    let sourceId: String

    /// The correlation identifier for two-way events, if present.
    let correlationId: String?

    /// The UTF-8 payload of the incoming message.
    let payload: String

    /// Creates a parsed message from a validated Coaty topic and its UTF-8 payload.
    ///
    /// - Parameters:
    ///   - topic: the validated ``CommunicationTopic``.
    ///   - payload: the UTF-8 payload string.
    init(topic: CommunicationTopic, payload: String) {
        self.eventType = topic.eventType
        self.eventTypeFilter = topic.eventTypeFilter
        self.namespace = topic.namespace
        self.sourceId = topic.sourceId.string
        self.correlationId = topic.correlationId
        self.payload = payload
    }
}
