// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

extension CommunicationManager {

    /// Returns an async stream of Advertise events for the given core type.
    ///
    /// The stream uses event buffering and does not replay historical
    /// advertisements. The underlying MQTT subscription is established when the
    /// first iterator is created and removed when the last iterator terminates.
    ///
    /// - Parameter coreType: the core type of objects to observe.
    /// - Returns: an ``EventStream`` of ``AdvertiseEventSnapshot`` values.
    public func observeAdvertiseStream(
        withCoreType coreType: CoreType
    ) async -> EventStream<AdvertiseEventSnapshot> {
        let namespace = self.communicationOptions.shouldEnableCrossNamespacing ? nil : self.namespace
        let topic = CommunicationTopic.createTopicStringByLevelsForSubscribe(
            eventType: .Advertise,
            eventTypeFilter: coreType.rawValue,
            namespace: namespace
        )

        return await registerAdvertiseStream(
            topic: topic,
            eventTypeFilter: coreType.rawValue
        )
    }

    /// Returns an async stream of Advertise events for the given object type.
    ///
    /// When the object type corresponds to a Coaty core type, the stream
    /// subscribes on the core type topic and filters out objects whose
    /// `objectType` does not match, matching the behavior of the legacy Rx API.
    ///
    /// - Parameter objectType: the object type of objects to observe.
    /// - Returns: an ``EventStream`` of ``AdvertiseEventSnapshot`` values.
    /// - Throws: ``AxolotyError/InvalidArgument`` if the object type is invalid.
    public func observeAdvertiseStream(
        withObjectType objectType: String
    ) async throws -> EventStream<AdvertiseEventSnapshot> {
        guard CommunicationTopic.isValidEventTypeFilter(filter: objectType) else {
            throw AxolotyError.InvalidArgument("\(objectType) is not a valid object type")
        }

        let namespace = self.communicationOptions.shouldEnableCrossNamespacing ? nil : self.namespace

        if let coreType = CoreType.getCoreType(forObjectType: objectType) {
            let topic = CommunicationTopic.createTopicStringByLevelsForSubscribe(
                eventType: .Advertise,
                eventTypeFilter: coreType.rawValue,
                namespace: namespace
            )
            return await registerAdvertiseStream(
                topic: topic,
                eventTypeFilter: coreType.rawValue,
                objectTypeFilter: objectType
            )
        }

        let topic = CommunicationTopic.createTopicStringByLevelsForSubscribe(
            eventType: .Advertise,
            eventTypeFilter: EVENT_TYPE_FILTER_SEPARATOR + objectType,
            namespace: namespace
        )
        return await registerAdvertiseStream(
            topic: topic,
            eventTypeFilter: EVENT_TYPE_FILTER_SEPARATOR + objectType
        )
    }

    // MARK: - Registration helper.

    private func registerAdvertiseStream(
        topic: String,
        eventTypeFilter: String,
        objectTypeFilter: String? = nil
    ) async -> EventStream<AdvertiseEventSnapshot> {
        let bridge = AdvertiseStreamLifecycleBridge(manager: self)
        let key = CommunicationEventHubKeys.advertise(
            eventTypeFilter: eventTypeFilter,
            objectTypeFilter: objectTypeFilter
        )

        return await client.eventHub.registerStream(
            key: key,
            buffering: .event,
            onFirst: { bridge.subscribe(to: topic) },
            onLast: { bridge.unsubscribe(from: topic) }
        )
    }
}

// MARK: - Lifecycle bridge.

/// A small sendability bridge that forwards first/last subscription callbacks to
/// a ``CommunicationManager`` without requiring the non-sendable manager to be
/// captured directly in a `@Sendable` closure.
///
/// This helper is intentionally narrow: it only exposes subscribe/unsubscribe
/// so that the async stream lifecycle mirrors the legacy Rx observable cleanup.
private final class AdvertiseStreamLifecycleBridge: @unchecked Sendable {
    private weak var manager: CommunicationManager?

    init(manager: CommunicationManager) {
        self.manager = manager
    }

    func subscribe(to topic: String) {
        manager?.subscribe(topic: topic)
    }

    func unsubscribe(from topic: String) {
        manager?.unsubscribe(topic: topic)
    }
}
