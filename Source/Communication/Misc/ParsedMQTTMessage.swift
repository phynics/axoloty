// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import AxolotyWire

/// A value-typed, concurrency-safe representation of a parsed MQTT `PUBLISH`
/// that carries enough topic metadata for manager-level routing, parsed from
/// the incoming topic bytes by ``TopicView``.
struct ParsedMQTTMessage: Sendable, Equatable {

    /// The Coaty event type carried on the topic's event level.
    let eventType: WireEventType

    /// The optional event type filter parsed from the topic's event level.
    let eventTypeFilter: String?

    /// The namespace level of the incoming topic.
    let namespace: String

    /// The source identifier from the topic, as a string.
    let sourceId: String

    /// The correlation identifier for two-way events, if present.
    let correlationId: String?

    /// The decoded event with all borrowed wire fields copied for async use.
    let event: OwnedWireEvent

    /// The original owned payload bytes, retained for correlated response APIs.
    let payload: [UInt8]

    /// Creates a parsed message from a ``TopicView`` (zero-allocation topic
    /// parse) and its UTF-8 payload string.
    ///
    /// - Parameters:
    ///   - topicView: the parsed topic view.
    ///   - event: the synchronously decoded, owned wire event.
    ///   - payload: the original owned payload bytes.
    init(topicView: TopicView, event: OwnedWireEvent, payload: [UInt8]) {
        self.eventType = topicView.eventType ?? .advertise
        self.eventTypeFilter = topicView.eventTypeFilter?.asString()
        self.namespace = topicView.namespaceLevel?.asString() ?? ""
        self.sourceId = topicView.sourceIdLevel?.asString() ?? ""
        self.correlationId = topicView.correlationIdLevel?.asString()
        self.event = event
        self.payload = payload
    }

    /// The original payload as UTF-8 text, when valid.
    var payloadString: String? {
        String(bytes: payload, encoding: .utf8)
    }
}
