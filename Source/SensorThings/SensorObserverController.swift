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
    ///
    /// The query carries an `Equals` ``ObjectFilter`` on `parentObjectId`
    /// equal to `thingId`, so peers only resolve Sensors whose parent Thing is
    /// the requested one (P1-7).
    public func querySensorsOfThingsStream(thingId: CoatyUUID) async -> AsyncStream<ResponseEventSnapshot> {
        let objectFilter = objectIdEqualsFilter(property: "parentObjectId", id: thingId)
        return await communicationManager.publishQuery(
            QueryEvent.with(
                objectTypes: [SensorThingsTypes.OBJECT_TYPE_SENSOR],
                objectFilter: objectFilter,
                objectJoinConditions: nil
            )
        )
    }

    /// Builds an `Equals` ``ObjectFilter`` on the given property (a UUID wire
    /// key) matching a single id, so a remote query is narrowed to the
    /// requested relation instead of returning every object of the type.
    private func objectIdEqualsFilter(property: String, id: CoatyUUID) -> ObjectFilter? {
        do {
            return try ObjectFilter.buildWithCondition { builder in
                builder.condition = try ObjectFilterCondition.build { conditionBuilder in
                    conditionBuilder.property = ObjectFilterProperty(property)
                    conditionBuilder.expression = FilterOperations.equals(FilterOperand(id))
                }
            }
        } catch {
            return nil
        }
    }

    private func filteredStream<Element: Sendable>(_ source: AsyncStream<Element>, _ predicate: @escaping @Sendable (Element) -> Bool) -> AsyncStream<Element> {
        let (stream, continuation) = AsyncStream<Element>.makeStream(bufferingPolicy: .bufferingNewest(256))
        let task = Task {
            for await element in source where predicate(element) { continuation.yield(element) }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }
}
