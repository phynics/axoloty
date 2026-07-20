// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

@MainActor
extension CommunicationManager {

    /// Observes Advertise snapshots for a core type.
    ///
    /// The returned stream acquires the MQTT topic when its first iterator is
    /// created (via the ``BroadcastFamily``'s `onFirst` hook) and releases it
    /// when its final iterator terminates (via `onLast`).
    ///
    /// - Parameter coreType: The core type to observe.
    /// - Returns: An event-buffered `AsyncStream` of immutable Advertise snapshots.
    public func observeAdvertiseStream(
        withCoreType coreType: CoreType
    ) async -> AsyncStream<AdvertiseEventSnapshot> {
        await streams.advertiseFamily.subscribe(
            for: AdvertiseKey(eventTypeFilter: coreType.rawValue)
        )
    }

    /// Observes Advertise snapshots for an object type.
    ///
    /// Core object types use the corresponding core topic and object-specific
    /// routing key. Other object types use the object-type topic directly.
    ///
    /// - Parameter objectType: The object type to observe.
    /// - Returns: An event-buffered `AsyncStream` of immutable Advertise snapshots.
    /// - Throws: ``AxolotyError/invalidArgument(argument:reason:)`` when `objectType` is invalid.
    public func observeAdvertiseStream(
        withObjectType objectType: String
    ) async throws -> AsyncStream<AdvertiseEventSnapshot> {
        guard CommunicationTopic.isValidEventTypeFilter(filter: objectType) else {
            throw AxolotyError.invalidArgument(argument: "objectType", reason: "\"\(objectType)\" is not a valid object type")
        }

        if let coreType = CoreType.getCoreType(forObjectType: objectType) {
            return await streams.advertiseFamily.subscribe(
                for: AdvertiseKey(
                    eventTypeFilter: coreType.rawValue,
                    objectTypeFilter: objectType
                )
            )
        }

        let eventTypeFilter = EVENT_TYPE_FILTER_SEPARATOR + objectType
        return await streams.advertiseFamily.subscribe(
            for: AdvertiseKey(eventTypeFilter: eventTypeFilter)
        )
    }
}
