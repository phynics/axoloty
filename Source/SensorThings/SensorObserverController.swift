// Copyright (c) 2020 Siemens AG. Licensed under the MIT License.

import Foundation

/// Observes Sensors and Sensor-related objects using async event streams.
open class SensorObserverController: Controller {
    /// Observes advertised Sensor snapshots.
    public func observeAdvertisedSensorsStream() async throws -> AsyncStream<AdvertiseEventSnapshot> {
        try await communicationManager.observeAdvertiseStream(withObjectType: SensorThingsTypes.OBJECT_TYPE_SENSOR)
    }

    /// Observes advertised Observation snapshots belonging to a Sensor.
    public func observeAdvertisedObservationsStream(sensorId: CoatyUUID) async throws -> AsyncStream<AdvertiseEventSnapshot> {
        let sensorIdString = sensorId.string
        let source = try await communicationManager.observeAdvertiseStream(withObjectType: SensorThingsTypes.OBJECT_TYPE_OBSERVATION)
        return filteredStream(source) { $0.object.parentObjectId == sensorIdString }
    }

    /// Observes channeled Observation snapshots belonging to a Sensor.
    public func observeChanneledObservationsStream(sensorId: CoatyUUID, channelId: String? = nil) async throws -> AsyncStream<ChannelEventSnapshot> {
        let sensorIdString = sensorId.string
        let source = try await communicationManager.observeChannelStream(channelId: channelId ?? sensorId.string)
        return filteredStream(source) { $0.object?.objectType == SensorThingsTypes.OBJECT_TYPE_OBSERVATION && $0.object?.parentObjectId == sensorIdString }
    }

    /// Discovers Sensor response snapshots.
    public func discoverSensorsStream() async -> AsyncStream<ResponseEventSnapshot> {
        await communicationManager.publishDiscover(DiscoverEvent.with(objectTypes: [SensorThingsTypes.OBJECT_TYPE_SENSOR]))
    }

    /// Queries Sensor response snapshots for a Thing.
    public func querySensorsOfThingsStream(thingId: CoatyUUID) async -> AsyncStream<ResponseEventSnapshot> {
        await communicationManager.publishQuery(QueryEvent.with(objectTypes: [SensorThingsTypes.OBJECT_TYPE_SENSOR], objectFilter: nil, objectJoinConditions: nil))
    }

    private func filteredStream<Element: Sendable>(_ source: AsyncStream<Element>, _ predicate: @escaping @Sendable (Element) -> Bool) -> AsyncStream<Element> {
        let (stream, continuation) = AsyncStream<Element>.makeStream(bufferingPolicy: .bufferingNewest(256))
        let task = _Concurrency.Task {
            for await element in source where predicate(element) { continuation.yield(element) }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }
}
