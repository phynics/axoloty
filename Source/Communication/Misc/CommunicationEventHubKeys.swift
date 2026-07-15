// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// A stable, namespaced key used to identify a stream in ``EventHub``.
///
/// Keys are grouped by a scope prefix and a unique name within that scope.
/// Using a dedicated ``Hashable`` struct instead of a raw string or
/// ``AnyHashable`` literal prevents accidental collisions with other EventHub
/// consumers that might choose the same textual identifier.
///
/// The canonical string form is `"<scope>/<name>"`, but equality and hashing
/// operate on the typed properties directly.
struct CommunicationEventHubKey: Hashable, Sendable {

    /// The scope prefix that groups related keys, e.g. `"communication"`.
    let scope: String

    /// The unique name of the stream within ``scope``.
    let name: String
}

/// Stable ``EventHub`` keys for communication-related streams.
///
/// These keys are used internally by ``MQTTNIOClient`` and exposed to callers
/// through the async observation API on ``CommunicationManager``.
enum CommunicationEventHubKeys {

    /// Key for the stream that replays the current ``CommunicationState``.
    static let communicationState = CommunicationEventHubKey(
        scope: "communication",
        name: "state"
    )

    /// Key for the stream of incoming raw MQTT transport messages.
    static let rawMQTTMessage = CommunicationEventHubKey(
        scope: "communication",
        name: "raw-mqtt-message"
    )

    /// Key for the stream of parsed MQTT messages that carry routing metadata.
    static let parsedMQTTMessage = CommunicationEventHubKey(
        scope: "communication",
        name: "parsed-mqtt-message"
    )

    /// Returns the key for the parsed Advertise event stream filtered by event
    /// type filter.
    ///
    /// This key is used by ``MQTTNIOClient`` to route parsed Advertise
    /// snapshots into the async event hub. It is not yet backed by a public
    /// manager-level lifecycle API, because ``CommunicationManager`` is not
    /// yet actor-safe and cannot safely drive MQTT subscription refcounting
    /// from the ``EventHub`` ``@Sendable`` first/last callbacks. A public
    /// async Advertise stream is blocked until that lifecycle can be provided
    /// without a production `@unchecked Sendable` bridge (see
    /// `docs/superpowers/plans/2026-07-15-T-027-advertise-async-lifecycle.md`).
    ///
    /// - Parameters:
    ///   - eventTypeFilter: the event type filter used for routing.
    ///   - objectTypeFilter: an optional concrete object type for further narrowing.
    /// - Returns: a stable ``CommunicationEventHubKey`` for the stream.
    static func advertise(
        eventTypeFilter: String,
        objectTypeFilter: String? = nil
    ) -> CommunicationEventHubKey {
        var name = "advertise/\(eventTypeFilter)"
        if let objectTypeFilter = objectTypeFilter {
            name += "/\(objectTypeFilter)"
        }
        return CommunicationEventHubKey(scope: "communication", name: name)
    }

    /// Key for the incoming Deadvertise event stream.
    static let deadvertise = CommunicationEventHubKey(
        scope: "communication",
        name: "deadvertise"
    )

    /// Key for the incoming Discover event stream.
    static let discover = CommunicationEventHubKey(
        scope: "communication",
        name: "discover"
    )

    /// Returns the key for an incoming Update event stream.
    static func update(eventTypeFilter: String) -> CommunicationEventHubKey {
        CommunicationEventHubKey(scope: "communication", name: "update/\(eventTypeFilter)")
    }

    /// Returns the key for an incoming Channel event stream.
    static func channel(channelId: String) -> CommunicationEventHubKey {
        CommunicationEventHubKey(scope: "communication", name: "channel/\(channelId)")
    }

    /// Returns the key for an IO point's state stream.
    static func ioState(ioPointId: String) -> CommunicationEventHubKey {
        CommunicationEventHubKey(scope: "communication", name: "io-state/\(ioPointId)")
    }

    /// Key for incoming raw IO value messages.
    static let ioValue = CommunicationEventHubKey(scope: "communication", name: "io-value")
}
