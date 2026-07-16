//  Copyright (c) 2020 Siemens AG. Licensed under the MIT License.
//
//  SensorThingsMocks.swift
//  Axoloty

import Axoloty
import Foundation
import Logging

final class AdvertiseEventLogger: @unchecked Sendable {
    var count: Int = 0
    var eventData: [AdvertiseEventData] = []
}

final class ChannelEventLogger: @unchecked Sendable {
    var count: Int = 0
    var eventData: [ChannelEventData] = []
}

final class RawEventLogger: @unchecked Sendable {
    var count: Int = 0
    var eventData: [Any] = []
}

/// Mock controller consuming data produced by sensorThings sensors.
class MockReceiverController: Controller, @unchecked Sendable {
    let log = Logging.Logger(label: "AxolotyTests.MockReceiverController")

    override func onInit() {
        super.onInit()
    }

    override func onCommunicationManagerStarting() {
        log.info("Starting the container with name: \(registeredName)")
    }

    override func onCommunicationManagerStopping() {
        log.info("Stopping the container with name: \(registeredName)")
    }

    /// Subscribes to advertise events and only returns once both the broker
    /// has acknowledged the subscription and this consumer's iterator is
    /// attached to the event hub, so callers don't need to guess a "long
    /// enough" delay before publishing (see
    /// https://github.com/phynics/axoloty/issues/51).
    ///
    /// Uses `makeAsyncIteratorAndWait()` rather than plain `for await`: a bare
    /// `for await` creates its iterator via `makeAsyncIterator()`, whose event
    /// hub registration is a detached, unawaited task. That leaves a real gap
    /// between "the broker acknowledged the subscription" and "this consumer
    /// can actually receive events", which intermittently dropped the first
    /// events published right after subscribing.
    func watchForAdvertiseEvents(logger: AdvertiseEventLogger, objectType: String) async throws -> _Concurrency.Task<Void, Never> {
        let stream = try await communicationManager.observeAdvertiseStream(withObjectType: objectType)
        let box = SharedAsyncIteratorBox(await stream.makeAsyncIteratorAndWait())
        return _Concurrency.Task { @MainActor in
            while let event = await box.iterator.next() {
                guard let object = event.object.decodeObject() as? CoatyObject else { continue }
                logger.count += 1
                if let event = try? AdvertiseEvent.with(object: object) { logger.eventData.append(event.data) }
            }
        }
    }

    /// Subscribes to channel events and only returns once both the broker has
    /// acknowledged the subscription and this consumer's iterator is attached
    /// to the event hub (see `watchForAdvertiseEvents` above for why a bare
    /// `for await` isn't sufficient, and
    /// https://github.com/phynics/axoloty/issues/51 for the subscription-ack
    /// half of this guarantee).
    func watchForChannelEvents(logger: ChannelEventLogger, channelId: String) async throws -> _Concurrency.Task<Void, Never> {
        let stream = try await communicationManager.observeChannelStream(channelId: channelId)
        let box = SharedAsyncIteratorBox(await stream.makeAsyncIteratorAndWait())
        return _Concurrency.Task { @MainActor in
            while let event = await box.iterator.next() {
                if let object = event.object.flatMap({ try? $0.decodeObject() }) {
                    logger.count += 1
                    if let event = try? ChannelEvent.with(object: object, channelId: channelId) { logger.eventData.append(event.data) }
                }
            }
        }
    }

    func watchForRawEvents(logger: RawEventLogger, topic: String) {
        _Concurrency.Task { @MainActor in
            let stream = await self.communicationManager.observeRawMQTTMessageStream()
            for await value in stream where value.topic == topic {
                logger.count += 1
                logger.eventData.append(value.payload)
            }
        }
    }
}

/// Mock controller producing  sensorThings observations.
class MockEmitterController: Controller, @unchecked Sendable {
    private var _name: String = ""
    let log = Logging.Logger(label: "AxolotyTests.MockEmitterController")

    override func onInit() {
        super.onInit()
        _name = options?.extra["name"] as! String

        _handleDiscoverEvents()
    }

    override func onCommunicationManagerStarting() {
        log.info("Starting the container with name: \(registeredName)")
    }

    override func onCommunicationManagerStopping() {
        log.info("Stopping the container with name: \(registeredName)")
    }

    /// Publish count objects of type objectType through advertise.
    /// - Parameters:
    ///     - count: number Number of times a different object will be advertised
    ///     - objectType: ObjectType the type for objects to be emitted
    func publishAdvertiseEvents(count: Int = 1, objectType: String) {
        for i in 1 ... count {
            _ = try? communicationManager
                .publishAdvertise(
                    AdvertiseEvent.with(
                        object: _createSensorThings(i: i,
                                                    objectType: objectType,
                                                    name: "Advertised")
                    )
                )
        }
    }

    /// Publish count objects of type objectType on a given channel.
    /// - Parameters:
    ///     - count: number Number of times a different object will be published
    ///     - objectType: ObjectType the type for objects to be emitted
    ///     - channelId: the channel id on which objects will be published
    func publishChannelEvents(count: Int, objectType: String, channelId: String) {
        for i in 1 ... count {
            // Debugging output: use to debug the channel test
//            print("publish event with: \(i) \(objectType)")
            _ = try? communicationManager
                .publishChannel(
                    ChannelEvent.with(
                        object: _createSensorThings(i: i,
                                                    objectType: objectType,
                                                    name: "Channeled"),
                        channelId: channelId
                    )
                )
        }
    }

    /// Count and store the advertise events for objectType
    /// - Parameters:
    ///     - logger: A logger for advertise event
    ///     - objectType: Type to look the advertise events for.
    func watchForAdvertiseEvents(logger: AdvertiseEventLogger, objectTypes: String) {
        _Concurrency.Task { @MainActor in
            guard let stream = try? await self.communicationManager.observeAdvertiseStream(withObjectType: objectTypes) else { return }
            for await event in stream {
                guard let object = event.object.decodeObject() else { continue }
                logger.count += 1
                if let event = try? AdvertiseEvent.with(object: object) { logger.eventData.append(event.data) }
            }
        }
    }

    /// Observe discover events for object of Type sensor reply to the first of them.
    private func _handleDiscoverEvents() {
        // Discovery responses are exercised by the async communication tests.
    }

    private func _createSensorThings(i: Int, objectType: String, name: String?) -> CoatyObject {
        guard let result = SensorThingsCollection.getObjectByType(objectType: objectType, uuid: .init(), i: i, name: name) else {
            fatalError("Incorrect call of _createSensorThings")
        }

        return result
    }
}

/// A factory of sensorThings objects used to check validator behaviours.
///
/// Each `_make*` function returns a brand-new instance. These object types
/// are classes, and earlier revisions shared one mutable static instance per
/// type across the whole test process; concurrently running tests (or loop
/// iterations) publishing the same objectType raced to overwrite that shared
/// instance's `objectId`/`name` between construction and the point the
/// communication layer serializes it, which could silently corrupt or drop
/// events. A fresh instance per call removes the shared mutable state
/// instead of papering over the race with timing.
class SensorThingsCollection {
    private static func _makeSensor() -> Sensor {
        Sensor(description: "A thermometer measures the temperature",
               encodingType: SensorEncodingTypes.UNDEFINED,
               metadata: AnyCodable(),
               unitOfMeasurement: UnitOfMeasurement(name: "Celsius",
                                                    symbol: "degC",
                                                    definition: "http://www.qudt.org/qudt/owl/1.0.0/unit/Instances.html#DegreeCelsius"),
               observationType: ObservationTypes.MEASUREMENT,
               phenomenonTime: CoatyTimeInterval(start: Date().millisecondsSince1970 - 1000,
                                                 end: Date().millisecondsSince1970),
               resultTime: CoatyTimeInterval(start: Date().millisecondsSince1970 - 1000,
                                             end: Date().millisecondsSince1970),
               observedProperty: ObservedProperty(name: "Temperature",
                                                  definition: "http://dbpedia.org/page/Dew_point",
                                                  description: "DewPoint Temperature"),
               name: "Thermometer",
               objectId: CoatyUUID(uuidString: "83dfc46a-0709-4f70-9ea5-beebf8fa89af")!,
               parentObjectId: CoatyUUID(uuidString: "4c480c29-f65f-496f-8005-03e7503eec2b")!)
    }

    private static func _makeFeatureOfInterest() -> FeatureOfInterest {
        FeatureOfInterest(description: "feature of interest",
                          encodingType: EncodingTypes.UNDEFINED,
                          metadata: AnyCodable("interesting"),
                          name: "F0I1",
                          objectId: CoatyUUID(uuidString: "b15521af-9077-4b22-978a-5ff8381d53ae")!)
    }

    private static func _makeLocation() -> Location {
        Location(geoLocation: GeoLocation(coords: GeoCoordinates(latitude: 32, longitude: 46, accuracy: 1),
                                          timestamp: Double(Date().millisecondsSince1970)),
                 name: "Muenchen",
                 objectType: Location.objectType,
                 objectId: CoatyUUID(uuidString: "14119642-ee6a-4596-bf34-d8a3436290d3")!)
    }

    private static func _makeObservation() -> Observation {
        Observation(phenomenonTime: Double(Date().millisecondsSince1970),
                    result: AnyCodable("12.50"),
                    resultTime: Double(Date().millisecondsSince1970),
                    featureOfInterest: CoatyUUID(uuidString: "b15521af-9077-4b22-978a-5ff8381d53ae")!,
                    name: "Observation1",
                    objectId: CoatyUUID(uuidString: "31ba0e43-ea26-4179-acf2-299e3a9a0f92")!,
                    parentObjectId: CoatyUUID(uuidString: "83dfc46a-0709-4f70-9ea5-beebf8fa89af")!)
    }

    private static func _makeThing() -> Thing {
        Thing(description: "",
              name: "Thing1",
              objectId: CoatyUUID(uuidString: "4c480c29-f65f-496f-8005-03e7503eec2b")!,
              locationId: CoatyUUID(uuidString: "14119642-ee6a-4596-bf34-d8a3436290d3")!)
    }

    static func getObjectByType(objectType: String,
                                uuid: CoatyUUID,
                                i: Int? = nil,
                                name: String? = nil) -> CoatyObject?
    {
        // routing
        let result = SensorThingsCollection._objectTypeRouter(objectType: objectType)
        result?.objectId = uuid
        if let object = result, let name = name, let i = i {
            object.name = name + "_" + "\(i)"
        }
        return result
    }

    private static func _objectTypeRouter(objectType: String) -> CoatyObject? {
        switch objectType {
        case SensorThingsTypes.OBJECT_TYPE_SENSOR:
            return SensorThingsCollection._makeSensor()
        case SensorThingsTypes.OBJECT_TYPE_FEATURE_OF_INTEREST:
            return SensorThingsCollection._makeFeatureOfInterest()
        case CoreType.Location.objectType:
            return SensorThingsCollection._makeLocation()
        case SensorThingsTypes.OBJECT_TYPE_OBSERVATION:
            return SensorThingsCollection._makeObservation()
        case SensorThingsTypes.OBJECT_TYPE_THING:
            return SensorThingsCollection._makeThing()
        default:
            return nil
        }
    }
}

// MARK: - Date extension.

extension Date {
    var millisecondsSince1970: Int {
        return Int((timeIntervalSince1970 * 1000.0).rounded())
    }
}

private final class SendableBox<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) {
        self.value = value
    }
}
