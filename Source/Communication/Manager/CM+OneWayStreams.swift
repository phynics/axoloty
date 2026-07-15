// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

extension CommunicationManager {

    /// Observes incoming Deadvertise snapshots.
    ///
    /// - Returns: An event-buffered stream of immutable Deadvertise snapshots.
    public func observeDeadvertiseStream() async -> EventStream<DeadvertiseEventSnapshot> {
        let namespace = communicationOptions.shouldEnableCrossNamespacing ? nil : self.namespace
        let topic = CommunicationTopic.createTopicStringByLevelsForSubscribe(
            eventType: .Deadvertise,
            namespace: namespace
        )
        let coordinator = subscriptionCoordinator!
        await coordinator.acquire(topic: topic)
        return await eventHub.registerStream(
            key: CommunicationEventHubKeys.deadvertise,
            buffering: .event,
            onFirst: {},
            onLast: {
                _Concurrency.Task {
                    await coordinator.release(topic: topic)
                }
            }
        )
    }

    /// Observes incoming Discover snapshots.
    ///
    /// - Returns: An event-buffered stream of immutable Discover snapshots.
    public func observeDiscoverStream() async -> EventStream<DiscoverEventSnapshot> {
        let namespace = communicationOptions.shouldEnableCrossNamespacing ? nil : self.namespace
        let topic = CommunicationTopic.createTopicStringByLevelsForSubscribe(
            eventType: .Discover,
            namespace: namespace
        )
        let coordinator = subscriptionCoordinator!
        await coordinator.acquire(topic: topic)
        return await eventHub.registerStream(
            key: CommunicationEventHubKeys.discover,
            buffering: .event,
            onFirst: {},
            onLast: {
                _Concurrency.Task {
                    await coordinator.release(topic: topic)
                }
            }
        )
    }
}
