// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

extension CommunicationManager {

    /// Observes Update events for a core type as immutable snapshots.
    public func observeUpdateStream(withCoreType coreType: CoreType) async -> EventStream<UpdateEventSnapshot> {
        let topic = CommunicationTopic.createTopicStringByLevelsForSubscribe(
            eventType: .Update,
            eventTypeFilter: coreType.rawValue,
            namespace: communicationOptions.shouldEnableCrossNamespacing ? nil : namespace
        )
        await acquireSubscription(topic: topic)
        let coordinator = subscriptionCoordinator!
        return await registerSnapshotStream(
            key: CommunicationEventHubKeys.update(eventTypeFilter: coreType.rawValue),
            onLast: {
                _Concurrency.Task { await coordinator.release(topic: topic) }
            }
        )
    }

    /// Observes Channel events for a channel identifier as immutable snapshots.
    ///
    /// - Throws: ``AxolotyError.InvalidArgument`` when `channelId` is invalid.
    public func observeChannelStream(channelId: String) async throws -> EventStream<ChannelEventSnapshot> {
        guard CommunicationTopic.isValidEventTypeFilter(filter: channelId) else {
            throw AxolotyError.InvalidArgument("\(channelId) is not a valid channel Id.")
        }
        let topic = CommunicationTopic.createTopicStringByLevelsForSubscribe(
            eventType: .Channel,
            eventTypeFilter: channelId,
            namespace: communicationOptions.shouldEnableCrossNamespacing ? nil : namespace
        )
        await acquireSubscription(topic: topic)
        let coordinator = subscriptionCoordinator!
        return await registerSnapshotStream(
            key: CommunicationEventHubKeys.channel(channelId: channelId),
            onLast: {
                _Concurrency.Task { await coordinator.release(topic: topic) }
            }
        )
    }

    private func registerSnapshotStream<Element: Sendable>(
        key: CommunicationEventHubKey,
        onLast: @escaping @Sendable () -> Void
    ) async -> EventStream<Element> {
        await client.eventHub.registerStream(
            key: key,
            buffering: .event,
            onFirst: {},
            onLast: onLast
        )
    }
}
