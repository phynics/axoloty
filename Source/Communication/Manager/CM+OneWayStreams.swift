// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

@MainActor
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
            onLast: {
                _Concurrency.Task {
                    await coordinator.release(topic: topic)
                }
            }
        )
    }

    /// Observes incoming Query snapshots.
    ///
    /// Use the snapshot's ``QueryEventSnapshot/correlationId`` to publish a
    /// ``RetrieveEvent`` response via
    /// ``CommunicationManager/publishRetrieve(event:correlationId:)``.
    ///
    /// - Returns: An event-buffered stream of immutable Query snapshots.
    public func observeQueryStream() async -> EventStream<QueryEventSnapshot> {
        let namespace = communicationOptions.shouldEnableCrossNamespacing ? nil : self.namespace
        let topic = CommunicationTopic.createTopicStringByLevelsForSubscribe(
            eventType: .Query,
            namespace: namespace
        )
        let coordinator = subscriptionCoordinator!
        await coordinator.acquire(topic: topic)
        return await eventHub.registerStream(
            key: CommunicationEventHubKeys.query,
            buffering: .event,
            onLast: {
                _Concurrency.Task {
                    await coordinator.release(topic: topic)
                }
            }
        )
    }

    /// Observes incoming Call snapshots for a specific operation.
    ///
    /// Use the snapshot's ``CallEventSnapshot/correlationId`` to publish a
    /// ``ReturnEvent`` response via
    /// ``CommunicationManager/publishReturn(event:correlationId:)``.
    ///
    /// - Parameter operation: The remote operation name to observe.
    /// - Throws: ``AxolotyError.invalidArgument(argument:reason:)`` when
    ///   `operation` is not a valid event type filter.
    /// - Returns: An event-buffered stream of immutable Call snapshots.
    public func observeCallStream(operation: String) async throws -> EventStream<CallEventSnapshot> {
        guard CommunicationTopic.isValidEventTypeFilter(filter: operation) else {
            throw AxolotyError.invalidArgument(argument: "operation", reason: "\"\(operation)\" is not a valid call operation")
        }
        let namespace = communicationOptions.shouldEnableCrossNamespacing ? nil : self.namespace
        let topic = CommunicationTopic.createTopicStringByLevelsForSubscribe(
            eventType: .Call,
            eventTypeFilter: operation,
            namespace: namespace
        )
        let coordinator = subscriptionCoordinator!
        await coordinator.acquire(topic: topic)
        return await eventHub.registerStream(
            key: CommunicationEventHubKeys.call(operation: operation),
            buffering: .event,
            onLast: {
                _Concurrency.Task {
                    await coordinator.release(topic: topic)
                }
            }
        )
    }
}
