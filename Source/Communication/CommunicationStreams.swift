// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// Key for a parameterized Advertise event stream, identifying a
/// specific event-type filter and optional object-type filter.
///
/// Equality and hashing use both fields, so
/// `advertise(eventTypeFilter: "sensors")` and
/// `advertise(eventTypeFilter: "sensors", objectTypeFilter: "sensors:temp")`
/// are distinct streams that share the same MQTT topic (the topic is
/// derived from `eventTypeFilter` only).
internal struct AdvertiseKey: Hashable, Sendable {
    let eventTypeFilter: String
    let objectTypeFilter: String?

    init(eventTypeFilter: String, objectTypeFilter: String? = nil) {
        self.eventTypeFilter = eventTypeFilter
        self.objectTypeFilter = objectTypeFilter
    }
}

/// Key for a correlated response stream, identifying a specific
/// response event type and correlation ID.
internal struct ResponseKey: Hashable, Sendable {
    let eventType: CommunicationEventType
    let correlationId: String

    init(eventType: CommunicationEventType, correlationId: String) {
        self.eventType = eventType
        self.correlationId = correlationId
    }
}

/// Holds all `Broadcast` and `BroadcastFamily` instances used by the
/// communication layer.
///
/// Created by ``CommunicationManager`` (which owns the
/// ``CommunicationSubscriptionCoordinator`` needed for `onFirst`/
/// `onLast` hooks) and passed to ``MQTTNIOClient`` at initialization.
/// The client calls `send`/`sendState` to produce values; the manager
/// calls `subscribe` to create consumer streams.
///
/// This struct replaces the former `EventHub` — a single actor with
/// `AnyHashable`-keyed routing. Each stream is now a typed property,
/// and the string-based `CommunicationEventHubKeys` vocabulary is
/// deleted.
internal struct CommunicationStreams: Sendable {
    let communicationState: Broadcast<CommunicationState>
    let operatingState: Broadcast<OperatingState>
    let rawMQTTMessages: Broadcast<RawMQTTMessage>
    let parsedMQTTMessages: Broadcast<ParsedMQTTMessage>
    let ioValues: Broadcast<IoValueEventSnapshot>

    let ioStateFamily: BroadcastFamily<String, IoStateEventSnapshot>
    let advertiseFamily: BroadcastFamily<AdvertiseKey, AdvertiseEventSnapshot>
    let deadvertise: Broadcast<DeadvertiseEventSnapshot>
    let discover: Broadcast<DiscoverEventSnapshot>
    let query: Broadcast<QueryEventSnapshot>
    let callFamily: BroadcastFamily<String, CallEventSnapshot>
    let updateFamily: BroadcastFamily<String, UpdateEventSnapshot>
    let channelFamily: BroadcastFamily<String, ChannelEventSnapshot>
    let responseFamily: BroadcastFamily<ResponseKey, ResponseEventSnapshot>
}
