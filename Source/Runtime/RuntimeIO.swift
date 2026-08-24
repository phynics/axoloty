// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@_spi(AxolotyRuntimeAdapter) import AxolotyProtocol
import AxolotyObjectModel
import AxolotyWire

struct RuntimeIoState: Sendable {
    let registration: RuntimeIoEndpointRegistration
    var machine = IoPublicationStateMachine()
    var pending: [UInt8]?
    var inFlight = false

    init(_ registration: RuntimeIoEndpointRegistration) {
        self.registration = registration
        self.pending = nil
    }
}

struct RuntimeIoObserver: Sendable {
    let sourceID: ObjectID?
    let actorID: ObjectID?
    let continuation: AsyncStream<IoAssociationState>.Continuation
}

/// Executor-backed typed IO operations for a running host runtime.
public struct RuntimeIO: Sendable {
    private let executor: ProtocolExecutor

    init(executor: ProtocolExecutor) {
        self.executor = executor
    }

    /// Publishes one typed value from a registered source.
    public func publish<Value: IoEndpointValue>(
        _ value: borrowing Value,
        from source: IoSource<Value>,
        nowMS: UInt32? = nil
    ) async throws -> IoPublicationReceipt {
        let representation: IoValueRepresentation
        let encoded: [UInt8]
        if let fixed = Value.fixedRepresentation {
            representation = fixed
            encoded = try encodeRuntimeIoValue(value, representation: fixed)
        } else if let json = try? encodeRuntimeIoValue(value, representation: .json) {
            representation = .json
            encoded = json
        } else {
            representation = .binary
            encoded = try encodeRuntimeIoValue(value, representation: .binary)
        }
        return await executor.publishIo(
            encoded,
            representation: representation,
            from: source,
            nowMS: nowMS ?? monotonicNowMS()
        )
    }

    /// Returns the current association state for a source.
    public func state<Value: IoEndpointValue>(
        of source: IoSource<Value>
    ) async throws -> IoAssociationState {
        try await executor.ioState(of: source)
    }

    /// Returns the current association state for an actor.
    public func state<Value: IoEndpointValue>(
        of actor: IoActor<Value>
    ) async throws -> IoAssociationState {
        try await executor.ioState(of: actor)
    }

    /// Creates a bounded association snapshot stream for a source.
    public func associations<Value: IoEndpointValue>(
        of source: IoSource<Value>,
        buffering: RuntimeBufferingPolicy = .coalesceLatest
    ) async throws -> AsyncStream<IoAssociationState> {
        try await executor.ioAssociations(of: source, buffering: buffering)
    }

    /// Creates a bounded association snapshot stream for an actor.
    public func associations<Value: IoEndpointValue>(
        of actor: IoActor<Value>,
        buffering: RuntimeBufferingPolicy = .coalesceLatest
    ) async throws -> AsyncStream<IoAssociationState> {
        try await executor.ioAssociations(of: actor, buffering: buffering)
    }
}

extension ProtocolExecutor {
    func clearIoTransportState() {
        for index in ioStates.indices {
            ioStates[index].machine.clear()
            ioStates[index].pending = nil
            ioStates[index].inFlight = false
        }
    }

    func publishIoAdvertisements(nowMS: UInt32) async throws {
        for endpoint in definition.ioEndpointRegistrations {
            let payload = try runtimeAdvertisePayload(objectBytes: endpoint.objectBytes)
            try await publishLifecycle(
                .advertise(sourceID: endpoint.id.uuid, payload: payload),
                nowMS: nowMS
            )
        }
    }

    func publishIoDeadvertisements(nowMS: UInt32) async throws {
        for endpoint in definition.ioEndpointRegistrations {
            let payload = try runtimeAdvertisePayload(objectBytes: endpoint.objectBytes)
            try await publishLifecycle(
                .deadvertise(sourceID: endpoint.id.uuid, payload: payload),
                nowMS: nowMS
            )
        }
    }

    func publishIo<Value: IoEndpointValue>(
        _ encoded: [UInt8],
        representation: IoValueRepresentation,
        from source: IoSource<Value>,
        nowMS: UInt32
    ) -> IoPublicationReceipt {
        guard state == .running else { return .rejected(.malformedPayload) }
        guard let index = sourceIndex(source), ioStates[index].registration.role == .source else {
            return .rejected(.invalidEndpoint)
        }
        let registration = ioStates[index].registration
        guard registration.representation == representation else {
            return .rejected(.malformedPayload)
        }
        let association = processor.ioAssociationState(forSource: registration.id.uuid)
        guard association.hasAssociations else {
            ioStates[index].machine.clear()
            ioStates[index].pending = nil
            ioStates[index].inFlight = false
            return .notAssociated
        }
        let decision = ioStates[index].machine.decision(
            policy: registration.publication,
            association: association,
            nowMS: nowMS
        )
        switch decision {
        case .notAssociated:
            ioStates[index].machine.clear()
            ioStates[index].pending = nil
            ioStates[index].inFlight = false
            return .notAssociated
        case .throttled:
            return .throttled
        case .replaceLatest:
            ioStates[index].pending = encoded
            return .queuedLatest
        case .emitCurrent:
            if ioStates[index].inFlight || outboundQueued >= definition.capacities.dispatch {
                if case .latest = registration.publication {
                    ioStates[index].pending = encoded
                    return .queuedLatest
                }
                return .rejected(.capacityExceeded)
            }
            let receipt = publish(
                .ioValue(sourceID: registration.id.uuid, payload: encoded),
                nowMS: nowMS
            )
            switch receipt {
            case .accepted:
                ioStates[index].machine.commitEmission(at: nowMS)
                ioStates[index].inFlight = true
                return .published
            case .ignored:
                ioStates[index].machine.clear()
                ioStates[index].pending = nil
                return .notAssociated
            case .rejected(.capacityExceeded):
                if case .latest = registration.publication {
                    ioStates[index].pending = encoded
                    return .queuedLatest
                }
                return .rejected(.capacityExceeded)
            case .rejected(let rejection):
                switch rejection {
                case .protocol(let code): return .rejected(code)
                case .capacityExceeded: return .rejected(.capacityExceeded)
                default: return .rejected(.malformedPayload)
                }
            }
        }
    }

    func ioState<Value: IoEndpointValue>(of source: IoSource<Value>) throws(ProtocolError) -> IoAssociationState {
        guard let index = sourceIndex(source), ioStates[index].registration.role == .source else {
            throw ProtocolError(.invalidEndpoint)
        }
        return processor.ioAssociationState(forSource: ioStates[index].registration.id.uuid)
    }

    func ioState<Value: IoEndpointValue>(of actor: IoActor<Value>) throws(ProtocolError) -> IoAssociationState {
        guard let index = actorIndex(actor), ioStates[index].registration.role == .actor else {
            throw ProtocolError(.invalidEndpoint)
        }
        return processor.ioAssociationState(forActor: ioStates[index].registration.id.uuid)
    }

    func ioAssociations<Value: IoEndpointValue>(
        of source: IoSource<Value>,
        buffering: RuntimeBufferingPolicy
    ) throws(ProtocolError) -> AsyncStream<IoAssociationState> {
        guard let index = sourceIndex(source), ioStates[index].registration.role == .source else {
            throw ProtocolError(.invalidEndpoint)
        }
        let policy = runtimeIoBufferingPolicy(buffering)
        let pair = AsyncStream<IoAssociationState>.makeStream(bufferingPolicy: policy)
        let observerID = nextIoObserverID
        nextIoObserverID &+= 1
        ioObservers[observerID] = RuntimeIoObserver(
            sourceID: ioStates[index].registration.id,
            actorID: nil,
            continuation: pair.continuation
        )
        pair.continuation.yield(processor.ioAssociationState(forSource: ioStates[index].registration.id.uuid))
        pair.continuation.onTermination = { _ in
            Task { await self.removeIoObserver(observerID) }
        }
        return pair.stream
    }

    func ioAssociations<Value: IoEndpointValue>(
        of actor: IoActor<Value>,
        buffering: RuntimeBufferingPolicy
    ) throws(ProtocolError) -> AsyncStream<IoAssociationState> {
        guard let index = actorIndex(actor), ioStates[index].registration.role == .actor else {
            throw ProtocolError(.invalidEndpoint)
        }
        let policy = runtimeIoBufferingPolicy(buffering)
        let pair = AsyncStream<IoAssociationState>.makeStream(bufferingPolicy: policy)
        let observerID = nextIoObserverID
        nextIoObserverID &+= 1
        ioObservers[observerID] = RuntimeIoObserver(
            sourceID: nil,
            actorID: ioStates[index].registration.id,
            continuation: pair.continuation
        )
        pair.continuation.yield(processor.ioAssociationState(forActor: ioStates[index].registration.id.uuid))
        pair.continuation.onTermination = { _ in
            Task { await self.removeIoObserver(observerID) }
        }
        return pair.stream
    }

    func removeIoObserver(_ id: UInt64) {
        ioObservers.removeValue(forKey: id)
    }

    func notifyIoObservers() {
        for observer in ioObservers.values {
            let state: IoAssociationState
            if let sourceID = observer.sourceID {
                state = processor.ioAssociationState(forSource: sourceID.uuid)
            } else if let actorID = observer.actorID {
                state = processor.ioAssociationState(forActor: actorID.uuid)
            } else {
                continue
            }
            _ = observer.continuation.yield(state)
        }
    }

    func dispatchIoActorIfRegistered(_ action: OwnedProtocolAction, nowMS: UInt32) {
        guard case let .deliver(delivery) = action,
              case let .ioActor(actorID) = delivery.deliveryKey,
              let routeKind = IoRouteKind(protocolClassification: delivery.routeClassification),
              let index = ioStates.firstIndex(where: {
                  $0.registration.role == .actor && $0.registration.id.uuid == actorID
              }),
              let handler = ioStates[index].registration.handler else { return }
        let generation = processor.ioAssociationState(forActor: actorID).generation
        let context = IoDeliveryContext(
            sourceUUID: delivery.routingKey.sourceID,
            actorUUID: actorID,
            receivedAtMS: nowMS,
            associationGeneration: generation,
            routeKind: routeKind
        )
        let payload = delivery.payload
        let task = Task {
            do {
                try await handler(payload, context)
            } catch {
                await self.emitIoDiagnostic("IO actor delivery dropped: (error)")
            }
        }
        _ = task
    }

    private func sourceIndex<Value: IoEndpointValue>(_ source: IoSource<Value>) -> Int? {
        let slot = Int(source.runtimeSlot)
        guard slot >= 0, slot < ioStates.count else { return nil }
        let state = ioStates[slot]
        guard state.registration.role == .source,
              source.matches(
                  registryID: definition.registryID,
                  slot: source.runtimeSlot,
                  generation: 1,
                  id: state.registration.id,
                  representation: state.registration.representation
              ) else { return nil }
        return slot
    }

    private func actorIndex<Value: IoEndpointValue>(_ actor: IoActor<Value>) -> Int? {
        let slot = Int(actor.runtimeSlot)
        guard slot >= 0, slot < ioStates.count else { return nil }
        let state = ioStates[slot]
        guard state.registration.role == .actor,
              actor.matches(
                  registryID: definition.registryID,
                  slot: actor.runtimeSlot,
                  generation: 1,
                  id: state.registration.id,
                  representation: state.registration.representation
              ) else { return nil }
        return slot
    }

    private func emitIoDiagnostic(_ detail: String) {
        emit(.init(kind: .handlerFailed, detail: detail))
    }
}

private func runtimeAdvertisePayload(
    objectBytes: BoundedIoBytes<512>
) throws(ProtocolError) -> [UInt8] {
    var output = [UInt8](repeating: 0, count: 512)
    var length = 0
    var failed = false
    output.withUnsafeMutableBufferPointer { buffer in
        var writer = WireWriter(buffer: buffer.baseAddress!, capacity: buffer.count)
        do throws(WireEncodeError) {
            try writer.beginObject()
            try writer.writeKey("object")
            objectBytes.withBytes { bytes in
                do { try writer.writeRawValue(bytes) }
                catch { failed = true }
            }
            if failed { throw WireEncodeError.bufferOverflow }
            try writer.endObject()
            length = writer.position
        } catch {
            failed = true
        }
    }
    guard !failed else { throw ProtocolError(.capacityExceeded) }
    output.removeSubrange(length..<output.count)
    return output
}

private func runtimeIoBufferingPolicy(
    _ policy: RuntimeBufferingPolicy
) -> AsyncStream<IoAssociationState>.Continuation.BufferingPolicy {
    switch policy {
    case let .failAfterDrop(capacity), let .dropNewest(capacity):
        return .bufferingOldest(max(1, capacity))
    case let .fail(capacity), let .dropOldest(capacity):
        return .bufferingNewest(max(1, capacity))
    case .coalesceLatest:
        return .bufferingNewest(1)
    }
}

private func encodeRuntimeIoValue<Value: IoEndpointValue>(
    _ value: borrowing Value,
    representation: IoValueRepresentation
) throws(IoValueError) -> [UInt8] {
    var result: [UInt8] = []
    do {
        try value.withEncodedIoPayload(representation: representation) { bytes in
            result.reserveCapacity(bytes.length)
            for index in 0..<bytes.length { result.append(bytes.byte(at: index) ?? 0) }
        }
    } catch {
        throw .invalidValue
    }
    guard result.count <= 512 else { throw .capacityExceeded }
    return result
}

private extension IoRouteKind {
    init?(protocolClassification: ProtocolRouteClassification) {
        switch protocolClassification {
        case .coaty: self = .coaty
        case .external: self = .external
        case .unrelated: return nil
        }
    }
}
