// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

@MainActor
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

    /// Observes local association state for an IO point as immutable snapshots.
    public func observeIoStateStream(ioPoint: IoPoint) async -> EventStream<IoStateEventSnapshot> {
        let state = _observeIoState(ioPointId: ioPoint.objectId)
        let initial = IoStateEventSnapshot(
            ioPointId: ioPoint.objectId.string,
            hasAssociations: state.eventData.hasAssociations(),
            updateRate: state.eventData.updateRate()
        )
        let key = CommunicationEventHubKeys.ioState(ioPointId: ioPoint.objectId.string)
        await client.eventHub.yieldState(value: initial, to: key)
        return await client.eventHub.registerStream(
            key: key,
            buffering: .state,
            onFirst: {},
            onLast: {}
        )
    }

    internal func _observeIoState(ioPointId: CoatyUUID) -> IoStateEvent {
        if let item = observedIoStateItems[ioPointId.string] {
            return item.currentValue
        }
        var hasAssociations = false
        var updateRate: Int?
        if let source = ioSourceItems[ioPointId.string] {
            hasAssociations = !source.actorIds.isEmpty
            updateRate = source.updateRate
        } else {
            hasAssociations = ioActorItems.values.contains { $0[ioPointId.string] != nil }
        }
        let value = IoStateEvent.with(hasAssociations: hasAssociations, updateRate: updateRate)
        observedIoStateItems[ioPointId.string] = IoStateItem(ioPointId: ioPointId, initialValue: value)
        return value
    }

    /// Observes raw IO value messages routed through the communication manager.
    public func observeIoValueStream() async -> EventStream<IoValueEventSnapshot> {
        await client.eventHub.registerStream(
            key: CommunicationEventHubKeys.ioValue,
            buffering: .event,
            onFirst: {},
            onLast: {}
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
