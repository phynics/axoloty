// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyObjectModel
@_spi(AxolotyRuntimeAdapter) import AxolotyProtocol
import AxolotyWire

struct StaticIoReceiveContext {
    let receivedAtMS: UInt32
    let associationGeneration: UInt32
}

extension StaticRuntime {
    /// Publishes one typed IO value through active associations.
    ///
    /// - Parameters:
    ///   - value: Borrowed application value encoded during this call.
    ///   - source: Registered source handle.
    ///   - nowMS: Wrapping monotonic time in milliseconds.
    /// - Returns: The bounded publication admission result.
    public mutating func publishIoValue<Value: IoEndpointValue>(
        _ value: borrowing Value,
        from source: IoSource<Value>,
        nowMS: UInt32
    ) -> IoPublicationReceipt {
        guard let slot = ioRegistry.sourceSlot(for: source, registryID: registryID),
              let record = ioRegistry.endpoint(at: slot) else {
            return .rejected(.invalidEndpoint)
        }
        let encoded: BoundedIoBytes<payloadCapacity>
        do throws(ProtocolError) {
            encoded = try encodeIoValue(value, representation: record.representation)
        } catch {
            return .rejected(.malformedPayload)
        }

        let association = processor.ioAssociationState(forSource: record.id.uuid)
        guard association.hasAssociations else {
            ioRegistry.clearSourceTransportState(at: slot)
            return .notAssociated
        }
        let decision = record.machine.decision(
            policy: record.publication,
            association: association,
            nowMS: nowMS
        )
        switch decision {
        case .notAssociated:
            ioRegistry.clearSourceTransportState(at: slot)
            return .notAssociated
        case .throttled:
            return .throttled
        case .replaceLatest:
            ioRegistry.replacePending(at: slot, with: encoded)
            return .queuedLatest
        case .emitCurrent:
            if sink.count != 0 || record.inFlight {
                if case .latest = record.publication {
                    ioRegistry.replacePending(at: slot, with: encoded)
                    return .queuedLatest
                }
                return .rejected(.capacityExceeded)
            }
            let outcome = encoded.withBytes { bytes in
                send(.ioValue(sourceID: record.id.uuid, payload: bytes), nowMS: nowMS)
            }
            switch outcome {
            case .accepted:
                ioRegistry.commitEmission(at: slot, nowMS: nowMS)
                return .published
            case .ignored:
                ioRegistry.clearSourceTransportState(at: slot)
                return .notAssociated
            case .rejected(let code):
                if code == .capacityExceeded, case .latest = record.publication {
                    ioRegistry.replacePending(at: slot, with: encoded)
                    return .queuedLatest
                }
                return .rejected(code)
            }
        }
    }

    /// Returns the processor-owned source association projection.
    ///
    /// - Parameter source: Registered source handle.
    /// - Returns: Current complete association state.
    /// - Throws: ``ProtocolError`` when the handle is stale or foreign.
    public borrowing func ioAssociationState<Value: IoEndpointValue>(
        of source: IoSource<Value>
    ) throws(ProtocolError) -> IoAssociationState {
        guard let slot = ioRegistry.sourceSlot(for: source, registryID: registryID),
              let record = ioRegistry.endpoint(at: slot) else {
            throw ProtocolError(.invalidEndpoint)
        }
        return processor.ioAssociationState(forSource: record.id.uuid)
    }

    /// Returns the processor-owned actor association projection.
    ///
    /// - Parameter actor: Registered actor handle.
    /// - Returns: Current complete association state.
    /// - Throws: ``ProtocolError`` when the handle is stale or foreign.
    public borrowing func ioAssociationState<Value: IoEndpointValue>(
        of actor: IoActor<Value>
    ) throws(ProtocolError) -> IoAssociationState {
        guard let slot = ioRegistry.actorSlot(for: actor, registryID: registryID),
              let record = ioRegistry.endpoint(at: slot) else {
            throw ProtocolError(.invalidEndpoint)
        }
        return processor.ioAssociationState(forActor: record.id.uuid)
    }

    /// Visits the current source projection when its generation changed.
    ///
    /// - Parameters:
    ///   - source: Registered source handle.
    ///   - generation: Last generation observed by the caller.
    ///   - body: Synchronous visitor for the complete current snapshot.
    /// - Returns: `true` when `body` received a newer snapshot.
    /// - Throws: ``ProtocolError`` when the handle is stale or foreign.
    public borrowing func visitIoAssociationState<Value: IoEndpointValue>(
        of source: IoSource<Value>,
        after generation: UInt32,
        _ body: (borrowing IoAssociationState) -> Void
    ) throws(ProtocolError) -> Bool {
        let state = try ioAssociationState(of: source)
        guard state.generation != generation else { return false }
        body(state)
        return true
    }

    /// Visits the current actor projection when its generation changed.
    ///
    /// - Parameters:
    ///   - actor: Registered actor handle.
    ///   - generation: Last generation observed by the caller.
    ///   - body: Synchronous visitor for the complete current snapshot.
    /// - Returns: `true` when `body` received a newer snapshot.
    /// - Throws: ``ProtocolError`` when the handle is stale or foreign.
    public borrowing func visitIoAssociationState<Value: IoEndpointValue>(
        of actor: IoActor<Value>,
        after generation: UInt32,
        _ body: (borrowing IoAssociationState) -> Void
    ) throws(ProtocolError) -> Bool {
        let state = try ioAssociationState(of: actor)
        guard state.generation != generation else { return false }
        body(state)
        return true
    }

    /// Flushes pending latest values in stable source-slot order.
    ///
    /// - Parameter nowMS: Wrapping monotonic time in milliseconds.
    /// - Returns: The number of source values accepted for publication.
    @discardableResult
    public mutating func flushIo(nowMS: UInt32) -> Int {
        var emitted = 0
        for slot in 0..<capacity {
            guard let record = ioRegistry.endpoint(at: slot),
                  record.role == .source,
                  let pending = ioRegistry.pending(at: slot) else { continue }
            let association = processor.ioAssociationState(forSource: record.id.uuid)
            guard association.hasAssociations else {
                ioRegistry.clearSourceTransportState(at: slot)
                continue
            }
            switch record.machine.decision(
                policy: record.publication,
                association: association,
                nowMS: nowMS
            ) {
            case .notAssociated:
                ioRegistry.clearSourceTransportState(at: slot)
            case .throttled, .replaceLatest:
                continue
            case .emitCurrent:
                guard !record.inFlight, sink.count == 0 else {
                    return emitted
                }
                let outcome = pending.withBytes { bytes in
                    send(.ioValue(sourceID: record.id.uuid, payload: bytes), nowMS: nowMS)
                }
                switch outcome {
                case .accepted:
                    ioRegistry.commitEmission(at: slot, nowMS: nowMS)
                    emitted += 1
                case .ignored:
                    ioRegistry.clearSourceTransportState(at: slot)
                case .rejected:
                    return emitted
                }
            }
        }
        return emitted
    }

    /// Registers a typed, fixed-representation IO source.
    ///
    /// - Parameters:
    ///   - metadata: Source metadata consumed by registration.
    ///   - valueType: Concrete value type used for publication.
    ///   - publication: Local publication timing policy.
    /// - Returns: A provenance-bound source handle.
    /// - Throws: ``ProtocolError`` when registration cannot commit atomically.
    public mutating func registerIoSource<Value: IoValue>(
        metadata: consuming Object<IoSourceMetadata>,
        as valueType: Value.Type,
        publication: IoPublicationPolicy = .immediate
    ) throws(ProtocolError) -> IoSource<Value> {
        _ = valueType
        let definition = try BoundedIoSourceEndpointDefinition<payloadCapacity>(
            metadata: metadata,
            representation: Value.representation,
            publication: publication
        )
        let registration = try registerSource(definition)
        return IoSource(
            registryID: registryID,
            slot: UInt16(registration.slot),
            generation: registration.generation,
            id: registration.id,
            representation: registration.representation
        )
    }

    /// Registers a source whose dynamic representation is fixed by the caller.
    ///
    /// - Parameters:
    ///   - metadata: Source metadata consumed by registration.
    ///   - representation: Representation accepted by this endpoint.
    ///   - publication: Local publication timing policy.
    /// - Returns: A provenance-bound dynamic source handle.
    /// - Throws: ``ProtocolError`` when registration cannot commit atomically.
    public mutating func registerDynamicIoSource(
        metadata: consuming Object<IoSourceMetadata>,
        representation: IoValueRepresentation,
        publication: IoPublicationPolicy = .immediate
    ) throws(ProtocolError) -> IoSource<DynamicIoValue> {
        let definition = try BoundedIoSourceEndpointDefinition<payloadCapacity>(
            metadata: metadata,
            representation: representation,
            publication: publication
        )
        let registration = try registerSource(definition)
        return IoSource(
            registryID: registryID,
            slot: UInt16(registration.slot),
            generation: registration.generation,
            id: registration.id,
            representation: registration.representation
        )
    }

    /// Registers a macro-generated synchronous IO actor.
    ///
    /// - Parameters:
    ///   - metadata: Actor metadata consumed by registration.
    ///   - handler: Generated handler entry and numeric context.
    ///   - recommendedUpdateRateMS: Optional association recommendation.
    /// - Returns: A provenance-bound actor handle.
    /// - Throws: ``ProtocolError`` when registration cannot commit atomically.
    public mutating func registerIoActor<Handler: StaticIoActorHandler>(
        metadata: consuming Object<IoActorMetadata>,
        handler: StaticIoHandler<Handler>,
        recommendedUpdateRateMS: UInt32? = nil
    ) throws(ProtocolError) -> IoActor<Handler.Value> {
        guard let representation = Handler.Value.fixedRepresentation else {
            throw ProtocolError(.invalidEndpoint)
        }
        let definition = try BoundedIoActorEndpointDefinition<payloadCapacity>(
            metadata: metadata,
            representation: representation,
            recommendedUpdateRateMS: recommendedUpdateRateMS
        )
        let registration = try registerActor(definition, handler: handler)
        return IoActor(
            registryID: registryID,
            slot: UInt16(registration.slot),
            generation: registration.generation,
            id: registration.id,
            representation: registration.representation
        )
    }

    /// Registers a dynamic actor with a fixed accepted representation.
    ///
    /// - Parameters:
    ///   - metadata: Actor metadata consumed by registration.
    ///   - representation: Representation accepted by this endpoint.
    ///   - handler: Generated dynamic handler entry and numeric context.
    ///   - recommendedUpdateRateMS: Optional association recommendation.
    /// - Returns: A provenance-bound dynamic actor handle.
    /// - Throws: ``ProtocolError`` when registration cannot commit atomically.
    public mutating func registerDynamicIoActor<Handler: StaticIoActorHandler>(
        metadata: consuming Object<IoActorMetadata>,
        representation: IoValueRepresentation,
        handler: StaticIoHandler<Handler>,
        recommendedUpdateRateMS: UInt32? = nil
    ) throws(ProtocolError) -> IoActor<DynamicIoValue> where Handler.Value == DynamicIoValue {
        let definition = try BoundedIoActorEndpointDefinition<payloadCapacity>(
            metadata: metadata,
            representation: representation,
            recommendedUpdateRateMS: recommendedUpdateRateMS
        )
        let registration = try registerActor(definition, handler: handler)
        return IoActor(
            registryID: registryID,
            slot: UInt16(registration.slot),
            generation: registration.generation,
            id: registration.id,
            representation: registration.representation
        )
    }

    private mutating func registerSource(
        _ definition: consuming BoundedIoSourceEndpointDefinition<payloadCapacity>
    ) throws(ProtocolError) -> (slot: Int, generation: UInt32, id: ObjectID, representation: IoValueRepresentation) {
        guard sink.count == 0, receiveContext == nil else {
            throw ProtocolError(.capacityExceeded)
        }
        guard let slot = ioRegistry.firstFreeSlot() else {
            throw ProtocolError(.capacityExceeded)
        }
        guard !ioRegistry.contains(id: definition.id),
              let generation = ioRegistry.generation(at: slot) else {
            throw ProtocolError(.invalidEndpoint)
        }
        let objectBytes = try copyEndpointBytes(from: definition)
        let advertise = try makeAdvertisePayload(copying: objectBytes)
        let endpointID = definition.id
        let representation = definition.representation
        let publication = definition.publication
        try submitAdvertise(endpointID: endpointID, payload: advertise)
        ioRegistry.commitSource(
            at: slot,
            id: endpointID,
            generation: generation,
            representation: representation,
            objectBytes: objectBytes,
            publication: publication
        )
        return (slot, generation, endpointID, representation)
    }

    private mutating func registerActor<Handler: StaticIoActorHandler>(
        _ definition: consuming BoundedIoActorEndpointDefinition<payloadCapacity>,
        handler: StaticIoHandler<Handler>
    ) throws(ProtocolError) -> (slot: Int, generation: UInt32, id: ObjectID, representation: IoValueRepresentation) {
        guard sink.count == 0, receiveContext == nil else {
            throw ProtocolError(.capacityExceeded)
        }
        guard let slot = ioRegistry.firstFreeSlot() else {
            throw ProtocolError(.capacityExceeded)
        }
        guard !ioRegistry.contains(id: definition.id),
              let generation = ioRegistry.generation(at: slot) else {
            throw ProtocolError(.invalidEndpoint)
        }
        let objectBytes = try copyEndpointBytes(from: definition)
        let advertise = try makeAdvertisePayload(copying: objectBytes)
        let endpointID = definition.id
        let representation = definition.representation
        let context = handler.context
        let entry = handler.entry
        try submitAdvertise(endpointID: endpointID, payload: advertise)
        ioRegistry.commitActor(
            at: slot,
            id: endpointID,
            generation: generation,
            representation: representation,
            objectBytes: objectBytes,
            entry: entry,
            context: context
        )
        return (slot, generation, endpointID, representation)
    }

    private mutating func submitAdvertise(
        endpointID: ObjectID,
        payload: BoundedIoBytes<payloadCapacity>
    ) throws(ProtocolError) {
        let outcome = payload.withBytes { bytes in
            send(
                .advertise(sourceID: endpointID.uuid, payload: bytes)
            )
        }
        guard case .accepted = outcome else {
            switch outcome {
            case .rejected(let code): throw ProtocolError(code)
            case .ignored: throw ProtocolError(.malformedPayload)
            case .accepted: return
            }
        }
    }

    /// Replays a retained source Advertise operation through the ordinary path.
    ///
    /// - Parameter source: Previously registered source handle.
    /// - Throws: ``ProtocolError`` when the handle or replay is invalid.
    public mutating func replayIoAdvertisement<Value: IoEndpointValue>(
        for source: IoSource<Value>
    ) throws(ProtocolError) {
        guard sink.count == 0, receiveContext == nil else { throw ProtocolError(.capacityExceeded) }
        guard let slot = ioRegistry.sourceSlot(for: source, registryID: registryID),
              let record = ioRegistry.endpoint(at: slot) else { throw ProtocolError(.invalidEndpoint) }
        let advertise = try makeAdvertisePayload(copying: record.objectBytes)
        try submitAdvertise(endpointID: record.id, payload: advertise)
    }

    /// Replays a retained actor Advertise operation through the ordinary path.
    ///
    /// - Parameter actor: Previously registered actor handle.
    /// - Throws: ``ProtocolError`` when the handle or replay is invalid.
    public mutating func replayIoAdvertisement<Value: IoEndpointValue>(
        for actor: IoActor<Value>
    ) throws(ProtocolError) {
        guard sink.count == 0, receiveContext == nil else { throw ProtocolError(.capacityExceeded) }
        guard let slot = ioRegistry.actorSlot(for: actor, registryID: registryID),
              let record = ioRegistry.endpoint(at: slot) else { throw ProtocolError(.invalidEndpoint) }
        let advertise = try makeAdvertisePayload(copying: record.objectBytes)
        try submitAdvertise(endpointID: record.id, payload: advertise)
    }
}

func dispatchStaticIoDelivery<let capacity: Int, let payloadCapacity: Int>(
    _ delivery: borrowing BorrowedProtocolDelivery,
    registry: borrowing StaticIoEndpointRegistry<capacity, payloadCapacity>,
    receiveContext: StaticIoReceiveContext?
) {
        guard case .ioActor(let actorUUID) = delivery.deliveryKey,
              let routeKind: IoRouteKind = {
                  switch delivery.routeClassification {
                  case .coaty: return .coaty
                  case .external: return .external
                  case .unrelated: return nil
                  }
              }(),
              let context = receiveContext,
              let slot = registry.actorSlot(forID: ObjectID(uuid: actorUUID)),
              let actorRecord = registry.endpoint(at: slot),
              let actor = registry.actor(at: slot),
              actorRecord.role == .actor,
              actorRecord.id.uuid == actorUUID,
              let entry = actor.entry else { return }
        entry.invoke(
            context: actor.context,
            payload: delivery.payload,
            representation: actorRecord.representation,
            sourceID: delivery.routingKey.sourceID,
            actorID: actorUUID,
            receivedAtMS: context.receivedAtMS,
            associationGeneration: context.associationGeneration,
            routeKind: routeKind
        )
}

private func makeAdvertisePayload<let payloadCapacity: Int>(
    copying objectBytes: borrowing BoundedIoBytes<payloadCapacity>
) throws(ProtocolError) -> BoundedIoBytes<payloadCapacity> {
    var objectStorage = InlineArray<payloadCapacity, UInt8>(repeating: 0)
    var objectLength = 0
    objectBytes.withBytes { bytes in
        objectLength = bytes.length
        for index in 0..<bytes.length {
            objectStorage[index] = bytes.byte(at: index) ?? 0
        }
    }
    var storage = InlineArray<payloadCapacity, UInt8>(repeating: 0)
    var length = 0
    var failed = false
    withUnsafeMutableBytes(of: &storage) { rawBuffer in
        var writer = WireWriter(
            buffer: rawBuffer.baseAddress!.assumingMemoryBound(to: UInt8.self),
            capacity: rawBuffer.count
        )
        do throws(WireEncodeError) {
            try writer.beginObject()
            try writer.writeKey("object")
            var objectError: WireEncodeError?
            withUnsafeBytes(of: objectStorage) { rawObject in
                let bytes = ByteSlice(
                    bytes: rawObject.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    length: objectLength
                )
                do throws(WireEncodeError) {
                    try writer.writeRawValue(bytes)
                } catch {
                    objectError = error
                }
            }
            if let objectError { throw objectError }
            try writer.endObject()
            length = writer.position
        } catch {
            failed = true
        }
    }
    guard !failed else { throw ProtocolError(.capacityExceeded) }
    var result: BoundedIoBytes<payloadCapacity>?
    withUnsafeBytes(of: storage) { rawBuffer in
        result = try? BoundedIoBytes<payloadCapacity>(copying: ByteSlice(
            bytes: rawBuffer.baseAddress!.assumingMemoryBound(to: UInt8.self),
            length: length
        ))
    }
    guard let result else { throw ProtocolError(.capacityExceeded) }
    return result
}

private func copyEndpointBytes<let payloadCapacity: Int>(
    from definition: borrowing BoundedIoSourceEndpointDefinition<payloadCapacity>
) throws(ProtocolError) -> BoundedIoBytes<payloadCapacity> {
    var result: BoundedIoBytes<payloadCapacity>?
    definition.withObjectBytes { bytes in
        result = try? BoundedIoBytes<payloadCapacity>(copying: bytes)
    }
    guard let result else { throw ProtocolError(.capacityExceeded) }
    return result
}

private func copyEndpointBytes<let payloadCapacity: Int>(
    from definition: borrowing BoundedIoActorEndpointDefinition<payloadCapacity>
) throws(ProtocolError) -> BoundedIoBytes<payloadCapacity> {
    var result: BoundedIoBytes<payloadCapacity>?
    definition.withObjectBytes { bytes in
        result = try? BoundedIoBytes<payloadCapacity>(copying: bytes)
    }
    guard let result else { throw ProtocolError(.capacityExceeded) }
    return result
}

private func encodeIoValue<Value: IoEndpointValue, let payloadCapacity: Int>(
    _ value: borrowing Value,
    representation: IoValueRepresentation
) throws(ProtocolError) -> BoundedIoBytes<payloadCapacity> {
    var result: BoundedIoBytes<payloadCapacity>?
    do {
        try value.withEncodedIoPayload(representation: representation) { bytes in
            result = try? BoundedIoBytes<payloadCapacity>(copying: bytes)
        }
    } catch {
        throw ProtocolError(.malformedPayload)
    }
    guard let result else { throw ProtocolError(.malformedPayload) }
    return result
}
