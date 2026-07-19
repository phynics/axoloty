// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// Stable ``EventHub`` keys for communication-related streams.
///
/// Each constant carries its element type as a phantom parameter so that a
/// wrong-typed ``EventHub/yield(value:to:)`` is a compile error rather than
/// a silent runtime drop. These keys are used internally by
/// ``MQTTNIOClient`` and exposed to callers through the async observation
/// API on ``CommunicationManager``.
enum CommunicationEventHubKeys {

    /// Key for the stream that replays the current ``CommunicationState``.
    static let communicationState = EventKey<CommunicationState>(
        scope: "communication",
        name: "state"
    )

    /// Key for the container operating lifecycle state.
    static let operatingState = EventKey<OperatingState>(
        scope: "communication",
        name: "operating-state"
    )

    /// Key for the stream of incoming raw MQTT transport messages.
    static let rawMQTTMessage = EventKey<RawMQTTMessage>(
        scope: "communication",
        name: "raw-mqtt-message"
    )

    /// Key for the stream of parsed MQTT messages that carry routing metadata.
    static let parsedMQTTMessage = EventKey<ParsedMQTTMessage>(
        scope: "communication",
        name: "parsed-mqtt-message"
    )

    /// Returns the key for the parsed Advertise event stream filtered by event
    /// type filter.
    ///
    /// - Parameters:
    ///   - eventTypeFilter: the event type filter used for routing.
    ///   - objectTypeFilter: an optional concrete object type for further narrowing.
    /// - Returns: a stable ``EventKey`` for the stream.
    static func advertise(
        eventTypeFilter: String,
        objectTypeFilter: String? = nil
    ) -> EventKey<AdvertiseEventSnapshot> {
        var name = "advertise/\(eventTypeFilter)"
        if let objectTypeFilter = objectTypeFilter {
            name += "/\(objectTypeFilter)"
        }
        return EventKey<AdvertiseEventSnapshot>(scope: "communication", name: name)
    }

    /// Key for the incoming Deadvertise event stream.
    static let deadvertise = EventKey<DeadvertiseEventSnapshot>(
        scope: "communication",
        name: "deadvertise"
    )

    /// Key for the incoming Discover event stream.
    static let discover = EventKey<DiscoverEventSnapshot>(
        scope: "communication",
        name: "discover"
    )

    /// Key for the incoming Query event stream.
    static let query = EventKey<QueryEventSnapshot>(
        scope: "communication",
        name: "query"
    )

    /// Returns the key for an incoming Call event stream filtered by operation.
    static func call(operation: String) -> EventKey<CallEventSnapshot> {
        EventKey<CallEventSnapshot>(scope: "communication", name: "call/\(operation)")
    }

    /// Returns the key for an incoming Update event stream.
    static func update(eventTypeFilter: String) -> EventKey<UpdateEventSnapshot> {
        EventKey<UpdateEventSnapshot>(scope: "communication", name: "update/\(eventTypeFilter)")
    }

    /// Returns the key for an incoming Channel event stream.
    static func channel(channelId: String) -> EventKey<ChannelEventSnapshot> {
        EventKey<ChannelEventSnapshot>(scope: "communication", name: "channel/\(channelId)")
    }

    /// Returns the key for an IO point's state stream.
    static func ioState(ioPointId: String) -> EventKey<IoStateEventSnapshot> {
        EventKey<IoStateEventSnapshot>(scope: "communication", name: "io-state/\(ioPointId)")
    }

    /// Key for incoming raw IO value messages.
    static let ioValue = EventKey<IoValueEventSnapshot>(
        scope: "communication",
        name: "io-value"
    )

    /// Returns the key for a correlated response stream.
    static func response(
        eventType: CommunicationEventType,
        correlationId: String
    ) -> EventKey<ResponseEventSnapshot> {
        EventKey<ResponseEventSnapshot>(
            scope: "communication",
            name: "response/\(eventType.rawValue)/\(correlationId)"
        )
    }
}
