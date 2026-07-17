// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

@MainActor
extension CommunicationManager {

    /// Observes Advertise snapshots for a core type.
    ///
    /// The returned stream acquires the MQTT topic when its first iterator is
    /// created and releases it when its final iterator terminates.
    ///
    /// - Parameter coreType: The core type to observe.
    /// - Returns: An event-buffered stream of immutable Advertise snapshots.
    public func observeAdvertiseStream(
        withCoreType coreType: CoreType
    ) async -> EventStream<AdvertiseEventSnapshot> {
        let namespace = communicationOptions.shouldEnableCrossNamespacing ? nil : self.namespace
        let topic = CommunicationTopic.createTopicStringByLevelsForSubscribe(
            eventType: .Advertise,
            eventTypeFilter: coreType.rawValue,
            namespace: namespace
        )
        let key = CommunicationEventHubKeys.advertise(
            eventTypeFilter: coreType.rawValue
        )
        return await registerAdvertiseStream(topic: topic, key: key)
    }

    /// Observes Advertise snapshots for an object type.
    ///
    /// Core object types use the corresponding core topic and object-specific
    /// routing key. Other object types use the object-type topic directly.
    ///
    /// - Parameter objectType: The object type to observe.
    /// - Returns: An event-buffered stream of immutable Advertise snapshots.
    /// - Throws: ``AxolotyError/invalidArgument(argument:reason:)`` when `objectType` is invalid.
    public func observeAdvertiseStream(
        withObjectType objectType: String
    ) async throws -> EventStream<AdvertiseEventSnapshot> {
        guard CommunicationTopic.isValidEventTypeFilter(filter: objectType) else {
            throw AxolotyError.invalidArgument(argument: "objectType", reason: "\"\(objectType)\" is not a valid object type")
        }

        let namespace = communicationOptions.shouldEnableCrossNamespacing ? nil : self.namespace
        if let coreType = CoreType.getCoreType(forObjectType: objectType) {
            let topic = CommunicationTopic.createTopicStringByLevelsForSubscribe(
                eventType: .Advertise,
                eventTypeFilter: coreType.rawValue,
                namespace: namespace
            )
            let key = CommunicationEventHubKeys.advertise(
                eventTypeFilter: coreType.rawValue,
                objectTypeFilter: objectType
            )
            return await registerAdvertiseStream(topic: topic, key: key)
        }

        let eventTypeFilter = EVENT_TYPE_FILTER_SEPARATOR + objectType
        let topic = CommunicationTopic.createTopicStringByLevelsForSubscribe(
            eventType: .Advertise,
            eventTypeFilter: eventTypeFilter,
            namespace: namespace
        )
        let key = CommunicationEventHubKeys.advertise(eventTypeFilter: eventTypeFilter)
        return await registerAdvertiseStream(topic: topic, key: key)
    }

    private func registerAdvertiseStream(
        topic: String,
        key: CommunicationEventHubKey
    ) async -> EventStream<AdvertiseEventSnapshot> {
        let coordinator = subscriptionCoordinator!
        await coordinator.acquire(topic: topic)
        return await eventHub.registerStream(
            key: key,
            buffering: .event,
            onLast: {
                _Concurrency.Task {
                    await coordinator.release(topic: topic)
                }
            }
        )
    }
}
