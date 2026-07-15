//  Copyright (c) 2020 Siemens AG. Licensed under the MIT License.
//
//  SensorObserverController.swift
//  Axoloty
//

import Foundation
import RxSwift

// MARK: - SensorObserverController.

/// Observes Sensors and Sensor-related objects. This controller is designed to
/// be used by a client as a counterpart to a SensorSourceController which should
/// answer its requests.
open class SensorObserverController: Controller {

    /// Returns an async stream of immutable snapshots for advertised Sensors.
    ///
    /// Consumers can decode the snapshot's preserved payload with
    /// ``CoatyObjectSnapshot/decodeObject()`` when they need the concrete
    /// Sensor model. The stream owns its MQTT subscription while iterated.
    ///
    /// - Returns: An event-buffered stream of Sensor Advertise snapshots.
    /// - Throws: ``AxolotyError/InvalidArgument`` if the registered Sensor
    ///   object type is invalid.
    public func observeAdvertisedSensorsStream() async throws -> EventStream<AdvertiseEventSnapshot> {
        try await self.communicationManager.observeAdvertiseStream(
            withObjectType: SensorThingsTypes.OBJECT_TYPE_SENSOR
        )
    }

    /// Returns an async stream of advertised Observation snapshots belonging
    /// to the given Sensor.
    ///
    /// The returned snapshots preserve their wire payload and can be decoded
    /// with ``CoatyObjectSnapshot/decodeObject()`` when a concrete Observation
    /// is needed.
    ///
    /// - Parameter sensorId: Object identifier of the Sensor to observe.
    /// - Returns: A filtered stream of Observation Advertise snapshots.
    /// - Throws: ``AxolotyError/InvalidArgument`` if the Observation object
    ///   type is invalid.
    public func observeAdvertisedObservationsStream(
        sensorId: CoatyUUID
    ) async throws -> AsyncStream<AdvertiseEventSnapshot> {
        let sensorIdString = sensorId.string
        let source = try await self.communicationManager.observeAdvertiseStream(
            withObjectType: SensorThingsTypes.OBJECT_TYPE_OBSERVATION
        )
        return filteredStream(source) { snapshot in
            snapshot.object.parentObjectId == sensorIdString
        }
    }

    /// Returns an async stream of channeled Observation snapshots belonging to
    /// the given Sensor.
    ///
    /// - Parameters:
    ///   - sensorId: Object identifier of the Sensor to observe.
    ///   - channelId: Channel identifier, defaulting to the Sensor object id.
    /// - Returns: A filtered stream of Observation Channel snapshots.
    /// - Throws: ``AxolotyError/InvalidArgument`` when `channelId` is invalid.
    public func observeChanneledObservationsStream(
        sensorId: CoatyUUID,
        channelId: String? = nil
    ) async throws -> AsyncStream<ChannelEventSnapshot> {
        let sensorIdString = sensorId.string
        let source = try await self.communicationManager.observeChannelStream(
            channelId: channelId ?? sensorId.string
        )
        return filteredStream(source) { snapshot in
            guard let object = snapshot.object else {
                return false
            }
            return object.objectType == SensorThingsTypes.OBJECT_TYPE_OBSERVATION
                && object.parentObjectId == sensorIdString
        }
    }

    private func filteredStream<Element: Sendable>(
        _ source: EventStream<Element>,
        _ predicate: @escaping @Sendable (Element) -> Bool
    ) -> AsyncStream<Element> {
        let (stream, continuation) = AsyncStream<Element>.makeStream()
        let task = _Concurrency.Task {
            for await element in source {
                if predicate(element) {
                    continuation.yield(element)
                }
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in
            task.cancel()
        }
        return stream
    }
    
    /// Observe the channeled observations for the given Sensor. By default, the
    /// channelId is the same as the sensorId.
    ///
    /// - Parameters:
    ///     - sensorId: ObjectId of the sensor to listen observations of.
    ///     - channelId: ChannelId to listen to. This is by default the objectId
    ///     of the Sensor and therefore should be left nil. (optional)
    public func observeChanneledObservations(sensorId: CoatyUUID, channelId: String? = nil) throws -> Observable<Observation> {
        return try self.communicationManager
            .observeChannel(channelId: channelId != nil ? channelId! : sensorId.string)
            .filter({ event -> Bool in
                return event.data.object != nil
                    && event.data.object!.objectType == SensorThingsTypes.OBJECT_TYPE_OBSERVATION
                    && event.data.object?.parentObjectId == sensorId
            }).map({ event -> Observation in
                // Fail-fast invariant, not user input.
                // swiftlint:disable:next force_cast
                return event.data.object as! Observation
            })
    }
    
    /// Observe the advertised observations for the given Sensor.
    ///
    /// - Parameter sensorId: ObjectId of the sensor to listen observations of.
    public func observeAdvertisedObservations(sensorId: CoatyUUID) throws -> Observable<Observation> {
        return try self.communicationManager
            .observeAdvertise(withObjectType: SensorThingsTypes.OBJECT_TYPE_OBSERVATION)
            .filter({ event -> Bool in
                return event.data.object.parentObjectId! == sensorId
            }).map({ event -> Observation in
                // Fail-fast invariant, not user input.
                // swiftlint:disable:next force_cast
                return event.data.object as! Observation
            })
    }
    
    /// Returns an observable emitting advertised Sensors.
    
    /// This method does not perform any kind of caching and it should
    /// be performed on the application-side.
    public func observeAdvertisedSensors() throws -> Observable<Sensor> {
        return try self.communicationManager
            .observeAdvertise(withObjectType: SensorThingsTypes.OBJECT_TYPE_SENSOR)
            .compactMap({ event -> Sensor? in
                return event.data.object as? Sensor
            })
    }
    
    /// Returns an observable of the Sensors in the system.
    ///
    /// This is performed by sending a Discovery event with the object type of
    /// Sensor.
    ///
    /// This method does not perform any kind of caching and it should be
    /// performed on the application-side.
    public func discoverSensors() -> Observable<Sensor> {
        return self.communicationManager
            .publishDiscover(DiscoverEvent.with(objectTypes: [SensorThingsTypes.OBJECT_TYPE_SENSOR]))
            .compactMap({ event -> Sensor? in
                return event.data.object as? Sensor
            })
    }
    
    /// Returns an observable of the Sensors that are associated with this Thing.
    ///
    /// This is performed by sending a Query event for Sensor objects with the
    /// parentObjectId matching the objectId of the Thing.
    ///
    /// This method does not perform any kind of caching and it should be
    /// performed on the application-side.
    public func querySensorsOfThings(thingId: CoatyUUID) -> Observable<[Sensor]> {
        let objectFilter = ObjectFilter(conditions: ObjectFilterConditions(and: [ObjectFilterCondition(property: ObjectFilterProperty("parentObjectId"),
                                                                                                       expression: ObjectFilterExpression(filterOperator: .Equals,
                                                                                                                                          op1: AnyCodable(thingId)))]))
        
        return self.communicationManager
            .publishQuery(QueryEvent.with(objectTypes: [SensorThingsTypes.OBJECT_TYPE_SENSOR],
                                          objectFilter: objectFilter,
                                          objectJoinConditions: nil))
            .map { event -> [Sensor] in
                // Fail-fast invariant, not user input.
                // swiftlint:disable:next force_cast
                return event.data.objects as! [Sensor]
        }
    }
}
