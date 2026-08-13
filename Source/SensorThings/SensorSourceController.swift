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
        discoverTask?.cancel()
        discoverTask = nil
        queryTask?.cancel()
        queryTask = nil
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
        if options?.skipsSensorDeadvertise != true { communicationManager.publishDeadvertise(DeadvertiseEvent.with(objectIds: [sensorId])) }
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

    internal func publishChanneledObservationAndWait(sensorId: CoatyUUID, resultQuality: [String]? = nil, validTime: CoatyTimeInterval? = nil, parameters: [String: String]? = nil, featureOfInterestId: CoatyUUID? = nil, readTimeout: Duration = .seconds(5)) async throws {
        try await _publishObservation(sensorId: sensorId, channeled: true, resultQuality: resultQuality, validTime: validTime, parameters: parameters, featureOfInterestId: featureOfInterestId, readTimeout: readTimeout)
    }

    internal func publishAdvertisedObservationAndWait(sensorId: CoatyUUID, resultQuality: [String]? = nil, validTime: CoatyTimeInterval? = nil, parameters: [String: String]? = nil, featureOfInterestId: CoatyUUID? = nil, readTimeout: Duration = .seconds(5)) async throws {
        try await _publishObservation(sensorId: sensorId, channeled: false, resultQuality: resultQuality, validTime: validTime, parameters: parameters, featureOfInterestId: featureOfInterestId, readTimeout: readTimeout)
    }

    internal func createObservation(container: SensorContainer, value: Any, resultQuality: [String]? = nil, validTime: CoatyTimeInterval? = nil, parameters: [String: String]? = nil, featureOfInterestId: CoatyUUID? = nil) -> Observation {
        createObservation(container: container, value: RawJSONValue(any: value) ?? .null, resultQuality: resultQuality, validTime: validTime, parameters: parameters, featureOfInterestId: featureOfInterestId)
    }

    private func createObservation(container: SensorContainer, value: RawJSONValue, resultQuality: [String]? = nil, validTime: CoatyTimeInterval? = nil, parameters: [String: String]? = nil, featureOfInterestId: CoatyUUID? = nil) -> Observation {
        let now = Date().timeIntervalSince1970 * 1000
        let result = (try? JSONEncoder().encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "null"
        return Observation(phenomenonTime: now, result: result, resultTime: now, resultQuality: resultQuality, validTime: validTime, parameters: parameters, featureOfInterest: featureOfInterestId, name: "Observation of \(container.sensor.name)", objectId: .init(), externalId: nil, parentObjectId: container.sensor.objectId)
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

    private func _publishObservation(sensorId: CoatyUUID, channeled: Bool, resultQuality: [String]? = nil, validTime: CoatyTimeInterval? = nil, parameters: [String: String]? = nil, featureOfInterestId: CoatyUUID? = nil, readTimeout: Duration = .seconds(5)) async throws {
        guard let container = sensors[sensorId.string] else {
            throw AxolotyError.runtime(code: .notRegistered, reason: "sensorId \(sensorId.string) is not registered")
        }
        let value = try await readSensorValue(from: container.io, sensorId: sensorId, timeout: readTimeout)
        let observation = createObservation(container: container, value: value, resultQuality: resultQuality, validTime: validTime, parameters: parameters, featureOfInterestId: featureOfInterestId)
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

    private func readSensorValue(from io: SensorIo, sensorId: CoatyUUID, timeout: Duration) async throws -> RawJSONValue {
        let bridge = SensorReadContinuation()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<RawJSONValue, Error>) in
                guard bridge.install(continuation) else { return }
                bridge.startDeadline(timeout, sensorId: sensorId)
                io.read { value in bridge.resume(value) }
            }
        }, onCancel: {
            bridge.cancel(sensorId: sensorId)
        })
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

/// Serializes sensor callback, deadline, and task-cancellation completion.
///
/// The callback's untyped value is converted to ``RawJSONValue`` before it is
/// stored, so no arbitrary `Any` crosses the asynchronous boundary.
private final class SensorReadContinuation: @unchecked Sendable {
    private let lock = NSLock()
    private var didComplete = false
    private var pendingCompletion: SensorReadCompletion?
    private var continuation: CheckedContinuation<RawJSONValue, Error>?
    private var deadlineTask: Task<Void, Never>?

    @discardableResult
    func install(_ continuation: CheckedContinuation<RawJSONValue, Error>) -> Bool {
        let result = lock.withLock { () -> (shouldInstall: Bool, pending: SensorReadCompletion?) in
            if didComplete {
                let pending = pendingCompletion
                pendingCompletion = nil
                return (false, pending)
            }
            self.continuation = continuation
            return (true, nil)
        }
        if let pending = result.pending {
            resume(continuation, with: pending)
        }
        return result.shouldInstall
    }

    func resume(_ value: Any) {
        finish(.success(RawJSONValue(any: value) ?? .null))
    }

    func startDeadline(_ timeout: Duration, sensorId: CoatyUUID) {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        let task = Task { [weak self] in
            do {
                try await clock.sleep(until: deadline)
            } catch {
                return
            }
            self?.finish(.failure(.runtime(code: .timedOut, reason: "Timed out waiting for sensor \(sensorId.string) read to complete")))
        }
        let keepTask = lock.withLock { () -> Bool in
            guard !didComplete else { return false }
            deadlineTask = task
            return true
        }
        if !keepTask { task.cancel() }
    }

    func cancel(sensorId: CoatyUUID) {
        finish(.failure(.runtime(code: .cancelled, reason: "Sensor read was cancelled for \(sensorId.string)")))
    }

    private func finish(_ completion: SensorReadCompletion) {
        let (continuation, deadlineTask) = lock.withLock { () -> (CheckedContinuation<RawJSONValue, Error>?, Task<Void, Never>?) in
            guard !didComplete else { return (nil, nil) }
            didComplete = true
            let continuation = self.continuation
            self.continuation = nil
            if continuation == nil {
                pendingCompletion = completion
            }
            let deadlineTask = self.deadlineTask
            self.deadlineTask = nil
            return (continuation, deadlineTask)
        }
        deadlineTask?.cancel()
        guard let continuation else { return }
        resume(continuation, with: completion)
    }

    private func resume(
        _ continuation: CheckedContinuation<RawJSONValue, Error>,
        with completion: SensorReadCompletion
    ) {
        switch completion {
        case let .success(value):
            continuation.resume(returning: value)
        case let .failure(error):
            continuation.resume(throwing: error)
        }
    }
}

private enum SensorReadCompletion {
    case success(RawJSONValue)
    case failure(AxolotyError)
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
