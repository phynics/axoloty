// Copyright (c) 2020 Siemens AG. Licensed under the MIT License.

import ErrorKit
import Foundation

/// Manages registered Sensors and publishes SensorThings observations.
open class SensorSourceController: Controller {
    private var sensors: [String: SensorContainer] = [:]
    private var samplingTasks: [String: Task<Void, Never>] = [:]
    private var discoverTask: Task<Void, Never>?
    private var queryTask: Task<Void, Never>?

    override open func onInit() {
        super.onInit()
        if let definitions = options?.sensorDefinitionsOption {
            for definition in definitions {
                do {
                    try registerSensor(sensor: definition.sensor, io: definition.io.init(parameters: definition.parameters), observationPublicationType: definition.observationPublicationType, samplingInterval: definition.samplingInterval)
                } catch {
                    LogManager.logger(.sensorThings).error("Failed to register sensor", metadata: [
                        "ioSourceId": .string(definition.sensor.objectId.string),
                        "error": .string(ErrorKit.errorChainDescription(for: AxolotyError.caught(error))),
                    ])
                }
            }
        }
    }

    override open func onCommunicationManagerStopping() {
        super.onCommunicationManagerStopping()
        samplingTasks.values.forEach { $0.cancel() }
        samplingTasks.removeAll()
        releaseResponders()
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
        guard observationPublicationType == .none || (samplingInterval ?? 0) > 0 else {
            throw AxolotyError.invalidArgument(argument: "samplingInterval", reason: "a positive sampling interval is expected")
        }
        sensors[sensor.objectId.string] = SensorContainer(sensor: sensor, io: io)
        if observationPublicationType != .none, let interval = samplingInterval {
            samplingTasks[sensor.objectId.string] = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(for: .milliseconds(interval))
                    } catch {
                        return
                    }
                    guard !Task.isCancelled else { return }
                    do {
                        try await self?._publishObservation(sensorId: sensor.objectId, channeled: observationPublicationType == .channel)
                    } catch {
                        guard let self else { return }
                        self.logPublicationFailure(error, sensorId: sensor.objectId, channeled: observationPublicationType == .channel)
                    }
                }
            }
        }
        if options?.skipsSensorAdvertise != true {
            do {
                try communicationManager.publishAdvertise(AdvertiseEvent.with(object: sensor))
            } catch {
                LogManager.logger(.sensorThings).error("Failed to advertise sensor", metadata: [
                    "ioSourceId": .string(sensor.objectId.string),
                    "error": .string(ErrorKit.errorChainDescription(for: AxolotyError.caught(error))),
                ])
            }
        }
        observeDiscoverForSensors()
        observeQueryForSensors()
    }

    /// Unregisters a sensor.
    func unregisterSensor(sensorId: CoatyUUID) throws {
        guard sensors.removeValue(forKey: sensorId.string) != nil else {
            throw AxolotyError.runtime(code: .notRegistered, reason: "sensorId \(sensorId.string) is not registered")
        }
        samplingTasks.removeValue(forKey: sensorId.string)?.cancel()
        // Once the final registration is removed there is no sensor left to
        // serve throughout the rest of the controller's lifetime, so cancel
        // and release the shared Discover/Query responder tasks. They would
        // otherwise keep running (and retain their stream subscriptions)
        // until the controller stops.
        if sensors.isEmpty {
            releaseResponders()
        }
        if options?.skipsSensorDeadvertise != true { communicationManager.publishDeadvertise(DeadvertiseEvent.with(objectIds: [sensorId])) }
    }

    /// Whether the shared Discover/Query responder tasks are active.
    ///
    /// Responders are started lazily by the first sensor registration and are
    /// released again when the last registration is removed (see
    /// ``unregisterSensor(sensorId:)``).
    var hasActiveResponders: Bool {
        discoverTask != nil || queryTask != nil
    }

    /// Cancels and releases the shared Discover/Query responder tasks.
    private func releaseResponders() {
        discoverTask?.cancel()
        discoverTask = nil
        queryTask?.cancel()
        queryTask = nil
    }

    /// Publishes a channeled observation.
    func publishChanneledObservation(sensorId: CoatyUUID, resultQuality: [String]? = nil, validTime: CoatyTimeInterval? = nil, parameters: [String: String]? = nil, featureOfInterestId: CoatyUUID? = nil) {
        Task { @MainActor [weak self] in
            do {
                try await self?._publishObservation(sensorId: sensorId, channeled: true, resultQuality: resultQuality, validTime: validTime, parameters: parameters, featureOfInterestId: featureOfInterestId)
            } catch {
                self?.logPublicationFailure(error, sensorId: sensorId, channeled: true)
            }
        }
    }

    /// Publishes an advertised observation.
    func publishAdvertisedObservation(sensorId: CoatyUUID, resultQuality: [String]? = nil, validTime: CoatyTimeInterval? = nil, parameters: [String: String]? = nil, featureOfInterestId: CoatyUUID? = nil) {
        Task { @MainActor [weak self] in
            do {
                try await self?._publishObservation(sensorId: sensorId, channeled: false, resultQuality: resultQuality, validTime: validTime, parameters: parameters, featureOfInterestId: featureOfInterestId)
            } catch {
                self?.logPublicationFailure(error, sensorId: sensorId, channeled: false)
            }
        }
    }

    internal func publishChanneledObservationAndWait(sensorId: CoatyUUID, resultQuality: [String]? = nil, validTime: CoatyTimeInterval? = nil, parameters: [String: String]? = nil, featureOfInterestId: CoatyUUID? = nil) async throws {
        try await _publishObservation(sensorId: sensorId, channeled: true, resultQuality: resultQuality, validTime: validTime, parameters: parameters, featureOfInterestId: featureOfInterestId)
    }

    internal func publishAdvertisedObservationAndWait(sensorId: CoatyUUID, resultQuality: [String]? = nil, validTime: CoatyTimeInterval? = nil, parameters: [String: String]? = nil, featureOfInterestId: CoatyUUID? = nil) async throws {
        try await _publishObservation(sensorId: sensorId, channeled: false, resultQuality: resultQuality, validTime: validTime, parameters: parameters, featureOfInterestId: featureOfInterestId)
    }

    internal func createObservation(container: SensorContainer, value: Any, resultQuality: [String]? = nil, validTime: CoatyTimeInterval? = nil, parameters: [String: String]? = nil, featureOfInterestId: CoatyUUID? = nil) -> Observation {
        makeObservation(container: container, serializedResult: RawJSONValue.serialize(any: value), resultQuality: resultQuality, validTime: validTime, parameters: parameters, featureOfInterestId: featureOfInterestId)
    }

    private func makeObservation(container: SensorContainer, serializedResult: String, resultQuality: [String]? = nil, validTime: CoatyTimeInterval? = nil, parameters: [String: String]? = nil, featureOfInterestId: CoatyUUID? = nil) -> Observation {
        let now = Date().timeIntervalSince1970 * 1000
        return Observation(phenomenonTime: now, result: serializedResult, resultTime: now, resultQuality: resultQuality, validTime: validTime, parameters: parameters, featureOfInterest: featureOfInterestId, name: "Observation of \(container.sensor.name)", objectId: .init(), externalId: nil, parentObjectId: container.sensor.objectId)
    }

    internal func getChannelId(container: SensorContainer) -> String { container.sensor.objectId.string }
    internal func onObservationWillPublish(container: SensorContainer, observation: Observation) {}
    internal func onObservationDidPublish(container: SensorContainer, observation: Observation) {}

    /// Consumes the typed Discover stream and resolves matching sensors.
    ///
    /// Mirrors ``CommunicationManager.respondToDiscover(matching:resolve:)``,
    /// which is the shared discover-responder used by
    /// ``CommunicationManager.observeDiscoverIdentity`` and
    /// ``CM+Observe.observeDiscoverIoNodes``. This controller needs direct stream
    /// access because its ``sensors`` state is not visible to the communication
    /// manager.
    private func observeDiscoverForSensors() {
        guard discoverTask == nil else { return }
        discoverTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let stream = await communicationManager.observeDiscoverStream()
            for await event in stream {
                self.handleDiscoverSnapshot(event)
            }
        }
    }

    @MainActor
    private func handleDiscoverSnapshot(_ event: DiscoverEventSnapshot) {
        guard let correlationId = event.correlationId else { return }

        if event.externalId == nil && event.objectId != nil {
            guard let id = event.objectId,
                  let uuid = CoatyUUID(uuidString: id),
                  let sensor = sensors[uuid.string] else { return }
            communicationManager.publishResolve(
                event: ResolveEvent.with(object: sensor.sensor),
                correlationId: correlationId
            )
        } else if event.externalId == nil && event.objectId == nil
                    && event.objectTypes?.contains(SensorThingsTypes.OBJECT_TYPE_SENSOR) == true {
            for sensor in sensors.values {
                communicationManager.publishResolve(
                    event: ResolveEvent.with(object: sensor.sensor),
                    correlationId: correlationId
                )
            }
        }
    }

    /// Consumes parsed transport messages for Query events and publishes
    /// Retrieve responses for matching sensors.
    ///
    /// Query observation still uses the raw ``observeParsedMessages()`` stream
    /// because a typed ``observeQueryStream()`` does not yet exist (tracked by
    /// issue #55).
    private func observeQueryForSensors() {
        guard queryTask == nil else { return }
        queryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let stream = await communicationManager.observeQueryStream()
            for await request in stream {
                guard let correlationId = request.correlationId else { continue }
                self.handleQueryEvent(request, correlationId: correlationId)
            }
        }
    }

    @MainActor
    private func handleQueryEvent(_ request: QueryEventSnapshot, correlationId: String) {
        guard Self.querySelectsSensor(request) else { return }

        let filter = request.objectFilter.flatMap {
            try? JSONDecoder().decode(ObjectFilter.self, from: Data($0.utf8))
        }
        let result = sensors.values.map(\.sensor).filter {
            filter == nil || ObjectMatcher.matchesFilter(obj: $0, filter: filter!)
        }
        if !result.isEmpty {
            communicationManager.publishRetrieve(
                event: RetrieveEvent.with(objects: result),
                correlationId: correlationId
            )
        }
    }

    internal static func querySelectsSensor(_ request: QueryEventSnapshot) -> Bool {
        guard request.objectTypes == nil || request.coreTypes == nil else { return false }

        if let objectTypes = request.objectTypes {
            return objectTypes.contains(SensorThingsTypes.OBJECT_TYPE_SENSOR)
        }
        return request.coreTypes?.contains(.CoatyObject) == true
    }

    private func _publishObservation(sensorId: CoatyUUID, channeled: Bool, resultQuality: [String]? = nil, validTime: CoatyTimeInterval? = nil, parameters: [String: String]? = nil, featureOfInterestId: CoatyUUID? = nil) async throws {
        guard let container = sensors[sensorId.string] else {
            throw AxolotyError.runtime(code: .notRegistered, reason: "sensorId \(sensorId.string) is not registered")
        }
        let serializedValue = await readSensorValue(from: container.io)
        let observation = makeObservation(container: container, serializedResult: serializedValue, resultQuality: resultQuality, validTime: validTime, parameters: parameters, featureOfInterestId: featureOfInterestId)
        onObservationWillPublish(container: container, observation: observation)
        do {
            if channeled {
                try await communicationManager.publishChannelAndWait(ChannelEvent.with(object: observation, channelId: getChannelId(container: container)))
            } else {
                try await communicationManager.publishAdvertiseAndWait(AdvertiseEvent.with(object: observation))
            }
        } catch let error as AxolotyError {
            throw error
        } catch {
            throw AxolotyError.caught(error)
        }
        onObservationDidPublish(container: container, observation: observation)
    }

    private func readSensorValue(from io: SensorIo) async -> String {
        await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            let bridge = SensorReadBridge(continuation)
            io.read { value in
                bridge.resume(RawJSONValue.serialize(any: value))
            }
        }
    }

    private func logPublicationFailure(_ error: Error, sensorId: CoatyUUID, channeled: Bool) {
        let kind = channeled ? "channeled" : "advertised"
        let wrappedError = error as? AxolotyError ?? AxolotyError.caught(error)
        LogManager.logger(.sensorThings).error("Failed to publish observation", metadata: [
            "kind": .string(kind),
            "ioSourceId": .string(sensorId.string),
            "error": .string(ErrorKit.errorChainDescription(for: wrappedError)),
        ])
    }
}

private final class SensorReadBridge: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String, Never>?
    private var didResume = false

    init(_ continuation: CheckedContinuation<String, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: String) {
        let continuation = lock.withLock { () -> CheckedContinuation<String, Never>? in
            guard !didResume else { return nil }
            didResume = true
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(returning: value)
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
