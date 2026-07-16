// Copyright (c) 2020 Siemens AG. Licensed under the MIT License.

import Foundation

/// Convenience controller for observing Things, Sensors, and observations.
open class ThingSensorObservationObserverController: ThingObserverController {
    private var registeredSensors: [String: Sensor] = [:]
    private var thingFilter: ((Thing) -> Bool)?
    private var sensorFilter: ((Sensor, Thing) -> Bool)?

    /// Sets a predicate used to filter Things.
    var thingFilterPredicate: ((Thing) -> Bool)? { get { thingFilter } set { thingFilter = newValue } }
    /// Sets a predicate used to filter Sensors.
    var sensorFilterPredicate: ((Sensor, Thing) -> Bool)? { get { sensorFilter } set { sensorFilter = newValue } }

    /// Observes advertised Sensors associated with a Thing.
    public func observeSensorsStream(for thingId: CoatyUUID) async throws -> AsyncStream<AdvertiseEventSnapshot> {
        let stream = try await communicationManager.observeAdvertiseStream(withObjectType: SensorThingsTypes.OBJECT_TYPE_SENSOR)
        let (filtered, continuation) = AsyncStream<AdvertiseEventSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(256))
        let task = _Concurrency.Task {
            for await item in stream where item.object.parentObjectId == thingId.string { continuation.yield(item) }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return filtered
    }
}

/// Represents sensor registration changes.
public struct RegisteredSensorsChangeInfo {
    public let added: [Sensor]
    public let removed: [Sensor]
    public let changed: [Sensor]
    public let total: [Sensor]
}
