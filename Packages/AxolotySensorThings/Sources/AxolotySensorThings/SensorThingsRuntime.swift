// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@_spi(AxolotyRuntimeAdapter) import Axoloty
import AxolotyObjectModel
import AxolotyProtocol
import AxolotyWire
import ErrorKit

/// A validated application Channel identifier for SensorThings values.
public struct SensorThingsChannel<Schema: SensorThingsTopLevelSchema>: Sendable, Hashable {
    /// The identifier encoded into the Channel route's filter segment.
    public let identifier: String

    /// Creates a Channel identifier.
    ///
    /// - Parameter identifier: One bounded route segment. It becomes the
    ///   filter on a Coaty Channel route, so it may not contain a segment
    ///   separator or any character the validated transport reserves for
    ///   wildcards.
    /// - Throws: ``AxolotyError`` when the identifier is empty, too large, or
    ///   contains a segment separator or reserved character.
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
    /// Maximum number of configured Sensor sources.
    public let maximumSensors: Int
    /// Maximum number of configured direct observation streams.
    public let maximumObservationStreams: Int

    /// Creates bounded SensorThings limits.
    ///
    /// - Parameters:
    ///   - maximumSensors: The maximum number of source Sensors.
    ///   - maximumObservationStreams: The maximum number of direct streams.
    /// - Throws: ``AxolotyError`` when either limit is outside `1...64`.
    public init(maximumSensors: Int = 16, maximumObservationStreams: Int = 16) throws {
        guard (1...64).contains(maximumSensors),
              (1...64).contains(maximumObservationStreams) else {
            throw AxolotyError.invalidArgument(
                argument: "limits",
                reason: "SensorThings limits must be in 1...64"
            )
        }
        self.maximumSensors = maximumSensors
        self.maximumObservationStreams = maximumObservationStreams
    }

    /// The default bounded limits.
    public static var `default`: Self { Self(uncheckedMaximumSensors: 16, maximumObservationStreams: 16) }

    private init(uncheckedMaximumSensors maximumSensors: Int, maximumObservationStreams: Int) {
        self.maximumSensors = maximumSensors
        self.maximumObservationStreams = maximumObservationStreams
    }

    fileprivate func validate() throws {
        guard (1...64).contains(maximumSensors),
              (1...64).contains(maximumObservationStreams) else {
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

    var encodedBytes: [UInt8] { bytes }

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
            throw runtimeError(for: reason)
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

/// An owned direct-observation stream for one fixed Sensor.
public struct SensorObservationStream: AsyncSequence, Sendable {
    /// The delivered observation and runtime context.
    public typealias Element = SensorThingsObservationDelivery
    private let sensorID: ObjectID
    private let stream: RuntimeEventStream
    private let diagnosticSink: SensorThingsDiagnosticSink

    fileprivate init(sensorID: ObjectID, stream: RuntimeEventStream, diagnosticSink: SensorThingsDiagnosticSink) {
        self.sensorID = sensorID
        self.stream = stream
        self.diagnosticSink = diagnosticSink
    }

    /// Creates an iterator over matching observation deliveries.
    ///
    /// - Returns: An iterator that completes when the runtime finishes the product stream.
    public func makeAsyncIterator() -> Iterator {
        Iterator(sensorID: sensorID, iterator: stream.makeAsyncIterator(), diagnosticSink: diagnosticSink)
    }

    /// An iterator over the stream's owned observation deliveries.
    public struct Iterator: AsyncIteratorProtocol {
        private let sensorID: ObjectID
        private var iterator: AsyncStream<RuntimeEventValue>.Iterator
        private let diagnosticSink: SensorThingsDiagnosticSink

        fileprivate init(
            sensorID: ObjectID,
            iterator: AsyncStream<RuntimeEventValue>.Iterator,
            diagnosticSink: SensorThingsDiagnosticSink
        ) {
            self.sensorID = sensorID
            self.iterator = iterator
            self.diagnosticSink = diagnosticSink
        }

        /// Returns the next matching observation, or `nil` after stream completion.
        public mutating func next() async -> Element? {
            while let event = await iterator.next() {
                let snapshot: SensorThingsObjectSnapshot<Observation>
                do { snapshot = try decodeSnapshot(Observation.self, from: event.value) }
                catch {
                    await diagnosticSink.emit(RuntimeDiagnostic(
                        kind: .malformedPayload,
                        detail: "SensorThings Observation Channel payload was invalid: \(sensorThingsErrorDetail(error))"
                    ))
                    continue
                }
                guard snapshot.envelope.parentObjectID == sensorID else { continue }
                return SensorThingsObservationDelivery(observation: snapshot, context: event.context)
            }
            return nil
        }
    }
}

private actor SensorThingsDiagnosticSink {
    private var handler: (@Sendable (RuntimeDiagnostic) async -> Void)?

    func install(_ handler: @escaping @Sendable (RuntimeDiagnostic) async -> Void) {
        self.handler = handler
    }

    func emit(_ diagnostic: RuntimeDiagnostic) async {
        await handler?(diagnostic)
    }
}

private final class SensorThingsTransactionToken: @unchecked Sendable {
    private var active = true
    func invalidate() { active = false }
    var isActive: Bool { active }
}

private struct SensorThingsSourceRegistration: Sendable {
    let sensor: SensorThingsObjectSnapshot<Sensor>
    let thing: SensorThingsObjectSnapshot<Thing>
    let channelID: String
    let run: @Sendable (SensorThingsPublisher) async throws -> Void
}

/// The atomic SensorThings registration draft passed to a builder transaction.
public struct SensorThingsConfiguration {
    fileprivate var builder: RuntimeBuilder
    fileprivate var sources: [SensorThingsSourceRegistration] = []
    fileprivate var observationStreams: [(ObjectID, RuntimeEventStream, SensorThingsDiagnosticSink)] = []
    fileprivate var registry: SensorThingsRegistryRegistration?
    fileprivate var limits: SensorThingsLimits = .default
    fileprivate let initialEventStreamCount: Int
    fileprivate let token: SensorThingsTransactionToken

    init(builder: RuntimeBuilder) {
        self.builder = builder
        self.initialEventStreamCount = builder.eventStreamCount
        self.token = SensorThingsTransactionToken()
    }

    /// Registers one bounded Sensor/Thing producer.
    ///
    /// - Parameters:
    ///   - sensor: The Sensor object to advertise and publish from.
    ///   - thing: The parent Thing object for the Sensor.
    ///   - observationChannel: The Channel used by published observations.
    ///   - run: The structured producer body.
    /// - Throws: ``AxolotyError`` when objects, parents, duplicates, or limits are invalid.
    public mutating func source(
        sensor: consuming Object<Sensor>,
        thing: consuming Object<Thing>,
        observationChannel: SensorThingsChannel<Observation>,
        run: @escaping @Sendable (SensorThingsPublisher) async throws -> Void
    ) throws {
        guard token.isActive else { throw AxolotyError.invalidArgument(argument: "configuration", reason: "SensorThings configuration transaction has ended") }
        let sensorSnapshot: SensorThingsObjectSnapshot<Sensor>
        let thingSnapshot: SensorThingsObjectSnapshot<Thing>
        do {
            sensorSnapshot = try SensorThingsObjectSnapshot(object: sensor)
            thingSnapshot = try SensorThingsObjectSnapshot(object: thing)
        } catch {
            throw AxolotyError.caught(error)
        }
        guard sensorSnapshot.envelope.parentObjectID == thingSnapshot.envelope.objectID else {
            throw AxolotyError.invalidArgument(argument: "sensor", reason: "Sensor parentObjectId must match its Thing objectID")
        }
        guard sources.count < limits.maximumSensors else {
            throw AxolotyError.runtime(code: .capacityExceeded, reason: "SensorThings sensor limit is full")
        }
        guard !sources.contains(where: { $0.sensor.envelope.objectID == sensorSnapshot.envelope.objectID }) else {
            throw AxolotyError.invalidArgument(argument: "sensor", reason: "Sensor objectID is duplicated")
        }
        if let existing = sources.first(where: { $0.thing.envelope.objectID == thingSnapshot.envelope.objectID }),
           existing.thing.encodedBytes != thingSnapshot.encodedBytes {
            throw AxolotyError.invalidArgument(argument: "thing", reason: "Thing objectID has conflicting snapshots")
        }
        sources.append(SensorThingsSourceRegistration(
            sensor: sensorSnapshot,
            thing: thingSnapshot,
            channelID: observationChannel.identifier,
            run: run
        ))
    }

    /// Registers one fixed-Sensor observation stream.
    ///
    /// - Parameters:
    ///   - sensorID: The Sensor identity whose observations are delivered.
    ///   - channel: The Channel to match.
    ///   - buffering: The bounded application buffering policy.
    /// - Returns: An owned asynchronous observation stream.
    /// - Throws: ``AxolotyError`` when the stream capacity or module limit is exceeded.
    public mutating func observations(
        for sensorID: ObjectID,
        channel: SensorThingsChannel<Observation>,
        buffering: RuntimeBufferingPolicy
    ) throws -> SensorObservationStream {
        guard token.isActive else { throw AxolotyError.invalidArgument(argument: "configuration", reason: "SensorThings configuration transaction has ended") }
        guard observationStreams.count < limits.maximumObservationStreams else {
            throw AxolotyError.runtime(code: .capacityExceeded, reason: "SensorThings observation stream limit is full")
        }
        let diagnosticSink = SensorThingsDiagnosticSink()
        let stream = try builder.events(matching: .channel(identifier: channel.identifier), buffering: buffering)
        observationStreams.append((sensorID, stream, diagnosticSink))
        return SensorObservationStream(sensorID: sensorID, stream: stream, diagnosticSink: diagnosticSink)
    }

    /// Registers a Thing-driven bounded Sensor catalogue and observation stream.
    ///
    /// - Parameters:
    ///   - thingID: The exact Thing identity to discover and track.
    ///   - sensorFilter: An optional Coaty object predicate applied to Sensors.
    ///   - buffering: The buffering policy for observation delivery.
    /// - Returns: The catalogue-change and observation streams owned by the module.
    /// - Throws: ``AxolotyError`` when the module stream capacity is exhausted.
    public mutating func observations(
        forSensorsOf thingID: ObjectID,
        matching sensorFilter: consuming SensorThingsObjectPredicate? = nil,
        buffering: RuntimeBufferingPolicy
    ) throws -> ThingSensorObservationStreams {
        guard token.isActive else {
            throw AxolotyError.invalidArgument(argument: "configuration", reason: "SensorThings configuration transaction has ended")
        }
        guard registry == nil else {
            throw AxolotyError.invalidArgument(argument: "thingID", reason: "Thing-driven Sensor registry is already configured")
        }
        guard observationStreams.count < limits.maximumObservationStreams else {
            throw AxolotyError.runtime(code: .capacityExceeded, reason: "SensorThings observation stream limit is full")
        }
        let filterBytes: [UInt8]?
        if let sensorFilter {
            var bytes = [UInt8](repeating: 0, count: WireBufferConfig.maxPayloadSize)
            var length = 0
            do {
                try bytes.withUnsafeMutableBufferPointer { buffer in
                    guard let base = buffer.baseAddress else { throw ObjectError(.capacityExceeded) }
                    var writer = WireWriter(buffer: base, capacity: buffer.count)
                    try sensorFilter.encode(to: &writer)
                    length = writer.position
                }
            } catch {
                throw AxolotyError.caught(error)
            }
            bytes.removeSubrange(length..<bytes.count)
            filterBytes = bytes
        } else {
            filterBytes = nil
        }
        let cataloguePair = AsyncStream<SensorThingsCatalogueChange>.makeStream(
            bufferingPolicy: .bufferingNewest(min(limits.maximumSensors, builder.capacities.stream))
        )
        let observationPair = AsyncStream<ThingSensorObservationDelivery>.makeStream(
            bufferingPolicy: sensorThingsBufferingPolicy(buffering, capacity: builder.capacities.stream)
        )
        let eventStreams: (
            RuntimeEventStream,
            RuntimeEventStream,
            RuntimeEventStream,
            RuntimeEventStream,
            RuntimeEventStream
        )
        do {
            eventStreams = try (
                builder.events(matching: .family(.channel), buffering: buffering),
                builder.events(matching: .family(.advertise), buffering: .dropOldest(capacity: min(builder.capacities.stream, 64))),
                builder.events(matching: .family(.deadvertise), buffering: .dropOldest(capacity: min(builder.capacities.stream, 64))),
                builder.events(matching: .family(.resolve), buffering: .dropOldest(capacity: min(builder.capacities.stream, 64))),
                builder.events(matching: .family(.retrieve), buffering: .dropOldest(capacity: min(builder.capacities.stream, 64)))
            )
        } catch {
            cataloguePair.continuation.finish()
            observationPair.continuation.finish()
            throw error
        }
        let observationStream = eventStreams.0
        let advertiseStream = eventStreams.1
        let deadvertiseStream = eventStreams.2
        let resolveStream = eventStreams.3
        let retrieveStream = eventStreams.4
        let streams = ThingSensorObservationStreams(
            catalogueChanges: cataloguePair.stream,
            observations: observationPair.stream
        )
        registry = SensorThingsRegistryRegistration(
            thingID: thingID,
            filterBytes: filterBytes,
            catalogueContinuation: cataloguePair.continuation,
            observationContinuation: observationPair.continuation,
            observationStream: observationStream,
            advertiseStream: advertiseStream,
            deadvertiseStream: deadvertiseStream,
            resolveStream: resolveStream,
            retrieveStream: retrieveStream,
            maximumSensors: limits.maximumSensors
        )
        return streams
    }
}

public extension RuntimeBuilder {
    /// Configures all SensorThings sources and direct-observation streams in one
    /// atomic runtime-module transaction.
    ///
    /// - Parameters:
    ///   - limits: The bounded source and direct-stream limits.
    ///   - configure: The closure that registers sources and streams.
    /// - Returns: The value returned by `configure`.
    /// - Throws: ``AxolotyError`` when configuration or module registration fails.
    mutating func sensorThings<Result>(
        limits: SensorThingsLimits = .default,
        _ configure: (inout SensorThingsConfiguration) throws -> Result
    ) throws -> Result {
        try limits.validate()
        return try withRuntimeModule(key: "axoloty.sensor-things") { draft in
            var configuration = SensorThingsConfiguration(builder: draft)
            configuration.limits = limits
            let result: Result
            do {
                result = try configure(&configuration)
            } catch {
                configuration.token.invalidate()
                configuration.builder.finishNewRuntimeEventStreams(after: configuration.initialEventStreamCount)
                configuration.registry?.finishStreams()
                throw error
            }
            configuration.token.invalidate()
            draft = configuration.builder
            var committed = false
            defer {
                if !committed {
                    configuration.registry?.finishStreams()
                }
            }

            let orderedSources = configuration.sources.sorted {
                $0.sensor.envelope.objectID.uuid.isLexicographicallyBefore($1.sensor.envelope.objectID.uuid)
            }
            var thingsByID: [ObjectID: [UInt8]] = [:]
            for source in orderedSources where thingsByID[source.thing.envelope.objectID] == nil {
                thingsByID[source.thing.envelope.objectID] = source.thing.encodedBytes
            }
            let orderedThings = thingsByID.sorted {
                $0.key.uuid.isLexicographicallyBefore($1.key.uuid)
            }
            let sourceBytes = orderedSources.map { $0.sensor.withEncodedBytes(copyBytes) }
            let sourceAdvertise = try sourceBytes.map { try encodeAdvertise(object: $0) }
            let thingAdvertise = try orderedThings.map { try encodeAdvertise(object: $0.value) }
            let sourceDeadvertise = try orderedSources.map { try encodeDeadvertise(objectID: $0.sensor.envelope.objectID) }
            let thingDeadvertise = try orderedThings.map { try encodeDeadvertise(objectID: $0.key) }
            let sourceResolve = try sourceBytes.map { try encodeResolve(object: $0) }
            let allObjects = (orderedSources.enumerated().map {
                ($0.element.sensor.envelope.objectID, $0.element.sensor.encodedBytes)
            } + orderedThings.map { ($0.key, $0.value) })
                .sorted { $0.0.uuid.isLexicographicallyBefore($1.0.uuid) }

            try draft.respond(to: .discover) { invocation in
                let payload = invocationPayload(invocation)
                for (index, source) in orderedSources.enumerated()
                    where discoverMatches(payload, objectID: source.sensor.envelope.objectID, objectType: "coaty.sensorThings.Sensor") {
                    return .response(sourceResolve[index])
                }
                for thing in orderedThings
                    where discoverMatches(payload, objectID: thing.key, objectType: "coaty.sensorThings.Thing") {
                    return .response(try encodeResolve(object: thing.value))
                }
                return .noResponse
            }
            try draft.respond(to: .query) { invocation in
                let payload = invocationPayload(invocation)
                guard !queryHasUnsupportedJoin(payload) else { return .noResponse }
                let matching = allObjects.filter {
                    queryMatches(payload, objectType: objectType(for: $0.0, sources: orderedSources), object: $0.1)
                }
                let bounded = Array(matching.prefix(limits.maximumSensors)).map(\.1)
                guard !bounded.isEmpty else { return .noResponse }
                return .response(try encodeRetrieve(objects: bounded))
            }

            let registrations = configuration.sources
            let observationStreams = configuration.observationStreams
            let registry = configuration.registry
            let registration = RuntimeModuleRegistration(
                start: { runtime in
                    for (_, _, sink) in observationStreams {
                        await sink.install { diagnostic in await runtime.diagnose(diagnostic) }
                    }
                    for payload in thingAdvertise {
                        await report(runtime.publish(.advertise(payload)), to: runtime, detail: "SensorThings Thing advertisement")
                    }
                    for payload in sourceAdvertise {
                        await report(runtime.publish(.advertise(payload)), to: runtime, detail: "SensorThings Sensor advertisement")
                    }
                    if let registry {
                        await registry.start(runtime: runtime)
                    }
                },
                run: { runtime in
                    await withTaskGroup(of: Void.self) { group in
                        for source in registrations {
                            group.addTask {
                                let publisher = SensorThingsPublisher(
                                    sensorID: source.sensor.envelope.objectID,
                                    channelID: source.channelID,
                                    submit: { operation in await runtime.publish(operation) }
                                )
                                do { try await source.run(publisher) }
                                catch {
                                    await runtime.diagnose(RuntimeDiagnostic(
                                        kind: .handlerFailed,
                                        detail: "SensorThings source producer failed: \(sensorThingsErrorDetail(error))"
                                    ))
                                }
                            }
                        }
                        if let registry {
                            group.addTask { await registry.run(runtime: runtime) }
                        }
                        await group.waitForAll()
                    }
                },
                stop: { runtime in
                    for payload in sourceDeadvertise {
                        await report(runtime.publish(.deadvertise(payload)), to: runtime, detail: "SensorThings Sensor deadvertisement")
                    }
                    for payload in thingDeadvertise {
                        await report(runtime.publish(.deadvertise(payload)), to: runtime, detail: "SensorThings Thing deadvertisement")
                    }
                    for (_, stream, _) in observationStreams {
                        stream.finish()
                    }
                    if let registry {
                        await registry.stop(runtime: runtime)
                    }
                }
            )
            committed = true
            return (registration, result)
        }
    }
}

private func sensorThingsErrorDetail(_ error: Error) -> String {
    let wrapped = error as? AxolotyError ?? AxolotyError.caught(error)
    return ErrorKit.errorChainDescription(for: wrapped)
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

private func objectType(
    for objectID: ObjectID,
    sources: [SensorThingsSourceRegistration]
) -> StaticString {
    if sources.contains(where: { $0.sensor.envelope.objectID == objectID }) {
        return "coaty.sensorThings.Sensor"
    }
    return "coaty.sensorThings.Thing"
}

private func report(
    _ receipt: RuntimeReceipt,
    to runtime: RuntimeModuleContext,
    detail: String
) async {
    guard case let .rejected(reason) = receipt else { return }
    await runtime.diagnose(RuntimeDiagnostic(kind: .handlerFailed, detail: detail + " rejected: " + String(describing: reason)))
}

private func runtimeError(for rejection: RuntimeRejection) -> AxolotyError {
    switch rejection {
    case let .notRunning(state):
        return .runtime(code: .notStarted, reason: "SensorThings operation was rejected because runtime is " + String(describing: state))
    case let .malformedFrame(code):
        return .runtime(code: .subscriptionFailed, reason: "SensorThings operation was rejected by malformed frame: " + String(describing: code))
    case .malformedPayload:
        return .decodingFailure(type: "SensorThings", reason: "operation payload was rejected")
    case .invalidOperationName:
        return .invalidArgument(argument: "operation", reason: "SensorThings operation name was rejected")
    case let .protocol(code):
        return .runtime(code: .subscriptionFailed, reason: "SensorThings operation was rejected by protocol: " + String(describing: code))
    case .capacityExceeded:
        return .runtime(code: .capacityExceeded, reason: "SensorThings operation exceeded runtime capacity")
    case .staleTransport:
        return .runtime(code: .cancelled, reason: "SensorThings operation was rejected by a stale transport")
    }
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
) throws -> SensorThingsObjectSnapshot<Schema> {
    guard !payload.isEmpty else {
        throw AxolotyError.decodingFailure(type: "SensorThingsObject", reason: "empty payload")
    }
    var result: Result<SensorThingsObjectSnapshot<Schema>, Error>?
    payload.withUnsafeBufferPointer { buffer in
        guard let baseAddress = buffer.baseAddress else {
            result = .failure(AxolotyError.decodingFailure(type: "SensorThingsObject", reason: "empty payload"))
            return
        }
        let reader = WireReader(bytes: baseAddress, length: buffer.count)
        guard let objectBytes = reader.readField("object") else {
            result = .failure(AxolotyError.decodingFailure(type: "SensorThingsObject", reason: "missing object field"))
            return
        }
        do {
            let decoded = try Object<Schema>(decoding: objectBytes)
            result = .success(try SensorThingsObjectSnapshot(object: decoded))
        } catch {
            result = .failure(AxolotyError.caught(error))
        }
    }
    guard let result else {
        throw AxolotyError.decodingFailure(type: "SensorThingsObject", reason: "missing payload")
    }
    return try result.get()
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
