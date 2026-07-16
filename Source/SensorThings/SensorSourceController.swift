// Copyright (c) 2020 Siemens AG. Licensed under the MIT License.

import Foundation

/// Manages registered Sensors and publishes SensorThings observations.
open class SensorSourceController: Controller {
    private var sensors: [String: SensorContainer] = [:]
    private var samplingTasks: [String: _Concurrency.Task<Void, Never>] = [:]
    private var protocolTask: _Concurrency.Task<Void, Never>?

    override open func onInit() {
        super.onInit()
        if let definitions = options?.extra["sensors"] as? [SensorDefinition] {
            for definition in definitions {
                do {
                    try registerSensor(sensor: definition.sensor, io: definition.io.init(parameters: definition.parameters), observationPublicationType: definition.observationPublicationType, samplingInterval: definition.samplingInterval)
                } catch {
                    LogManager.log.error("Failed to register sensor \(definition.sensor.objectId.string): \(error)")
                }
            }
        }
    }

    override open func onCommunicationManagerStopping() {
        super.onCommunicationManagerStopping()
        samplingTasks.values.forEach { $0.cancel() }
        samplingTasks.removeAll()
        protocolTask?.cancel()
        protocolTask = nil
    }

    var registeredSensorContainers: [SensorContainer] { Array(sensors.values) }
    var registeredSensors: [Sensor] { sensors.values.map(\.sensor) }
    func isRegistered(sensorId: CoatyUUID) -> Bool { sensors[sensorId.string] != nil }
    func getSensorContainer(sensorId: CoatyUUID) -> SensorContainer? { sensors[sensorId.string] }
    func getSensor(sensorId: CoatyUUID) -> Sensor? { sensors[sensorId.string]?.sensor }
    func getSensorIo(sensorId: CoatyUUID) -> SensorIo? { sensors[sensorId.string]?.io }
    func findSensor(predicate: ((Sensor) -> Bool)) -> Sensor? { registeredSensors.first(where: predicate) }

    /// Registers a sensor and optionally starts periodic observation publication.
    func registerSensor(sensor: Sensor, io: SensorIo, observationPublicationType: ObservationPublicationType, samplingInterval: Int?) throws {
        guard sensors[sensor.objectId.string] == nil else { return }
        guard observationPublicationType == .none || (samplingInterval ?? 0) > 0 else { throw AxolotyError.RuntimeError("A positive sampling interval is expected.") }
        sensors[sensor.objectId.string] = SensorContainer(sensor: sensor, io: io)
        if observationPublicationType != .none, let interval = samplingInterval {
            samplingTasks[sensor.objectId.string] = _Concurrency.Task { @MainActor [weak self] in
                while !_Concurrency.Task.isCancelled {
                    do {
                        try await _Concurrency.Task.sleep(for: .milliseconds(interval))
                    } catch {
                        return
                    }
                    guard !_Concurrency.Task.isCancelled else { return }
                    try? self?._publishObservation(sensorId: sensor.objectId, channeled: observationPublicationType == .channel)
                }
            }
        }
        if options?.extra["skipSensorAdvertise"] as? Bool != true {
            do {
                try communicationManager.publishAdvertise(AdvertiseEvent.with(object: sensor))
            } catch {
                LogManager.log.error("Failed to advertise sensor \(sensor.objectId.string): \(error)")
            }
        }
        observeProtocolEventsIfNeeded()
    }

    /// Unregisters a sensor.
    func unregisterSensor(sensorId: CoatyUUID) throws {
        guard let _ = sensors.removeValue(forKey: sensorId.string) else { throw AxolotyError.RuntimeError("sensorId is not registered.") }
        samplingTasks.removeValue(forKey: sensorId.string)?.cancel()
        if options?.extra["skipSensorDeadvertise"] as? Bool != true { communicationManager.publishDeadvertise(DeadvertiseEvent.with(objectIds: [sensorId])) }
    }

    /// Publishes a channeled observation.
    func publishChanneledObservation(sensorId: CoatyUUID, resultQuality: [String]? = nil, validTime: CoatyTimeInterval? = nil, parameters: [String: String]? = nil, featureOfInterestId: CoatyUUID? = nil) {
        do {
            try _publishObservation(sensorId: sensorId, channeled: true, resultQuality: resultQuality, validTime: validTime, parameters: parameters, featureOfInterestId: featureOfInterestId)
        } catch {
            LogManager.log.error("Failed to publish channeled observation for sensor \(sensorId.string): \(error)")
        }
    }

    /// Publishes an advertised observation.
    func publishAdvertisedObservation(sensorId: CoatyUUID, resultQuality: [String]? = nil, validTime: CoatyTimeInterval? = nil, parameters: [String: String]? = nil, featureOfInterestId: CoatyUUID? = nil) {
        do {
            try _publishObservation(sensorId: sensorId, channeled: false, resultQuality: resultQuality, validTime: validTime, parameters: parameters, featureOfInterestId: featureOfInterestId)
        } catch {
            LogManager.log.error("Failed to publish advertised observation for sensor \(sensorId.string): \(error)")
        }
    }

    internal func createObservation(container: SensorContainer, value: Any, resultQuality: [String]? = nil, validTime: CoatyTimeInterval? = nil, parameters: [String: String]? = nil, featureOfInterestId: CoatyUUID? = nil) -> Observation {
        let now = Date().timeIntervalSince1970 * 1000
        return Observation(phenomenonTime: now, result: AnyCodable(value), resultTime: now, resultQuality: resultQuality, validTime: validTime, parameters: parameters, featureOfInterest: featureOfInterestId, name: "Observation of \(container.sensor.name)", objectId: .init(), externalId: nil, parentObjectId: container.sensor.objectId)
    }

    internal func getChannelId(container: SensorContainer) -> String { container.sensor.objectId.string }
    internal func onObservationWillPublish(container: SensorContainer, observation: Observation) {}
    internal func onObservationDidPublish(container: SensorContainer, observation: Observation) {}

    private func observeProtocolEventsIfNeeded() {
        guard protocolTask == nil else { return }
        protocolTask = _Concurrency.Task { @MainActor [weak self] in
            guard let self else { return }
            let stream = await communicationManager.observeParsedMessages()
            for await parsed in stream {
                guard let correlationId = parsed.correlationId else { continue }
                if parsed.eventType == .Discover, let request: DiscoverEvent = PayloadCoder.decode(parsed.payload) {
                    if request.data.isDiscoveringObjectId(), let id = request.data.objectId, let sensor = sensors[id.string] { communicationManager.publishResolve(event: ResolveEvent.with(object: sensor.sensor), correlationId: correlationId) }
                    else if request.data.isDiscoveringTypes(), request.data.isObjectTypeCompatible(objectType: SensorThingsTypes.OBJECT_TYPE_SENSOR) { for sensor in sensors.values { communicationManager.publishResolve(event: ResolveEvent.with(object: sensor.sensor), correlationId: correlationId) } }
                } else if parsed.eventType == .Query, let request: QueryEvent = PayloadCoder.decode(parsed.payload) {
                    let result = sensors.values.map(\.sensor).filter { request.data.objectFilter == nil || ObjectMatcher.matchesFilter(obj: $0, filter: request.data.objectFilter!) }
                    if !result.isEmpty { communicationManager.publishRetrieve(event: RetrieveEvent.with(objects: result), correlationId: correlationId) }
                }
            }
        }
    }

    private func _publishObservation(sensorId: CoatyUUID, channeled: Bool, resultQuality: [String]? = nil, validTime: CoatyTimeInterval? = nil, parameters: [String: String]? = nil, featureOfInterestId: CoatyUUID? = nil) throws {
        guard let container = sensors[sensorId.string] else { throw AxolotyError.RuntimeError("sensorId is not registered") }
        container.io.read { [weak self] value in
            guard let self else { return }
            let observation = self.createObservation(container: container, value: value, resultQuality: resultQuality, validTime: validTime, parameters: parameters, featureOfInterestId: featureOfInterestId)
            self.onObservationWillPublish(container: container, observation: observation)
            if channeled {
                do {
                    try self.communicationManager.publishChannel(ChannelEvent.with(object: observation, channelId: self.getChannelId(container: container)))
                } catch {
                    LogManager.log.error("Failed to publish channeled observation: \(error)")
                }
            } else {
                do {
                    try self.communicationManager.publishAdvertise(AdvertiseEvent.with(object: observation))
                } catch {
                    LogManager.log.error("Failed to publish advertised observation: \(error)")
                }
            }
            self.onObservationDidPublish(container: container, observation: observation)
        }
    }
}

/// Defines whether and how observations are published.
public enum ObservationPublicationType: String { case none, advertise, channel }

/// Static definition of a sensor.
public struct SensorDefinition {
    let parameters: Any?
    let sensor: Sensor
    let io: ISensorStatic<SensorIo>
    let samplingInterval: Int?
    let observationPublicationType: ObservationPublicationType
    public init(parameters: Any? = nil, sensor: Sensor, io: ISensorStatic<SensorIo>, samplingInterval: Int? = nil, observationPublicationType: ObservationPublicationType) { self.parameters = parameters; self.sensor = sensor; self.io = io; self.samplingInterval = samplingInterval; self.observationPublicationType = observationPublicationType }
}

/// A registered Sensor and its IO interface.
public struct SensorContainer {
    let sensor: Sensor
    let io: SensorIo
}
