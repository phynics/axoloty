// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@_spi(AxolotyRuntimeAdapter) import Axoloty
import AxolotyObjectModel
import AxolotyProtocol
import AxolotyWire

/// A validated application Channel identifier for SensorThings values.
public struct SensorThingsChannel<Schema: SensorThingsTopLevelSchema>: Sendable, Hashable {
    /// The identifier encoded into the standard Channel topic filter.
    public let identifier: String

    /// Creates a Channel identifier.
    ///
    /// - Parameter identifier: One bounded MQTT topic level.
    /// - Throws: ``AxolotyError`` when the identifier is empty, too large, or
    ///   contains topic separators/wildcards.
    public init(_ identifier: String) throws {
        guard !identifier.isEmpty,
              identifier.utf8.count <= 128,
              !identifier.utf8.contains(0),
              !identifier.contains("/"),
              !identifier.contains("+"),
              !identifier.contains("#") else {
            throw AxolotyError.invalidArgument(
                argument: "identifier",
                reason: "invalid SensorThings channel"
            )
        }
        self.identifier = identifier
    }
}

/// Fixed bounds for one optional SensorThings runtime module.
public struct SensorThingsLimits: Sendable, Equatable {
    /// Maximum number of buffered Channel values.
    public let eventBufferCapacity: Int
    /// Maximum number of source objects retained by one module.
    public let maximumTrackedSensors: Int

    /// Creates bounded SensorThings limits.
    ///
    /// - Throws: ``AxolotyError`` when either limit is outside `1...64`.
    public init(eventBufferCapacity: Int = 16, maximumTrackedSensors: Int = 16) throws {
        guard (1...64).contains(eventBufferCapacity),
              (1...64).contains(maximumTrackedSensors) else {
            throw AxolotyError.invalidArgument(
                argument: "limits",
                reason: "SensorThings limits must be in 1...64"
            )
        }
        self.eventBufferCapacity = eventBufferCapacity
        self.maximumTrackedSensors = maximumTrackedSensors
    }

    /// The default bounded limits.
    public static var `default`: Self { Self(uncheckedEventBufferCapacity: 16, maximumTrackedSensors: 16) }

    private init(uncheckedEventBufferCapacity eventBufferCapacity: Int, maximumTrackedSensors: Int) {
        self.eventBufferCapacity = eventBufferCapacity
        self.maximumTrackedSensors = maximumTrackedSensors
    }

    fileprivate func validate() throws {
        guard (1...64).contains(eventBufferCapacity),
              (1...64).contains(maximumTrackedSensors) else {
            throw AxolotyError.invalidArgument(argument: "limits", reason: "SensorThings limits must be in 1...64")
        }
    }
}

/// A copyable snapshot suitable for an asynchronous SensorThings stream.
public struct SensorThingsObjectSnapshot<Schema: SensorThingsTopLevelSchema>: Sendable {
    /// The common Coaty object envelope.
    public let envelope: ObjectEnvelope<128, 128>
    /// The decoded SensorThings schema value.
    public let value: Schema
    private let bytes: [UInt8]

    /// Copies a bounded object before crossing an isolation boundary.
    public init(object: consuming Object<Schema>) throws(ObjectError) {
        var envelope: ObjectEnvelope<128, 128>?
        try object.withEnvelope { (value: ObjectEnvelope<128, 128>) in envelope = value }
        let value = object.value
        let bytes = object.withEncodedBytes(copyBytes)
        guard let envelope else { throw ObjectError(.invalidEnvelope) }
        self.envelope = envelope
        self.value = value
        self.bytes = bytes
    }

    /// Borrows the copied object bytes for synchronous decoding or wrapping.
    public borrowing func withEncodedBytes<R>(
        _ body: (borrowing ByteSlice) throws -> R
    ) rethrows -> R {
        try bytes.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return try body(.empty) }
            return try body(ByteSlice(bytes: baseAddress, length: buffer.count))
        }
    }
}

/// A SensorThings publication handle bound to one Sensor.
public struct SensorThingsPublisher: Sendable {
    private let sensorID: ObjectID
    private let channelID: String
    private let submit: @Sendable (RuntimeOneWayOperation) async -> RuntimeReceipt

    init(
        sensorID: ObjectID,
        channelID: String,
        submit: @escaping @Sendable (RuntimeOneWayOperation) async -> RuntimeReceipt
    ) {
        self.sensorID = sensorID
        self.channelID = channelID
        self.submit = submit
    }

    /// Publishes an Observation to this source's configured Channel.
    public func publish(_ observation: consuming Object<Observation>) async throws {
        var parent: ObjectID?
        try observation.withEnvelope { (value: ObjectEnvelope<128, 128>) in parent = value.parentObjectID }
        guard parent == sensorID else {
            throw AxolotyError.invalidArgument(
                argument: "observation",
                reason: "parentObjectId must match the configured Sensor"
            )
        }
        try await channel(
            observation,
            on: try SensorThingsChannel<Observation>(channelID)
        )
    }

    /// Publishes a SensorThings object through standard Advertise.
    public func advertise<Schema: SensorThingsTopLevelSchema>(
        _ object: consuming Object<Schema>
    ) async throws {
        let bytes = object.withEncodedBytes(copyBytes)
        try await checked(.advertise(try encodeAdvertise(object: bytes)))
    }

    /// Publishes a SensorThings object through standard Channel.
    public func channel<Schema: SensorThingsTopLevelSchema>(
        _ object: consuming Object<Schema>,
        on channel: SensorThingsChannel<Schema>
    ) async throws {
        let bytes = object.withEncodedBytes(copyBytes)
        try await checked(.channel(
            identifier: channel.identifier,
            payload: try encodeChannel(object: bytes)
        ))
    }

    /// Deadvertises one previously advertised SensorThings object.
    public func deadvertise(_ id: ObjectID) async throws {
        try await checked(.deadvertise(try encodeDeadvertise(objectID: id)))
    }

    private func checked(_ operation: RuntimeOneWayOperation) async throws {
        switch await submit(operation) {
        case .accepted:
            return
        case .ignored:
            throw AxolotyError.runtime(code: .notStarted, reason: "SensorThings operation was ignored")
        case let .rejected(reason):
            throw AxolotyError.runtime(code: .capacityExceeded, reason: "SensorThings operation rejected: \(reason)")
        }
    }
}

/// One copied observation delivered by an observer module.
public struct SensorThingsObservationDelivery: Sendable {
    /// The typed observation snapshot.
    public let observation: SensorThingsObjectSnapshot<Observation>
    /// The runtime context attached to the Channel event.
    public let context: RuntimeEventContext
}

/// Immutable source objects and Channel configuration captured before runtime
/// finishing. The configuration contains only copyable snapshots.
public struct SensorThingsSourceConfiguration: Sendable {
    let sensor: SensorThingsObjectSnapshot<Sensor>
    let thing: SensorThingsObjectSnapshot<Thing>
    let observationChannel: String
    let limits: SensorThingsLimits

    /// Creates a source configuration from typed SensorThings objects.
    public init(
        sensor: consuming Object<Sensor>,
        thing: consuming Object<Thing>,
        observationChannel: SensorThingsChannel<Observation>,
        limits: SensorThingsLimits = .default
    ) throws {
        self.sensor = try SensorThingsObjectSnapshot(object: sensor)
        self.thing = try SensorThingsObjectSnapshot(object: thing)
        self.observationChannel = observationChannel.identifier
        self.limits = limits
        try limits.validate()
    }
}

/// Configuration for a bounded observer module.
public struct SensorThingsObserverConfiguration: Sendable, Equatable {
    /// Sensor identity to accept from Channel events.
    public let sensorID: ObjectID
    /// Optional Thing identity to require as the Sensor parent.
    public let thingID: ObjectID?
    /// Channel identifier to consume.
    public let observationChannel: String
    /// Timeout applied to bounded Query requests issued at startup.
    public let requestTimeoutMS: UInt32
    /// Event buffering and registry limits.
    public let limits: SensorThingsLimits

    /// Creates observer configuration.
    public init(
        sensorID: ObjectID,
        thingID: ObjectID? = nil,
        observationChannel: SensorThingsChannel<Observation>,
        requestTimeoutMS: UInt32 = 5_000,
        limits: SensorThingsLimits = .default
    ) throws {
        guard requestTimeoutMS > 0 else {
            throw AxolotyError.invalidArgument(argument: "requestTimeoutMS", reason: "timeout must be positive")
        }
        try limits.validate()
        self.sensorID = sensorID
        self.thingID = thingID
        self.observationChannel = observationChannel.identifier
        self.requestTimeoutMS = requestTimeoutMS
        self.limits = limits
    }
}

public extension RuntimeBuilder {
    /// Installs one bounded SensorThings source module before finishing.
    ///
    /// The source advertises the Thing and Sensor during `start`, invokes the
    /// supplied async producer from `run`, and deadvertises both objects from
    /// `stop`. Reconnect calls `start` again, so advertisement is idempotent.
    mutating func sensorThingsSource(
        configuration: consuming SensorThingsSourceConfiguration,
        run: @escaping @Sendable (SensorThingsPublisher) async throws -> Void
    ) throws {
        try withRuntimeModule(key: "axoloty.sensor-things.source") { draft in
        let sensor = configuration.sensor
        let thing = configuration.thing
        let sensorBytes = sensor.withEncodedBytes(copyBytes)
        let thingBytes = thing.withEncodedBytes(copyBytes)
        let sensorID = sensor.envelope.objectID
        let thingID = thing.envelope.objectID
        let channelID = configuration.observationChannel
        let sensorAdvertise = try encodeAdvertise(object: sensorBytes)
        let thingAdvertise = try encodeAdvertise(object: thingBytes)
        let sensorResolve = try encodeResolve(object: sensorBytes)
        let thingResolve = try encodeResolve(object: thingBytes)
        let sensorRetrieve = try encodeRetrieve(objects: [sensorBytes])
        let thingRetrieve = try encodeRetrieve(objects: [thingBytes])
        let retrieveObjects = sensorID.uuid.isLexicographicallyBefore(thingID.uuid)
            ? [sensorBytes, thingBytes]
            : [thingBytes, sensorBytes]
        let retrieve = try encodeRetrieve(objects: retrieveObjects)
        let sensorDeadvertise = try encodeDeadvertise(objectID: sensorID)
        let thingDeadvertise = try encodeDeadvertise(objectID: thingID)

        // A single bounded responder handles both Sensor and Thing Discover
        // requests; unsupported selectors receive no response. Query applies
        // the supported object/core-type selectors and Coaty object filter,
        // then returns matching objects in stable object-ID order.
        try draft.respond(to: .discover) { invocation in
            let payload = invocationPayload(invocation)
            if discoverMatches(payload, objectID: thingID, objectType: "coaty.sensorThings.Thing") {
                return .response(thingResolve)
            }
            if discoverMatches(payload, objectID: sensorID, objectType: "coaty.sensorThings.Sensor") {
                return .response(sensorResolve)
            }
            return .noResponse
        }
        try draft.respond(to: .query) { invocation in
            let payload = invocationPayload(invocation)
            if queryHasUnsupportedJoin(payload) { return .noResponse }
            let sensorMatches = queryMatches(payload, objectType: "coaty.sensorThings.Sensor", object: sensorBytes)
            let thingMatches = queryMatches(payload, objectType: "coaty.sensorThings.Thing", object: thingBytes)
            guard sensorMatches || thingMatches else { return .noResponse }
            if sensorMatches && thingMatches { return .response(retrieve) }
            return .response(sensorMatches ? sensorRetrieve : thingRetrieve)
        }

        return (RuntimeModuleRegistration(
            start: { runtime in
                _ = await runtime.publish(.advertise(thingAdvertise))
                _ = await runtime.publish(.advertise(sensorAdvertise))
            },
            run: { runtime in
                let publisher = SensorThingsPublisher(
                    sensorID: sensorID,
                    channelID: channelID,
                    submit: { operation in await runtime.publish(operation) }
                )
                do { try await run(publisher) } catch { return }
            },
            stop: { runtime in
                _ = await runtime.publish(.deadvertise(sensorDeadvertise))
                _ = await runtime.publish(.deadvertise(thingDeadvertise))
            }
        ), ())
        }
    }

    /// Installs one bounded observer for Channel observations.
    mutating func sensorThingsObserver(
        configuration: SensorThingsObserverConfiguration,
        receive: @escaping @Sendable (SensorThingsObservationDelivery) async -> Void
    ) throws {
        try withRuntimeModule(key: "axoloty.sensor-things.observer") { draft in
        let stream = try draft.events(
            matching: .channel(identifier: configuration.observationChannel),
            buffering: .fail(capacity: configuration.limits.eventBufferCapacity)
        )
        let sensorAdvertisements = try draft.events(
            matching: .advertise(objectType: "coaty.sensorThings.Sensor"),
            buffering: .coalesceLatest
        )
        let thingAdvertisements = try draft.events(
            matching: .advertise(objectType: "coaty.sensorThings.Thing"),
            buffering: .coalesceLatest
        )
        let sensorID = configuration.sensorID
        let thingID = configuration.thingID
        let sensorResolveID = try draft.reserveRuntimeModuleCorrelationID()
        let sensorQueryID = try draft.reserveRuntimeModuleCorrelationID()
        let thingResolveID = thingID == nil ? nil : try draft.reserveRuntimeModuleCorrelationID()
        let thingQueryID = thingID == nil ? nil : try draft.reserveRuntimeModuleCorrelationID()
        let sensorDiscover = try encodeDiscover(objectID: sensorID, objectType: "coaty.sensorThings.Sensor")
        let sensorQuery = try encodeQuery(objectType: "coaty.sensorThings.Sensor")
        let thingDiscover = try thingID.map { try encodeDiscover(objectID: $0, objectType: "coaty.sensorThings.Thing") }
        let thingQuery = thingID == nil ? nil : try encodeQuery(objectType: "coaty.sensorThings.Thing")
        let sensorResolveStream = try draft.events(
            matching: .correlatedResponse(capability: .resolve, correlationID: sensorResolveID),
            buffering: .coalesceLatest
        )
        let sensorRetrieveStream = try draft.events(
            matching: .correlatedResponse(capability: .retrieve, correlationID: sensorQueryID),
            buffering: .coalesceLatest
        )
        let thingResolveStream: RuntimeEventStream? = try thingResolveID.map {
            try draft.events(matching: .correlatedResponse(capability: .resolve, correlationID: $0), buffering: .coalesceLatest)
        }
        let thingRetrieveStream: RuntimeEventStream? = try thingQueryID.map {
            try draft.events(matching: .correlatedResponse(capability: .retrieve, correlationID: $0), buffering: .coalesceLatest)
        }
        return (RuntimeModuleRegistration(
            start: { runtime in
                _ = await runtime.request(.discover(correlationID: sensorResolveID, payload: sensorDiscover, timeoutMS: configuration.requestTimeoutMS))
                _ = await runtime.request(.query(correlationID: sensorQueryID, payload: sensorQuery, timeoutMS: configuration.requestTimeoutMS))
                if let id = thingID, let correlation = thingResolveID, let payload = thingDiscover {
                    _ = id
                    _ = await runtime.request(.discover(correlationID: correlation, payload: payload, timeoutMS: configuration.requestTimeoutMS))
                }
                if let correlation = thingQueryID, let payload = thingQuery {
                    _ = await runtime.request(.query(correlationID: correlation, payload: payload, timeoutMS: configuration.requestTimeoutMS))
                }
            },
            run: { runtime in
                await withTaskGroup(of: Void.self) { group in
                    group.addTask {
                        for await event in stream {
                            guard !Task.isCancelled else { return }
                            guard let snapshot = decodeSnapshot(Observation.self, from: event.value) else {
                                await runtime.diagnose(RuntimeDiagnostic(kind: .malformedPayload, detail: "SensorThings Observation Channel payload was invalid"))
                                continue
                            }
                            guard snapshot.envelope.parentObjectID == sensorID else { continue }
                            await receive(SensorThingsObservationDelivery(observation: snapshot, context: event.context))
                        }
                    }
                    group.addTask { for await _ in sensorAdvertisements { if Task.isCancelled { return } } }
                    group.addTask { for await _ in thingAdvertisements { if Task.isCancelled { return } } }
                    group.addTask { for await event in sensorResolveStream { if Task.isCancelled { return }; _ = decodeSnapshot(Sensor.self, from: event.value) } }
                    group.addTask { for await event in sensorRetrieveStream { if Task.isCancelled { return }; _ = event } }
                    if let thingResolveStream {
                        group.addTask { for await event in thingResolveStream { if Task.isCancelled { return }; _ = decodeSnapshot(Thing.self, from: event.value) } }
                    }
                    if let thingRetrieveStream {
                        group.addTask { for await _ in thingRetrieveStream { if Task.isCancelled { return } } }
                    }
                    await group.next()
                    group.cancelAll()
                }
                _ = runtime
            },
            stop: { runtime in
                _ = await runtime.cancelRequest(sensorResolveID)
                _ = await runtime.cancelRequest(sensorQueryID)
                if let correlation = thingResolveID { _ = await runtime.cancelRequest(correlation) }
                if let correlation = thingQueryID { _ = await runtime.cancelRequest(correlation) }
            }
        ), ())
        }
    }
}

private func discoverMatches(_ payload: [UInt8], objectID: ObjectID, objectType: StaticString) -> Bool {
    var match = false
    payload.withUnsafeBufferPointer { buffer in
        guard let base = buffer.baseAddress else { return }
        let reader = WireReader(bytes: base, length: buffer.count)
        guard let discover = try? DiscoverWireData(from: reader) else { return }
        if let requestedID = discover.objectId {
            guard ObjectID(bytes: requestedID)?.uuid == objectID.uuid else { return }
        }
        if let types = discover.objectTypes {
            guard rawArrayContains(types, objectType) else { return }
        }
        if let cores = discover.coreTypes {
            guard rawArrayContains(cores, "CoatyObject") else { return }
        }
        match = true
    }
    return match
}

private func queryHasUnsupportedJoin(_ payload: [UInt8]) -> Bool {
    payload.withUnsafeBufferPointer { buffer in
        guard let base = buffer.baseAddress else { return false }
        let reader = WireReader(bytes: base, length: buffer.count)
        guard let query = try? QueryWireData(from: reader) else { return true }
        return query.objectJoinConditions != nil
    }
}

private func queryMatches(_ payload: [UInt8], objectType: StaticString, object: [UInt8]) -> Bool {
    var match = false
    payload.withUnsafeBufferPointer { buffer in
        guard let base = buffer.baseAddress else { return }
        let reader = WireReader(bytes: base, length: buffer.count)
        guard let query = try? QueryWireData(from: reader) else { return }
        if let types = query.objectTypes, !rawArrayContains(types, objectType) { return }
        if let cores = query.coreTypes, !rawArrayContains(cores, "CoatyObject") { return }
        guard let predicate = try? CoatyFilterAdapter<16, 16, 16, 2048>(query: query) else { return }
        var dynamic: BoundedDynamicObject<2048, 24>?
        object.withUnsafeBufferPointer { bytes in
            guard let base = bytes.baseAddress else { return }
            dynamic = try? BoundedDynamicObject<2048, 24>(decoding: base, length: bytes.count)
        }
        guard let dynamic else { return }
        match = predicate.matches(object: dynamic)
    }
    return match
}

private func rawArrayContains(_ bytes: ByteSlice, _ literal: StaticString) -> Bool {
    let literalLength = literal.utf8CodeUnitCount
    guard bytes.length >= literalLength + 2 else { return false }
    for start in 0...(bytes.length - literalLength - 2) {
        guard bytes.byte(at: start) == 34,
              bytes.byte(at: start + literalLength + 1) == 34 else { continue }
        var matches = true
        for index in 0..<literalLength {
            if bytes.byte(at: start + index + 1) != literal.utf8Start[index] { matches = false; break }
        }
        if matches { return true }
    }
    return false
}

private extension UUID16 {
    func isLexicographicallyBefore(_ other: UUID16) -> Bool {
        withUnsafeBytes(of: bytes) { left in
            withUnsafeBytes(of: other.bytes) { right in
                for index in 0..<16 {
                    if left[index] != right[index] { return left[index] < right[index] }
                }
                return false
            }
        }
    }
}

private func invocationPayload(_ invocation: RuntimeInvocation) -> [UInt8] {
    switch invocation.action {
    case let .deliver(delivery): return delivery.payload
    case let .associationChanged(transition): return transition.delivery.payload
    case .publish, .externalRouteActivated, .externalRouteDeactivated: return []
    }
}

private func copyBytes(_ bytes: borrowing ByteSlice) -> [UInt8] {
    var result: [UInt8] = []
    result.reserveCapacity(bytes.length)
    for index in 0..<bytes.length { result.append(bytes.byte(at: index) ?? 0) }
    return result
}

private func decodeSnapshot<Schema: SensorThingsTopLevelSchema>(
    _ type: Schema.Type,
    from payload: [UInt8]
) -> SensorThingsObjectSnapshot<Schema>? {
    guard !payload.isEmpty else { return nil }
    var result: SensorThingsObjectSnapshot<Schema>?
    payload.withUnsafeBufferPointer { buffer in
        guard let baseAddress = buffer.baseAddress else { return }
        let reader = WireReader(bytes: baseAddress, length: buffer.count)
        guard let objectBytes = reader.readField("object") else { return }
        do {
            let decoded = try Object<Schema>(decoding: objectBytes)
            result = try SensorThingsObjectSnapshot(object: decoded)
        } catch {
            result = nil
        }
    }
    return result
}


private func encodeDiscover(objectID: ObjectID, objectType: StaticString) throws -> [UInt8] {
    let objectId = uuidBytes(objectID.uuid)
    let objectTypes = Array("[\"\(String(decoding: UnsafeBufferPointer(start: objectType.utf8Start, count: objectType.utf8CodeUnitCount), as: UTF8.self))\"]".utf8)
    return try encodeWireEvent(.discover(OwnedDiscoverWireData(
        externalId: nil, objectId: objectId, objectTypes: objectTypes, coreTypes: nil
    )))
}

private func encodeQuery(objectType: StaticString) throws -> [UInt8] {
    let objectTypes = Array("[\"\(String(decoding: UnsafeBufferPointer(start: objectType.utf8Start, count: objectType.utf8CodeUnitCount), as: UTF8.self))\"]".utf8)
    return try encodeWireEvent(.query(OwnedQueryWireData(
        objectTypes: objectTypes, coreTypes: nil, objectFilter: nil, objectJoinConditions: nil
    )))
}

private func encodeResolve(object: [UInt8]) throws -> [UInt8] {
    try encodeWireEvent(.resolve(try OwnedResolveWireData(object: object, relatedObjects: nil, privateData: nil)))
}

private func encodeRetrieve(objects: [[UInt8]]) throws -> [UInt8] {
    var array = [UInt8](); array.append(91)
    for (index, object) in objects.enumerated() {
        if index > 0 { array.append(44) }
        array.append(contentsOf: object)
    }
    array.append(93)
    return try encodeWireEvent(.retrieve(try OwnedRetrieveWireData(objects: array, privateData: nil)))
}

private func encodeAdvertise(object: [UInt8]) throws -> [UInt8] {
    let fields = try OwnedAdvertiseWireData(object: object, privateData: nil)
    return try encodeWireEvent(.advertise(fields))
}

private func encodeChannel(object: [UInt8]) throws -> [UInt8] {
    let fields = try OwnedChannelWireData(object: object, objects: nil, privateData: nil)
    return try encodeWireEvent(.channel(fields))
}

private func encodeDeadvertise(objectID: ObjectID) throws -> [UInt8] {
    let id = uuidBytes(objectID.uuid)
    let ids = Array("[\"\(String(decoding: id, as: UTF8.self))\"]".utf8)
    let fields = try OwnedDeadvertiseWireData(objectIds: ids)
    return try encodeWireEvent(.deadvertise(fields))
}

private func encodeWireEvent(_ event: OwnedWireEvent) throws -> [UInt8] {
    var output = [UInt8](repeating: 0, count: WireBufferConfig.maxPayloadSize)
    var length = 0
    try output.withUnsafeMutableBufferPointer { buffer in
        guard let baseAddress = buffer.baseAddress else { throw AxolotyError.runtime(code: .capacityExceeded, reason: "empty SensorThings payload buffer") }
        var writer = WireWriter(buffer: baseAddress, capacity: buffer.count)
        try event.encode(to: &writer)
        length = writer.position
    }
    output.removeSubrange(length..<output.count)
    return output
}

private func uuidBytes(_ uuid: UUID16) -> [UInt8] {
    let raw = withUnsafeBytes(of: uuid.bytes) { Array($0) }
    let hex = Array("0123456789abcdef".utf8)
    var result: [UInt8] = []
    result.reserveCapacity(36)
    for index in 0..<16 {
        if index == 4 || index == 6 || index == 8 || index == 10 { result.append(45) }
        result.append(hex[Int(raw[index] >> 4)])
        result.append(hex[Int(raw[index] & 15)])
    }
    return result
}
