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

    /// Returns the key for an async Advertise stream filtered by event type filter.
    ///
    /// When an object type maps to a core type, callers may pass the concrete
    /// `objectTypeFilter` to receive a stream that is narrowed to that object
    /// type while still subscribing on the core type topic.
    ///
    /// - Parameters:
    ///   - eventTypeFilter: the event type filter used for the MQTT subscription.
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
}
