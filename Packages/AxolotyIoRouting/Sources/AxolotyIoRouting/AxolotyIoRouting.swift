// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@_spi(AxolotyRuntimeAdapter) import Axoloty
import AxolotyObjectModel
import AxolotyProtocol
import AxolotyWire

/// Fixed limits for the optional host-side Basic IO routing policy.
public struct IoRoutingLimits: Sendable, Equatable {
    /// Maximum endpoint advertisements retained by the policy.
    public let maximumEndpoints: Int
    /// Maximum association intents retained by the policy.
    public let maximumAssociations: Int

    /// Creates bounded routing limits.
    ///
    /// - Parameters:
    ///   - maximumEndpoints: Maximum scoped endpoint advertisements to retain.
    ///   - maximumAssociations: Maximum source-to-actor intents to retain.
    public init(maximumEndpoints: Int = 64, maximumAssociations: Int = 64) {
        self.maximumEndpoints = maximumEndpoints
        self.maximumAssociations = maximumAssociations
    }
}

public extension RuntimeDefinition.Builder {
    /// Installs the bounded, host-only Basic IO routing policy.
    ///
    /// The context scopes endpoint selection by `parentObjectId`. The
    /// installed component observes ordinary Advertise and Deadvertise event
    /// streams and submits typed Associate intents through the existing
    /// runtime executor. It owns no transport or association state.
    ///
    /// - Parameters:
    ///   - context: The consumed IoContext object that scopes this policy.
    ///   - limits: Endpoint and intent bounds.
    /// - Throws: ``AxolotyError`` when the context or limits are invalid, or
    ///   the host component capacity is exhausted.
    mutating func basicIoRouting(
        context: consuming Object<IoContext>,
        limits: IoRoutingLimits = .init()
    ) throws {
        guard limits.maximumEndpoints > 0, limits.maximumEndpoints <= 64,
              limits.maximumAssociations > 0, limits.maximumAssociations <= 64 else {
            throw AxolotyError.invalidArgument(
                argument: "limits",
                reason: "routing limits must be in 1...64"
            )
        }

        var contextID: ObjectID?
        var contextName = ""
        var contextBytes: [UInt8] = []
        try context.withEnvelope { (envelope: ObjectEnvelope<128, 128>) in
            contextID = envelope.objectID
            envelope.name.withBytes { name in
                contextName = String(decoding: (0..<name.length).map { name.byte(at: $0) ?? 0 }, as: UTF8.self)
            }
        }
        context.withEncodedBytes { bytes in
            contextBytes.reserveCapacity(bytes.length)
            for index in 0..<bytes.length {
                contextBytes.append(bytes.byte(at: index) ?? 0)
            }
        }
        guard let contextID else {
            throw AxolotyError.invalidArgument(argument: "context", reason: "context object identity is invalid")
        }

        let sourceAdvertise = try events(
            matching: .advertise(objectType: "IoSource"),
            buffering: .fail(capacity: limits.maximumEndpoints)
        )
        let sourceAdvertiseRemote = try events(
            matching: .advertise(objectType: "coaty.IoSource"),
            buffering: .fail(capacity: limits.maximumEndpoints)
        )
        let actorAdvertise = try events(
            matching: .advertise(objectType: "IoActor"),
            buffering: .fail(capacity: limits.maximumEndpoints)
        )
        let actorAdvertiseRemote = try events(
            matching: .advertise(objectType: "coaty.IoActor"),
            buffering: .fail(capacity: limits.maximumEndpoints)
        )
        let deadvertise = try events(
            matching: .family(.deadvertise),
            buffering: .fail(capacity: limits.maximumEndpoints)
        )
        let engine = BasicIoRoutingEngine(
            contextID: contextID,
            contextName: contextName,
            contextBytes: contextBytes,
            limits: limits
        )
        try registerRuntimeComponent(RuntimeComponentRegistration(
            start: { runtime in
                await engine.start(runtime)
            },
            run: { runtime in
                await engine.run(
                    runtime,
                    sourceAdvertise: sourceAdvertise,
                    sourceAdvertiseRemote: sourceAdvertiseRemote,
                    actorAdvertise: actorAdvertise,
                    actorAdvertiseRemote: actorAdvertiseRemote,
                    deadvertise: deadvertise
                )
            },
            stop: { runtime in
                await engine.stop(runtime)
            }
        ))
    }
}

private enum RoutingEndpointRole: Sendable, Equatable {
    case source
    case actor
}

private struct RoutingEndpoint: Sendable, Equatable {
    let id: ObjectID
    let role: RoutingEndpointRole
    let parentID: ObjectID?
    let valueType: [UInt8]
    let representation: IoValueRepresentation
    let externalRoute: [UInt8]?
    let updateRate: UInt32?
}

private struct RoutingPair: Hashable, Sendable {
    let source: ObjectID
    let actor: ObjectID
}

private struct RoutingBucket: Equatable, Sendable {
    let valueType: [UInt8]
    let representation: IoValueRepresentation
}

private struct RoutingIntent: Equatable, Sendable {
    let pair: RoutingPair
    let bucket: RoutingBucket
    let route: [UInt8]?
    let updateRate: UInt32?
}

private actor BasicIoRoutingEngine {
    private let contextID: ObjectID
    private let contextName: String
    private let contextBytes: [UInt8]
    private let limits: IoRoutingLimits
    private var endpoints = InlineArray<64, RoutingEndpoint?>(repeating: nil)
    private var intents = InlineArray<64, RoutingIntent?>(repeating: nil)

    init(contextID: ObjectID, contextName: String, contextBytes: [UInt8], limits: IoRoutingLimits) {
        self.contextID = contextID
        self.contextName = contextName
        self.contextBytes = contextBytes
        self.limits = limits
    }

    func start(_ runtime: RuntimeComponentContext) async {
        clearIntents()
        _ = await runtime.publish(.advertise(encodeAdvertise(objectBytes: contextBytes)))
        let buckets = uniqueBuckets()
        for bucket in buckets {
            await recompute(bucket: bucket, runtime: runtime)
        }
    }

    func stop(_ runtime: RuntimeComponentContext) async {
        for intent in sortedIntents() {
            _ = await runtime.publish(.associateInContext(
                contextName: contextName,
                payload: encodeAssociate(
                    source: intent.pair.source,
                    actor: intent.pair.actor,
                    intent: RoutingIntent(
                        pair: intent.pair,
                        bucket: intent.bucket,
                        route: nil,
                        updateRate: intent.updateRate
                    )
                )
            ))
        }
        _ = await runtime.publish(.deadvertise(encodeDeadvertise(objectID: contextID)))
        clearIntents()
        clearEndpoints()
    }

    func run(
        _ runtime: RuntimeComponentContext,
        sourceAdvertise: RuntimeEventStream,
        sourceAdvertiseRemote: RuntimeEventStream,
        actorAdvertise: RuntimeEventStream,
        actorAdvertiseRemote: RuntimeEventStream,
        deadvertise: RuntimeEventStream
    ) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { [weak self] in
                for await event in sourceAdvertise {
                    guard !Task.isCancelled else { return }
                    await self?.consumeAdvertise(event, runtime: runtime)
                }
            }
            group.addTask { [weak self] in
                for await event in sourceAdvertiseRemote {
                    guard !Task.isCancelled else { return }
                    await self?.consumeAdvertise(event, runtime: runtime)
                }
            }
            group.addTask { [weak self] in
                for await event in actorAdvertise {
                    guard !Task.isCancelled else { return }
                    await self?.consumeAdvertise(event, runtime: runtime)
                }
            }
            group.addTask { [weak self] in
                for await event in actorAdvertiseRemote {
                    guard !Task.isCancelled else { return }
                    await self?.consumeAdvertise(event, runtime: runtime)
                }
            }
            group.addTask { [weak self] in
                for await event in deadvertise {
                    guard !Task.isCancelled else { return }
                    await self?.consumeDeadvertise(event, runtime: runtime)
                }
            }
            _ = await group.next()
            group.cancelAll()
        }
    }

    private func consumeAdvertise(_ event: RuntimeEventValue, runtime: RuntimeComponentContext) async {
        guard let endpoint = decodeAdvertisedEndpoint(event.value) else { return }
        guard endpoint.role == .source || endpoint.role == .actor else { return }
        guard endpoint.parentID == contextID else { return }
        if let index = endpointIndex(endpoint.id), let previous = endpoints[index] {
            guard previous != endpoint else { return }
            endpoints[index] = nil
            await recompute(
                bucket: RoutingBucket(valueType: previous.valueType, representation: previous.representation),
                runtime: runtime
            )
            endpoints[index] = endpoint
            await recompute(
                bucket: RoutingBucket(valueType: endpoint.valueType, representation: endpoint.representation),
                runtime: runtime
            )
            return
        }
        guard endpointCount() < limits.maximumEndpoints,
              let index = firstFreeEndpointIndex() else { return }
        endpoints[index] = endpoint
        await recompute(
            bucket: RoutingBucket(valueType: endpoint.valueType, representation: endpoint.representation),
            runtime: runtime
        )
    }

    private func consumeDeadvertise(_ event: RuntimeEventValue, runtime: RuntimeComponentContext) async {
        for id in decodeDeadvertisedIDs(event.value) {
            guard let index = endpointIndex(id), let removed = endpoints[index] else { continue }
            endpoints[index] = nil
            await recompute(
                bucket: RoutingBucket(valueType: removed.valueType, representation: removed.representation),
                runtime: runtime
            )
        }
    }

    private func recompute(
        bucket: RoutingBucket,
        runtime: RuntimeComponentContext
    ) async {
        let candidates = endpointValues().filter {
            $0.parentID == contextID && $0.valueType == bucket.valueType && $0.representation == bucket.representation
        }
        let sources = candidates.filter { $0.role == .source }.sorted { objectIDLess($0.id, $1.id) }
        let actors = candidates.filter { $0.role == .actor }.sorted { objectIDLess($0.id, $1.id) }
        var desired: [RoutingIntent] = []
        desired.reserveCapacity(min(limits.maximumAssociations, sources.count * actors.count))
        for source in sources {
            guard let route = source.externalRoute
                .flatMap({ validatedExternalRoute($0, namespace: runtime.namespace) })
                ?? generatedRoute(namespace: runtime.namespace, sourceID: source.id)
            else { continue }
            for actor in actors {
                guard desired.count < limits.maximumAssociations else { break }
                let pair = RoutingPair(source: source.id, actor: actor.id)
                desired.append(RoutingIntent(
                    pair: pair,
                    bucket: bucket,
                    route: route,
                    updateRate: maximumRate(source.updateRate, actor.updateRate)
                ))
            }
        }

        let old = intentValues().filter { $0.bucket == bucket }
        var affected: [RoutingPair] = []
        affected.reserveCapacity(old.count + desired.count)
        for intent in old + desired {
            guard !affected.contains(intent.pair) else { continue }
            affected.append(intent.pair)
        }
        for pair in sortedPairs(affected) {
            let oldIntent = old.first { $0.pair == pair }
            let next = desired.first { $0.pair == pair }
            guard oldIntent != next else { continue }
            let intent = next ?? RoutingIntent(
                pair: pair,
                bucket: bucket,
                route: nil,
                updateRate: oldIntent?.updateRate
            )
            let receipt = await runtime.publish(.associateInContext(
                contextName: contextName,
                payload: encodeAssociate(source: pair.source, actor: pair.actor, intent: intent)
            ))
            switch receipt {
            case .accepted, .ignored:
                break
            case .rejected:
                continue
            }
            if let next {
                setIntent(next)
            } else {
                removeIntent(pair)
            }
        }
    }

    private func endpointIndex(_ id: ObjectID) -> Int? {
        for index in 0..<64 where endpoints[index]?.id == id { return index }
        return nil
    }

    private func firstFreeEndpointIndex() -> Int? {
        for index in 0..<limits.maximumEndpoints where endpoints[index] == nil { return index }
        return nil
    }

    private func endpointCount() -> Int {
        (0..<limits.maximumEndpoints).reduce(into: 0) { count, index in
            if endpoints[index] != nil { count += 1 }
        }
    }

    private func endpointValues() -> [RoutingEndpoint] {
        (0..<limits.maximumEndpoints).compactMap { endpoints[$0] }
    }

    private func intentValues() -> [RoutingIntent] {
        (0..<limits.maximumAssociations).compactMap { intents[$0] }
    }

    private func intentIndex(_ pair: RoutingPair) -> Int? {
        for index in 0..<limits.maximumAssociations where intents[index]?.pair == pair { return index }
        return nil
    }

    private func setIntent(_ intent: RoutingIntent) {
        if let index = intentIndex(intent.pair) {
            intents[index] = intent
        } else {
            for index in 0..<limits.maximumAssociations where intents[index] == nil {
                intents[index] = intent
                return
            }
        }
    }

    private func removeIntent(_ pair: RoutingPair) {
        if let index = intentIndex(pair) { intents[index] = nil }
    }

    private func sortedIntents() -> [RoutingIntent] {
        intentValues().sorted {
            if $0.pair.source != $1.pair.source { return objectIDLess($0.pair.source, $1.pair.source) }
            return objectIDLess($0.pair.actor, $1.pair.actor)
        }
    }

    private func uniqueBuckets() -> [RoutingBucket] {
        var result: [RoutingBucket] = []
        for endpoint in endpointValues() {
            let bucket = RoutingBucket(valueType: endpoint.valueType, representation: endpoint.representation)
            if !result.contains(bucket) { result.append(bucket) }
        }
        return result
    }

    private func clearIntents() {
        for index in 0..<64 { intents[index] = nil }
    }

    private func clearEndpoints() {
        for index in 0..<64 { endpoints[index] = nil }
    }
}

private func maximumRate(_ source: UInt32?, _ actor: UInt32?) -> UInt32? {
    switch (source, actor) {
    case (nil, nil): return nil
    case let (source?, actor?): return max(source, actor)
    case let (source?, nil): return source
    case let (nil, actor?): return actor
    }
}

private func sortedPairs<S: Sequence>(_ pairs: S) -> [RoutingPair] where S.Element == RoutingPair {
    pairs.sorted {
        if $0.source != $1.source { return objectIDLess($0.source, $1.source) }
        return objectIDLess($0.actor, $1.actor)
    }
}

private func objectIDLess(_ lhs: ObjectID, _ rhs: ObjectID) -> Bool {
    withUnsafeBytes(of: lhs.uuid.bytes) { left in
        withUnsafeBytes(of: rhs.uuid.bytes) { right in
            for index in 0..<16 {
                if left[index] != right[index] { return left[index] < right[index] }
            }
            return false
        }
    }
}

private func generatedRoute(namespace: String, sourceID: ObjectID) -> [UInt8]? {
    var result = Array("coaty/3/".utf8)
    result.append(contentsOf: namespace.utf8)
    result.append(contentsOf: "/IOV/".utf8)
    result.append(contentsOf: uuidBytes(sourceID.uuid))
    return result.count <= WireBufferConfig.maxTopicLength ? result : nil
}

private func validatedExternalRoute(_ route: [UInt8], namespace: String) -> [UInt8]? {
    guard !route.isEmpty, route.count <= WireBufferConfig.maxTopicLength,
          route.first != 0x2F, route.last != 0x2F else { return nil }
    var previousWasSeparator = false
    for byte in route {
        guard byte >= 0x20, byte != 0x22, byte != 0x23, byte != 0x2B, byte != 0x5C else {
            return nil
        }
        if byte == 0x2F {
            guard !previousWasSeparator else { return nil }
            previousWasSeparator = true
        } else {
            previousWasSeparator = false
        }
    }
    let profilePrefix = Array("coaty/3/\(namespace)/".utf8)
    guard route.count < profilePrefix.count || !route.starts(with: profilePrefix) else { return nil }
    return route
}

private func uuidBytes(_ uuid: UUID16) -> [UInt8] {
    let bytes = withUnsafeBytes(of: uuid.bytes) { Array($0) }
    let hex = Array("0123456789abcdef".utf8)
    var result: [UInt8] = []
    result.reserveCapacity(36)
    for index in 0..<16 {
        if index == 4 || index == 6 || index == 8 || index == 10 { result.append(0x2D) }
        result.append(hex[Int(bytes[index] >> 4)])
        result.append(hex[Int(bytes[index] & 0x0F)])
    }
    return result
}

private func encodeAdvertise(objectBytes: [UInt8]) -> [UInt8] {
    guard let fields = try? OwnedAdvertiseWireData(object: objectBytes, privateData: nil) else {
        return []
    }
    var output = [UInt8](repeating: 0, count: WireBufferConfig.maxPayloadSize)
    var length = 0
    output.withUnsafeMutableBufferPointer { buffer in
        guard let base = buffer.baseAddress else { return }
        var writer = WireWriter(buffer: base, capacity: buffer.count)
        do throws(WireEncodeError) {
            try OwnedWireEvent.advertise(fields).encode(to: &writer)
            length = writer.position
        } catch {
            length = 0
        }
    }
    output.removeSubrange(length..<output.count)
    return output
}

private func encodeAssociate(source: ObjectID, actor: ObjectID, intent: RoutingIntent) -> [UInt8] {
    let fields = try? OwnedAssociateWireData(
        ioSourceId: source.uuid,
        ioActorId: actor.uuid,
        associatingRoute: intent.route,
        isExternalRoute: nil,
        updateRate: intent.updateRate.map(Int.init)
    )
    guard let fields else { return [] }
    var output = [UInt8](repeating: 0, count: WireBufferConfig.maxPayloadSize)
    var length = 0
    output.withUnsafeMutableBufferPointer { buffer in
        guard let base = buffer.baseAddress else { return }
        var writer = WireWriter(buffer: base, capacity: buffer.count)
        do throws(WireEncodeError) {
            try OwnedWireEvent.associate(fields).encode(to: &writer)
            length = writer.position
        } catch {
            length = 0
        }
    }
    output.removeSubrange(length..<output.count)
    return output
}

private func encodeDeadvertise(objectID: ObjectID) -> [UInt8] {
    var output = [UInt8](repeating: 0, count: 128)
    var length = 0
    output.withUnsafeMutableBufferPointer { buffer in
        guard let base = buffer.baseAddress else { return }
        var writer = WireWriter(buffer: base, capacity: buffer.count)
        let encodedID = Array(String(decoding: uuidBytes(objectID.uuid), as: UTF8.self).utf8)
        guard let deadvertise = try? OwnedDeadvertiseWireData(
            objectIds: Array("[\"\(String(decoding: encodedID, as: UTF8.self))\"]".utf8)
        ) else { return }
        do throws(WireEncodeError) {
            try OwnedWireEvent.deadvertise(deadvertise).encode(to: &writer)
            length = writer.position
        } catch {
            length = 0
        }
    }
    output.removeSubrange(length..<output.count)
    return output
}

private func decodeAdvertisedEndpoint(_ bytes: [UInt8]) -> RoutingEndpoint? {
    bytes.withUnsafeBufferPointer { buffer in
        guard let base = buffer.baseAddress else { return nil }
        let reader = WireReader(bytes: base, length: buffer.count)
        guard let advertised = try? AdvertiseWireData(from: reader) else { return nil }
        return advertised.object.withBytes { pointer, count in
            let objectBytes = ByteSlice(bytes: pointer.assumingMemoryBound(to: UInt8.self), length: count)
            guard let envelope = try? ObjectEnvelope<128, 128>(decoding: objectBytes) else { return nil }
            let role: RoutingEndpointRole
            switch envelope.coreType {
            case .ioSource: role = .source
            case .ioActor: role = .actor
            default: return nil
            }
            guard let dynamic = try? DynamicObject(decoding: objectBytes) else { return nil }
            var valueType: [UInt8]?
            var binary = false
            var externalRoute: [UInt8]?
            var updateRate: UInt32?
            dynamic.withFields { fields in
                _ = fields.withValue(for: "valueType") { value in
                    valueType = decodedString(value, into: InlineArray<128, UInt8>.self)
                }
                _ = fields.withValue(for: "useRawIoValues") { value in binary = value.rawEquals("true") }
                _ = fields.withValue(for: "externalRoute") { value in
                    externalRoute = decodedString(value, into: InlineArray<256, UInt8>.self)
                }
                _ = fields.withValue(for: "updateRate") { value in
                    _ = value.withNumber { number in
                        guard let raw = number.uintValue, raw <= UInt64(UInt32.max) else { return }
                        updateRate = UInt32(raw)
                    }
                }
            }
            guard let valueType else { return nil }
            return RoutingEndpoint(
                id: envelope.objectID,
                role: role,
                parentID: envelope.parentObjectID,
                valueType: valueType,
                representation: binary ? .binary : .json,
                externalRoute: externalRoute,
                updateRate: updateRate
            )
        }
    }
}

private func decodeDeadvertisedIDs(_ bytes: [UInt8]) -> [ObjectID] {
    bytes.withUnsafeBufferPointer { buffer in
        guard let base = buffer.baseAddress else { return [] }
        let reader = WireReader(bytes: base, length: buffer.count)
        guard let deadvertised = try? DeadvertiseWireData(from: reader) else { return [] }
        var result: [ObjectID] = []
        deadvertised.objectIds.withBytes { pointer, count in
            let value = WireValueReader(ByteSlice(bytes: pointer.assumingMemoryBound(to: UInt8.self), length: count))
            try? value.withArrayElements { element in
                if let id = ObjectID(bytes: element) { result.append(id) }
            }
        }
        return result
    }
}

private func decodedString<let capacity: Int>(
    _ value: borrowing JSONValueView,
    into _: InlineArray<capacity, UInt8>.Type
) -> [UInt8]? {
    var result: [UInt8]?
    _ = value.withString { encoded in
        var storage = InlineArray<capacity, UInt8>(repeating: 0)
        var length = 0
        do throws(WireDecodeError) {
            length = try encoded.copyDecodedJSONString(into: &storage)
        } catch {
            return
        }
        result = (0..<length).map { storage[$0] }
    }
    return result
}
