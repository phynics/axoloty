// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import AxolotyWire

/// Bundles the levels that travel together through every publication
/// topic-string call site — `namespace`, `eventType`, `eventTypeFilter`,
/// and `correlationId` — so the data clump identified in #66 is named
/// rather than positional. `sourceId` is intentionally NOT part of this
/// struct: it is required for publication (passed alongside the struct to
/// ``TopicBuilder.publishTopic(components:sourceId:)``) and absent for
/// subscription (``TopicBuilder.subscribeTopic`` wildcards it), so carrying
/// it here would lose the compile-time distinction between the two
/// directions.
struct TopicStringComponents {
    let namespace: String
    let eventType: WireEventType
    let eventTypeFilter: String?
    let correlationId: String?

    init(
        namespace: String,
        eventType: WireEventType,
        eventTypeFilter: String? = nil,
        correlationId: String? = nil
    ) {
        self.namespace = namespace
        self.eventType = eventType
        self.eventTypeFilter = eventTypeFilter
        self.correlationId = correlationId
    }
}

/// Host-runtime topic builders, validators, and MQTT filter matching for
/// ``TopicBuilder``.
///
/// ``TopicBuilder`` itself (in the WireCodec layer) is a Foundation-free,
/// zero-allocation builder that writes into a caller-provided buffer and
/// returns a ``ByteSlice`` — suited to the embedded receive path. The
/// members in this extension serve the host (Foundation) runtime, where
/// topics are owned ``String`` values passed to the MQTT client, and
/// ``CoatyUUID`` source identifiers. They replace the builder, validation,
/// and matching logic that previously lived on the now-removed
/// `CommunicationTopic` class.
extension TopicBuilder {

    // MARK: - Publication topics

    /// Builds a Coaty publication topic string from bundled components and
    /// the required publication `sourceId`.
    ///
    /// - Parameters:
    ///   - components: The namespace, event type, optional filter, and
    ///     optional correlation id bundled as ``TopicStringComponents``.
    ///   - sourceId: The UUID of the originator of this event.
    /// - Returns: A topic string suitable for publishing.
    static func publishTopic(
        components: TopicStringComponents,
        sourceId: CoatyUUID
    ) -> String {
        publishTopic(
            namespace: components.namespace,
            sourceId: sourceId,
            eventType: components.eventType,
            eventTypeFilter: components.eventTypeFilter,
            correlationId: components.correlationId
        )
    }

    /// Builds a Coaty publication topic string.
    ///
    /// The topic shape is
    /// `coaty/3/<namespace>/<eventType>[:<filter>]/<sourceId>[/<correlationId>]`,
    /// with the correlation-id level present only for two-way event types.
    ///
    /// - Parameters:
    ///   - namespace: The messaging namespace.
    ///   - sourceId: The UUID of the originator of this event.
    ///   - eventType: The Coaty event type.
    ///   - eventTypeFilter: An optional event-type filter.
    ///   - correlationId: The correlation id for two-way events; ignored for
    ///     one-way event types.
    /// - Returns: A topic string suitable for publishing.
    static func publishTopic(
        namespace: String,
        sourceId: CoatyUUID,
        eventType: WireEventType,
        eventTypeFilter: String? = nil,
        correlationId: String? = nil
    ) -> String {
        var topic = "coaty/3/\(namespace)/\(eventType.rawValue)"
        if let filter = eventTypeFilter, !filter.isEmpty {
            topic += ":\(filter)"
        }
        topic += "/\(sourceId.string)"
        if !eventType.isOneWay {
            topic += "/\(correlationId!)"
        }
        return topic
    }

    // MARK: - Subscription topics

    /// Builds a Coaty subscription topic filter string.
    ///
    /// The filter shape is
    /// `coaty/3/[<namespace>|+]/<eventType>[:<filter>]/+[/<correlationId>|+]`,
    /// with the correlation-id level present only for two-way event types.
    /// A nil `namespace` widcards the namespace level (`+`); a nil
    /// `correlationId` wildcards it.
    ///
    /// - Parameters:
    ///   - eventType: The Coaty event type to subscribe to.
    ///   - eventTypeFilter: An optional event-type filter.
    ///   - namespace: The messaging namespace, or nil to subscribe across
    ///     namespaces.
    ///   - correlationId: The correlation id for a two-way response
    ///     subscription, or nil to subscribe to all requests of that type.
    /// - Returns: A topic filter string suitable for subscribing.
    static func subscribeTopic(
        eventType: WireEventType,
        eventTypeFilter: String? = nil,
        namespace: String? = nil,
        correlationId: String? = nil
    ) -> String {
        var topic = "coaty/3/\(namespace ?? "+")/\(eventType.rawValue)"
        if let filter = eventTypeFilter, !filter.isEmpty {
            topic += ":\(filter)"
        }
        topic += "/+"
        if !eventType.isOneWay {
            topic += "/\(correlationId ?? "+")"
        }
        return topic
    }

    /// Builds a namespace-scoped filter for every one-way event topic.
    ///
    /// MQTT wildcards must occupy an entire topic level, so matching every
    /// filtered Advertise level (`ADV:<filter>`) requires wildcarding the
    /// complete event level. Callers must discard non-Advertise events after
    /// parsing.
    ///
    /// - Parameter namespace: The messaging namespace, or nil to subscribe
    ///   across namespaces.
    /// - Returns: A filter matching one-way event and source levels.
    static func subscribeAllOneWayTopics(namespace: String? = nil) -> String {
        "coaty/3/\(namespace ?? "+")/+/+"
    }

    // MARK: - Topic validation

    /// Determines whether the given name is a valid topic name for
    /// publication: non-empty and free of the MQTT wildcards `#` and `+`
    /// and the NUL byte.
    ///
    /// - Parameter name: A topic name.
    /// - Returns: `true` if `name` is valid for publication.
    static func isValidPublicationTopic(_ name: String) -> Bool {
        !name.isEmpty
            && !name.contains("\u{0000}")
            && !name.contains("#")
            && !name.contains("+")
    }

    /// Determines whether the given name is a valid topic filter for
    /// subscribing: non-empty and free of the NUL byte.
    ///
    /// - Parameter name: A topic filter.
    /// - Returns: `true` if `name` is valid for subscription.
    static func isValidSubscriptionTopic(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("\u{0000}")
    }

    /// Determines whether the given data is valid as an event-type filter:
    /// a valid publication topic name that contains no `/`.
    ///
    /// - Parameter filter: An event-type filter.
    /// - Returns: `true` if `filter` is a valid event-type filter.
    static func isValidEventTypeFilter(filter: String) -> Bool {
        isValidPublicationTopic(filter) && !filter.contains("/")
    }

    // MARK: - Topic coherence validation

    /// Validates a Coaty publication topic string for structural and
    /// protocol-level coherence, throwing ``AxolotyError`` for malformed
    /// topics.
    ///
    /// This enforces the Coaty topic rules (protocol name, recognized event
    /// type, valid source-id UUID, and the correlation-id presence rules for
    /// one-way versus two-way event types). It is used to reject malformed
    /// topics; the live receive path uses ``TopicView`` (which parses
    /// defensively without these checks).
    ///
    /// - Parameter topic: A Coaty publication topic string.
    /// - Throws: ``AxolotyError`` of the `invalidArgument` category when
    ///   the topic is structurally or semantically malformed.
    static func validate(_ topic: String) throws {
        let levels = topic.components(separatedBy: "/")

        guard levels.count >= 5 else {
            throw AxolotyError.invalidArgument(
                argument: "topic",
                reason: "\"\(topic)\" has fewer than 5 segments"
            )
        }

        let protocolName = levels[0]
        let version = levels[1]
        let namespace = levels[2]
        let eventName = levels[3]
        let sourceId = levels[4]
        let corrId: String? = levels.count == 6 ? levels[5] : nil
        let postfix: String? = levels.count >= 7 ? levels[6] : nil

        guard protocolName == "coaty",
              !version.isEmpty,
              !namespace.isEmpty,
              !eventName.isEmpty,
              !sourceId.isEmpty else {
            throw AxolotyError.invalidArgument(argument: "topic", reason: "\"\(topic)\" is malformed")
        }
        guard (corrId == nil && postfix == nil)
                || (corrId != nil && !corrId!.isEmpty && postfix == nil) else {
            throw AxolotyError.invalidArgument(argument: "topic", reason: "\"\(topic)\" is malformed")
        }
        guard CoatyUUID(uuidString: sourceId) != nil else {
            throw AxolotyError.invalidArgument(
                argument: "sourceId",
                reason: "\"\(sourceId)\" is not a valid topic sourceId"
            )
        }
        guard let (eventType, eventTypeFilter) = extractEventType(eventName) else {
            throw AxolotyError.invalidArgument(
                argument: "eventType",
                reason: "\"\(eventName)\" is not a valid topic event type"
            )
        }

        if eventType.isOneWay {
            if corrId != nil {
                throw AxolotyError.invalidArgument(
                    argument: "correlationId",
                    reason: "must not be present for one-way \(eventType) event"
                )
            }
            if (eventType == .advertise || eventType == .channel || eventType == .associate)
                && (eventTypeFilter == nil || eventTypeFilter!.isEmpty) {
                throw AxolotyError.invalidArgument(
                    argument: "eventTypeFilter",
                    reason: "required for \(eventType) event"
                )
            }
            if eventType != .advertise && eventType != .channel && eventType != .associate
                && eventTypeFilter != nil {
                throw AxolotyError.invalidArgument(
                    argument: "eventTypeFilter",
                    reason: "must not be present for \(eventType) event"
                )
            }
        } else {
            if corrId == nil {
                throw AxolotyError.invalidArgument(
                    argument: "correlationId",
                    reason: "required for two-way event: \(eventType)"
                )
            }
            if (eventType == .call || eventType == .update)
                && (eventTypeFilter == nil || eventTypeFilter!.isEmpty) {
                throw AxolotyError.invalidArgument(
                    argument: "eventTypeFilter",
                    reason: "required for \(eventType) event"
                )
            }
            if eventType != .call && eventType != .update && eventTypeFilter != nil {
                throw AxolotyError.invalidArgument(
                    argument: "eventTypeFilter",
                    reason: "must not be present for \(eventType) event"
                )
            }
        }
    }

    /// Splits an event level (`ADV` or `ADV:filter`) into its type and filter.
    private static func extractEventType(_ eventName: String) -> (WireEventType, String?)? {
        if let index = eventName.firstIndex(of: ":") {
            let type = String(eventName[..<index])
            let filter = String(eventName[eventName.index(after: index)...])
            guard let evType = WireEventType(rawValue: type) else { return nil }
            return (evType, filter)
        }
        guard let evType = WireEventType(rawValue: eventName) else { return nil }
        return (evType, nil)
    }

    // MARK: - MQTT filter matching

    /// Determines whether the given MQTT topic matches the given MQTT topic
    /// filter.
    ///
    /// Examples:
    /// * topic filter `a/b/#` matches topics `a/b/c/d`, `a/b/c`, ...
    /// * topic filter `a/+/+` matches topic `a/b/c`, but _not_ `a/b/c/d`
    /// * topic filter `a/+/b` matches topic `a/c/b` and `a//b`
    /// * topic filters `/`, `+/`, `/+`, and `+/+` match topic `/`
    ///
    /// - Note: Matching assumes both topic and filter are valid according to
    ///   the MQTT 3.1.1 specification; otherwise the result is undefined.
    /// - Parameters:
    ///   - topic: A valid MQTT topic name.
    ///   - filter: A valid MQTT topic filter.
    /// - Returns: `true` if `topic` matches `filter`; otherwise `false`.
    static func matches(_ topic: String, _ filter: String) -> Bool {
        if topic.isEmpty || filter.isEmpty {
            return false
        }

        let patternLevels = filter.components(separatedBy: "/")
        let topicLevels = topic.components(separatedBy: "/")

        var topicIndex = 0
        for (patternIndex, patternLevel) in patternLevels.enumerated() {
            if patternLevel == "#" {
                return patternIndex == patternLevels.count - 1
            }

            guard topicIndex < topicLevels.count else {
                return false
            }

            let topicLevel = topicLevels[topicIndex]
            guard patternLevel == "+" || patternLevel == topicLevel else {
                return false
            }

            topicIndex += 1
        }

        return topicIndex == topicLevels.count
    }
}
