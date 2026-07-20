// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

@MainActor
extension CommunicationManager {

    /// Observes Update events for a core type as immutable snapshots.
    public func observeUpdateStream(withCoreType coreType: CoreType) async -> AsyncStream<UpdateEventSnapshot> {
        await streams.updateFamily.subscribe(for: coreType.rawValue)
    }

    /// Observes Channel events for a channel identifier as immutable snapshots.
    ///
    /// - Throws: ``AxolotyError.invalidArgument(argument:reason:)`` when `channelId` is invalid.
    public func observeChannelStream(channelId: String) async throws -> AsyncStream<ChannelEventSnapshot> {
        guard CommunicationTopic.isValidEventTypeFilter(filter: channelId) else {
            throw AxolotyError.invalidArgument(argument: "channelId", reason: "\"\(channelId)\" is not a valid channel Id")
        }
        return await streams.channelFamily.subscribe(for: channelId)
    }

    /// Observes local association state for an IO point as immutable snapshots.
    public func observeIoStateStream(ioPoint: IoPoint) async -> AsyncStream<IoStateEventSnapshot> {
        let state = _observeIoState(ioPointId: ioPoint.objectId)
        let initial = IoStateEventSnapshot(
            ioPointId: ioPoint.objectId.string,
            hasAssociations: state.eventData.hasAssociations(),
            updateRate: state.eventData.updateRate()
        )
        let ioPointId = ioPoint.objectId.string
        await streams.ioStateFamily.sendState(initial, for: ioPointId)
        return await streams.ioStateFamily.subscribe(for: ioPointId)
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
    public func observeIoValueStream() async -> AsyncStream<IoValueEventSnapshot> {
        await streams.ioValues.subscribe()
    }
}
