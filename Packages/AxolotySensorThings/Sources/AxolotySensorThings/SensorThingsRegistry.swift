// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import AxolotyObjectModel
import AxolotySensorThingsModel
import AxolotyProtocol
import AxolotyWire

/// The bounded predicate representation accepted by the Thing-driven Sensor
/// registry. The predicate is encoded into the query during configuration and
/// is never borrowed by the runtime module.
public typealias SensorThingsObjectPredicate = ObjectPredicate<64, 16, 16, 2048>

/// The kind of change reported by a Thing-driven Sensor catalogue.
public enum SensorThingsCatalogueChangeKind: Sendable, Equatable {
    /// A Sensor was added to the catalogue.
    case added
    /// A Sensor or its Thing snapshot changed.
    case changed
    /// A Sensor was removed from the catalogue.
    case removed
}

/// One bounded Sensor/Thing pair in a Thing-driven catalogue.
public struct SensorThingsCatalogueEntry: Sendable {
    /// The registered Sensor snapshot.
    public let sensor: SensorThingsObjectSnapshot<Sensor>
    /// The registered parent Thing snapshot.
    public let thing: SensorThingsObjectSnapshot<Thing>

    init(sensor: SensorThingsObjectSnapshot<Sensor>, thing: SensorThingsObjectSnapshot<Thing>) {
        self.sensor = sensor
        self.thing = thing
    }
}

/// A deterministic change to a Thing-driven Sensor catalogue.
public struct SensorThingsCatalogueChange: Sendable {
    /// The operation that changed the catalogue.
    public let kind: SensorThingsCatalogueChangeKind
    /// The Sensor involved in the change, when one remains available.
    public let sensor: SensorThingsObjectSnapshot<Sensor>?
    /// The Thing involved in the change, when one remains available.
    public let thing: SensorThingsObjectSnapshot<Thing>?
    /// The complete sorted catalogue after this change.
    public let total: [SensorThingsCatalogueEntry]

    init(
        kind: SensorThingsCatalogueChangeKind,
        sensor: SensorThingsObjectSnapshot<Sensor>?,
        thing: SensorThingsObjectSnapshot<Thing>?,
        total: [SensorThingsCatalogueEntry]
    ) {
        self.kind = kind
        self.sensor = sensor
        self.thing = thing
        self.total = total
    }
}

/// A Thing-driven observation delivery containing all related context.
public struct ThingSensorObservationDelivery: Sendable {
    /// The observation object received on the Sensor-ID Channel.
    public let observation: SensorThingsObjectSnapshot<Observation>
    /// The registered Sensor that owns the observation.
    public let sensor: SensorThingsObjectSnapshot<Sensor>
    /// The registered parent Thing.
    public let thing: SensorThingsObjectSnapshot<Thing>
    /// The normalized runtime event context.
    public let context: RuntimeEventContext

    init(
        observation: SensorThingsObjectSnapshot<Observation>,
        sensor: SensorThingsObjectSnapshot<Sensor>,
        thing: SensorThingsObjectSnapshot<Thing>,
        context: RuntimeEventContext
    ) {
        self.observation = observation
        self.sensor = sensor
        self.thing = thing
        self.context = context
    }
}

/// The two owned streams produced by a Thing-driven Sensor registry.
public struct ThingSensorObservationStreams: Sendable {
    /// Bounded added, changed, and removed catalogue notifications.
    public let catalogueChanges: AsyncStream<SensorThingsCatalogueChange>
    /// Observation deliveries accepted after relationship validation.
    public let observations: AsyncStream<ThingSensorObservationDelivery>

    /// Alias for ``catalogueChanges`` used by callers that treat the stream
    /// as the current Sensor catalogue.
    public var catalogue: AsyncStream<SensorThingsCatalogueChange> { catalogueChanges }
    /// Alias for ``observations`` used by callers that treat the value as the
    /// registry's observation stream.
    public var observation: AsyncStream<ThingSensorObservationDelivery> { observations }

    init(
        catalogueChanges: AsyncStream<SensorThingsCatalogueChange>,
        observations: AsyncStream<ThingSensorObservationDelivery>
    ) {
        self.catalogueChanges = catalogueChanges
        self.observations = observations
    }
}

struct SensorThingsRegistryRegistration: Sendable {
    fileprivate let coordinator: SensorThingsRegistryCoordinator
    let thingID: ObjectID
    let discoverCorrelationID: UUID16
    let queryCorrelationID: UUID16

    let observationStream: RuntimeEventStream
    let advertiseStream: RuntimeEventStream
    let deadvertiseStream: RuntimeEventStream
    let resolveStream: RuntimeEventStream
    let retrieveStream: RuntimeEventStream
    let catalogueContinuation: AsyncStream<SensorThingsCatalogueChange>.Continuation
    let observationContinuation: AsyncStream<ThingSensorObservationDelivery>.Continuation

    init(
        thingID: ObjectID,
        filterBytes: [UInt8]?,
        catalogueContinuation: AsyncStream<SensorThingsCatalogueChange>.Continuation,
        observationContinuation: AsyncStream<ThingSensorObservationDelivery>.Continuation,
        observationStream: RuntimeEventStream,
        advertiseStream: RuntimeEventStream,
        deadvertiseStream: RuntimeEventStream,
        resolveStream: RuntimeEventStream,
        retrieveStream: RuntimeEventStream,
        maximumSensors: Int
    ) {
        self.thingID = thingID
        self.discoverCorrelationID = registryCorrelationID(thingID: thingID, discriminator: 1)
        self.queryCorrelationID = registryCorrelationID(thingID: thingID, discriminator: 2)
        self.observationStream = observationStream
        self.advertiseStream = advertiseStream
        self.deadvertiseStream = deadvertiseStream
        self.resolveStream = resolveStream
        self.retrieveStream = retrieveStream
        self.catalogueContinuation = catalogueContinuation
        self.observationContinuation = observationContinuation
        self.coordinator = SensorThingsRegistryCoordinator(
            thingID: thingID,
            filterBytes: filterBytes,
            maximumSensors: maximumSensors,
            catalogueContinuation: catalogueContinuation,
            observationContinuation: observationContinuation
        )
    }

    func start(runtime: RuntimeModuleContext) async {
        let discover = makeDiscoverRequest(
            correlationID: discoverCorrelationID,
            objectID: thingID,
            objectType: "coaty.sensorThings.Thing"
        )
        let query = makeSensorQuery(
            correlationID: queryCorrelationID,
            thingID: thingID,
            filterBytes: await coordinator.filterBytes()
        )
        let discoverReceipt = await runtime.request(discover)
        await reportRegistryReceipt(discoverReceipt, runtime: runtime, detail: "Thing-driven Sensor registry discovery")
        let queryReceipt = await runtime.request(query)
        await reportRegistryReceipt(queryReceipt, runtime: runtime, detail: "Thing-driven Sensor registry query")
    }

    func run(runtime: RuntimeModuleContext) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for await event in self.advertiseStream {
                    await self.coordinator.advertise(event, diagnose: runtime.diagnose)
                }
            }
            group.addTask {
                for await event in self.deadvertiseStream {
                    await self.coordinator.deadvertise(event, diagnose: runtime.diagnose)
                }
            }
            group.addTask {
                for await event in self.resolveStream where event.context.correlationID == self.discoverCorrelationID {
                    await self.coordinator.resolve(event, diagnose: runtime.diagnose)
                }
            }
            group.addTask {
                for await event in self.retrieveStream where event.context.correlationID == self.queryCorrelationID {
                    await self.coordinator.retrieve(event, diagnose: runtime.diagnose)
                }
            }
            group.addTask {
                for await event in self.observationStream {
                    await self.coordinator.observation(event, diagnose: runtime.diagnose)
                }
            }
            await group.waitForAll()
        }
    }

    func stop(runtime: RuntimeModuleContext) async {
        _ = await runtime.cancelRequest(discoverCorrelationID)
        _ = await runtime.cancelRequest(queryCorrelationID)
        await coordinator.finish()
        observationStream.finish()
        advertiseStream.finish()
        deadvertiseStream.finish()
        resolveStream.finish()
        retrieveStream.finish()
    }

    func finishStreams() {
        catalogueContinuation.finish()
        observationContinuation.finish()
    }
}

private actor SensorThingsRegistryCoordinator {
    private let thingID: ObjectID
    private let filter: [UInt8]?
    /// The catalogue decides what changes; this actor decodes and publishes.
    private var catalogue: SensorThingsCatalogue
    private let catalogueContinuation: AsyncStream<SensorThingsCatalogueChange>.Continuation
    private let observationContinuation: AsyncStream<ThingSensorObservationDelivery>.Continuation

    init(
        thingID: ObjectID,
        filterBytes: [UInt8]?,
        maximumSensors: Int,
        catalogueContinuation: AsyncStream<SensorThingsCatalogueChange>.Continuation,
        observationContinuation: AsyncStream<ThingSensorObservationDelivery>.Continuation
    ) {
        self.thingID = thingID
        self.filter = filterBytes
        self.catalogue = SensorThingsCatalogue(thingID: thingID, maximumSensors: maximumSensors)
        self.catalogueContinuation = catalogueContinuation
        self.observationContinuation = observationContinuation
    }

    func filterBytes() -> [UInt8]? { filter }

    func advertise(
        _ event: RuntimeEventValue,
        diagnose: @escaping @Sendable (RuntimeDiagnostic) async -> Void
    ) async {
        guard let objectBytes = wrappedObject(event.value, field: "object") else {
            await diagnose(registryMalformed("Advertise payload"))
            return
        }
        await apply(objectBytes: objectBytes, diagnose: diagnose)
    }

    func resolve(
        _ event: RuntimeEventValue,
        diagnose: @escaping @Sendable (RuntimeDiagnostic) async -> Void
    ) async {
        guard let fields = decodeResponse(event.value) else {
            await diagnose(registryMalformed("Resolve payload"))
            return
        }
        await apply(objectBytes: fields.object, diagnose: diagnose)
        for related in fields.related {
            await apply(objectBytes: related, diagnose: diagnose)
        }
    }

    func retrieve(
        _ event: RuntimeEventValue,
        diagnose: @escaping @Sendable (RuntimeDiagnostic) async -> Void
    ) async {
        guard let objects = decodeRetrieve(event.value) else {
            await diagnose(registryMalformed("Retrieve payload"))
            return
        }
        for object in objects {
            await apply(objectBytes: object, diagnose: diagnose)
        }
    }

    func deadvertise(
        _ event: RuntimeEventValue,
        diagnose: @escaping @Sendable (RuntimeDiagnostic) async -> Void
    ) async {
        guard let ids = decodeDeadvertise(event.value) else {
            await diagnose(registryMalformed("Deadvertise payload"))
            return
        }
        for id in ids {
            await publish(catalogue.remove(id), diagnose: diagnose)
        }
    }

    func observation(
        _ event: RuntimeEventValue,
        diagnose: @escaping @Sendable (RuntimeDiagnostic) async -> Void
    ) async {
        guard let channel = event.context.channelIdentifier,
              let sensorUUID = UUID16(parsing: channel),
              let pair = catalogue.deliverableSensor(ObjectID(uuid: sensorUUID)),
              let objectBytes = wrappedObject(event.value, field: "object") else { return }
        guard let observation = decodeSnapshot(Observation.self, bytes: objectBytes) else {
            await diagnose(registryMalformed("Observation Channel payload"))
            return
        }
        guard observation.envelope.parentObjectID == pair.0.envelope.objectID else { return }
        observationContinuation.yield(ThingSensorObservationDelivery(
            observation: observation,
            sensor: pair.0,
            thing: pair.1,
            context: event.context
        ))
    }

    func finish() {
        catalogueContinuation.finish()
        observationContinuation.finish()
    }

    private func apply(
        objectBytes: [UInt8],
        diagnose: @escaping @Sendable (RuntimeDiagnostic) async -> Void
    ) async {
        guard let type = objectType(bytes: objectBytes) else {
            await diagnose(registryMalformed("SensorThings metadata"))
            return
        }
        let outcome: SensorThingsCatalogue.Outcome
        switch type {
        case "coaty.sensorThings.Thing":
            guard let decoded = decodeSnapshot(Thing.self, bytes: objectBytes) else { return }
            outcome = catalogue.apply(thing: decoded)
        case "coaty.sensorThings.Sensor":
            guard let decoded = decodeSnapshot(Sensor.self, bytes: objectBytes),
                  matchesFilter(sensorBytes: objectBytes) else { return }
            outcome = catalogue.apply(sensor: decoded)
        default:
            return
        }
        await publish(outcome, diagnose: diagnose)
    }

    /// Turns a catalogue outcome into diagnostics and published changes.
    private func publish(
        _ outcome: SensorThingsCatalogue.Outcome,
        diagnose: @escaping @Sendable (RuntimeDiagnostic) async -> Void
    ) async {
        if outcome.isCapacityExceeded {
            await diagnose(RuntimeDiagnostic(
                kind: .capacityExceeded,
                detail: "Thing-driven Sensor registry reached its sensor limit"
            ))
            return
        }
        for transition in outcome.transitions {
            await emit(transition, diagnose: diagnose)
        }
    }

    private func emit(
        _ transition: SensorThingsCatalogue.Transition,
        diagnose: @escaping @Sendable (RuntimeDiagnostic) async -> Void
    ) async {
        let result = catalogueContinuation.yield(SensorThingsCatalogueChange(
            kind: transition.kind,
            sensor: transition.sensor,
            thing: transition.thing,
            total: transition.total
        ))
        if case .dropped = result {
            await diagnose(RuntimeDiagnostic(
                kind: .capacityExceeded,
                detail: "Thing-driven Sensor catalogue stream is full"
            ))
        }
    }

    private func matchesFilter(sensorBytes: [UInt8]) -> Bool {
        guard let filter else { return true }
        var result = false
        filter.withUnsafeBufferPointer { filterBuffer in
            guard let filterBase = filterBuffer.baseAddress else { return }
            sensorBytes.withUnsafeBufferPointer { sensorBuffer in
                guard let sensorBase = sensorBuffer.baseAddress,
                      let object = try? BoundedDynamicObject<2048, 24>(
                        decoding: sensorBase,
                        length: sensorBuffer.count
                      ) else { return }
                do {
                    let adapter = try CoatyFilterAdapter<64, 16, 16, 2048>(
                        decoding: ByteSlice(bytes: filterBase, length: filterBuffer.count)
                    )
                    result = adapter.matches(object: object)
                } catch {
                    return
                }
            }
        }
        return result
    }

}

func sensorThingsBufferingPolicy(
    _ policy: RuntimeBufferingPolicy,
    capacity: Int
) -> AsyncStream<ThingSensorObservationDelivery>.Continuation.BufferingPolicy {
    switch policy {
    case let .failAfterDrop(value), let .dropNewest(value): return .bufferingOldest(min(value, capacity))
    case let .fail(value), let .dropOldest(value): return .bufferingNewest(min(value, capacity))
    case .coalesceLatest: return .bufferingNewest(1)
    }
}

private func registryMalformed(_ subject: String) -> RuntimeDiagnostic {
    RuntimeDiagnostic(kind: .malformedPayload, detail: "Thing-driven Sensor registry ignored malformed \(subject)")
}

private func reportRegistryReceipt(
    _ receipt: RuntimeReceipt,
    runtime: RuntimeModuleContext,
    detail: String
) async {
    guard case let .rejected(reason) = receipt else { return }
    await runtime.diagnose(RuntimeDiagnostic(kind: .handlerFailed, detail: detail + " rejected: " + String(describing: reason)))
}

private func makeDiscoverRequest(correlationID: UUID16, objectID: ObjectID, objectType: StaticString) -> RuntimeRequest {
    .discover(
        correlationID: correlationID,
        payload: encodeDiscover(objectID: objectID, objectType: objectType),
        timeoutMS: 5_000
    )
}

private func makeSensorQuery(correlationID: UUID16, thingID: ObjectID, filterBytes: [UInt8]?) -> RuntimeRequest {
    .query(
        correlationID: correlationID,
        payload: encodeQuery(objectType: "coaty.sensorThings.Sensor", thingID: thingID, filterBytes: filterBytes),
        timeoutMS: 5_000
    )
}

private func encodeDiscover(objectID: ObjectID, objectType: StaticString) -> [UInt8] {
    guard let fields = try? OwnedDiscoverWireData(
        externalId: nil,
        objectId: uuidBytes(objectID.uuid),
        objectTypes: jsonArray(objectType),
        coreTypes: nil
    ) else { return [] }
    return encodeRegistryEvent(.discover(fields))
}

private func encodeQuery(objectType: StaticString, thingID: ObjectID, filterBytes: [UInt8]?) -> [UInt8] {
    let objectFilter = parentFilter(thingID: thingID, extra: filterBytes)
    guard let fields = try? OwnedQueryWireData(
        objectTypes: jsonArray(objectType),
        coreTypes: nil,
        objectFilter: objectFilter,
        objectJoinConditions: nil
    ) else { return [] }
    return encodeRegistryEvent(.query(fields))
}

private func parentFilter(thingID: ObjectID, extra: [UInt8]?) -> [UInt8] {
    let parent = Array("[\"parentObjectId\",[7,\"\(objectIDString(thingID: thingID))\"]]".utf8)
    guard let extra,
          let condition = extra.withUnsafeBufferPointer({ buffer -> [UInt8]? in
              guard let base = buffer.baseAddress else { return nil }
              return WireReader(bytes: base, length: buffer.count).readField("conditions").map(copyBytes)
          }) else {
        return Array("{\"conditions\":\(String(decoding: parent, as: UTF8.self))}".utf8)
    }
    return Array("{\"conditions\":{\"and\":[\(String(decoding: parent, as: UTF8.self)),\(String(decoding: condition, as: UTF8.self))]}}".utf8)
}

private func encodeRegistryEvent(_ event: OwnedWireEvent) -> [UInt8] {
    var output = [UInt8](repeating: 0, count: WireBufferConfig.maxPayloadSize)
    var length = 0
    output.withUnsafeMutableBufferPointer { buffer in
        guard let baseAddress = buffer.baseAddress else { return }
        var writer = WireWriter(buffer: baseAddress, capacity: buffer.count)
        try? event.encode(to: &writer)
        length = writer.position
    }
    output.removeSubrange(length..<output.count)
    return output
}

private func jsonArray(_ value: StaticString) -> [UInt8] {
    Array("[\"\(String(decoding: UnsafeBufferPointer(start: value.utf8Start, count: value.utf8CodeUnitCount), as: UTF8.self))\"]".utf8)
}

private func wrappedObject(_ payload: [UInt8], field: StaticString) -> [UInt8]? {
    payload.withUnsafeBufferPointer { buffer in
        guard let base = buffer.baseAddress else { return nil }
        return WireReader(bytes: base, length: buffer.count).readField(field).map(copyBytes)
    }
}

private func objectType(bytes: [UInt8]) -> String? {
    bytes.withUnsafeBufferPointer { buffer in
        guard let base = buffer.baseAddress else { return nil }
        return WireReader(bytes: base, length: buffer.count).readString("objectType").map(copyString)
    }
}

private func decodeSnapshot<Schema: SensorThingsTopLevelSchema>(
    _ type: Schema.Type,
    bytes: [UInt8]
) -> SensorThingsObjectSnapshot<Schema>? {
    bytes.withUnsafeBufferPointer { buffer in
        guard let base = buffer.baseAddress,
              let object = try? Object<Schema>(decoding: ByteSlice(bytes: base, length: buffer.count))
        else { return nil }
        return try? SensorThingsObjectSnapshot(object: object)
    }
}

private func decodeResponse(_ payload: [UInt8]) -> (object: [UInt8], related: [[UInt8]])? {
    payload.withUnsafeBufferPointer { buffer in
        guard let base = buffer.baseAddress,
              let response = try? ResolveWireData(from: WireReader(bytes: base, length: buffer.count))
        else { return nil }
        var related: [[UInt8]] = []
        if let values = response.relatedObjects {
            try? values.withArrayElements { related.append(copyBytes($0)) }
        }
        return (copyBytes(response.object), related)
    }
}

private func decodeRetrieve(_ payload: [UInt8]) -> [[UInt8]]? {
    payload.withUnsafeBufferPointer { buffer in
        guard let base = buffer.baseAddress,
              let response = try? RetrieveWireData(from: WireReader(bytes: base, length: buffer.count))
        else { return nil }
        var objects: [[UInt8]] = []
        try? response.objects.withArrayElements { objects.append(copyBytes($0)) }
        return objects
    }
}

private func decodeDeadvertise(_ payload: [UInt8]) -> [ObjectID]? {
    payload.withUnsafeBufferPointer { buffer in
        guard let base = buffer.baseAddress,
              let response = try? DeadvertiseWireData(from: WireReader(bytes: base, length: buffer.count))
        else { return nil }
        var result: [ObjectID] = []
        try? response.objectIds.withArrayElements { value in
            guard value.length > 0 else { return }
            let encoded = value.byte(at: 0) == 34 && value.byte(at: value.length - 1) == 34
                ? value.subSlice(from: 1, length: value.length - 2)
                : value
            guard let uuid = UUID16(parsing: encoded) else { return }
            result.append(ObjectID(uuid: uuid))
        }
        return result
    }
}

private func registryCorrelationID(thingID: ObjectID, discriminator: UInt8) -> UUID16 {
    let b = thingID.uuid.bytes
    return UUID16(bytes: (
        b.0, b.1, b.2, b.3, b.4, b.5, b.6, b.7,
        b.8, b.9, b.10, b.11, b.12, b.13, b.14, b.15 ^ discriminator
    ))
}

private func objectIDString(thingID: ObjectID) -> String {
    String(decoding: uuidBytes(thingID.uuid), as: UTF8.self)
}

private func copyBytes(_ bytes: ByteSlice) -> [UInt8] {
    bytes.withBytes { pointer, length in
        Array(UnsafeBufferPointer(start: pointer.assumingMemoryBound(to: UInt8.self), count: length))
    }
}

private func copyString(_ bytes: ByteSlice) -> String {
    String(decoding: copyBytes(bytes), as: UTF8.self)
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

