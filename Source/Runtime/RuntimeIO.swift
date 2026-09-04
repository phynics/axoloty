// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@_spi(AxolotyRuntimeAdapter) import AxolotyProtocol
import AxolotyObjectModel
import AxolotyWire

/// Executor-backed typed IO operations for a running host runtime.
public struct RuntimeIO: Sendable {
    private let executor: ProtocolExecutor

    init(executor: ProtocolExecutor) { self.executor = executor }

    /// Publishes one typed value from a registered source.
    /// - Parameters:
    ///   - value: The value to encode and publish.
    ///   - source: The registered source handle.
    ///   - nowMS: Optional wrapping monotonic time; the runtime clock is used when omitted.
    /// - Returns: The bounded publication admission receipt.
    /// - Throws: ``AxolotyError`` when encoding or handle validation fails.
    public func publish<Value: IoEndpointValue>(
        _ value: borrowing Value, from source: IoSource<Value>, nowMS: UInt32? = nil
    ) async throws -> IoPublicationReceipt {
        let representation: IoValueRepresentation
        let encoded: [UInt8]
        do {
            if let fixed = Value.fixedRepresentation {
                representation = fixed
                encoded = try encodeRuntimeIoValue(value, representation: fixed)
            } else if let json = try? encodeRuntimeIoValue(value, representation: .json) {
                representation = .json; encoded = json
            } else {
                representation = .binary
                encoded = try encodeRuntimeIoValue(value, representation: .binary)
            }
        } catch { throw AxolotyError.caught(error) }
        return await executor.publishIo(
            encoded, representation: representation, from: source, nowMS: nowMS ?? monotonicNowMS()
        )
    }

    /// Returns the current association state for a source.
    /// - Parameter source: The registered source handle.
    /// - Returns: The complete processor-owned association projection.
    /// - Throws: ``AxolotyError`` for an invalid or foreign handle.
    public func state<Value: IoEndpointValue>(of source: IoSource<Value>) async throws -> IoAssociationState {
        do { return try await executor.ioState(of: source) }
        catch { throw AxolotyError.caught(error) }
    }

    /// Returns the current association state for an actor.
    /// - Parameter actor: The registered actor handle.
    /// - Returns: The complete processor-owned association projection.
    /// - Throws: ``AxolotyError`` for an invalid or foreign handle.
    public func state<Value: IoEndpointValue>(of actor: IoActor<Value>) async throws -> IoAssociationState {
        do { return try await executor.ioState(of: actor) }
        catch { throw AxolotyError.caught(error) }
    }

    /// Creates a bounded association snapshot stream for a source.
    /// - Parameters:
    ///   - source: The registered source handle.
    ///   - buffering: The bounded stream buffering policy.
    /// - Returns: A stream beginning with the current complete snapshot.
    /// - Throws: ``AxolotyError`` when the handle or observer capacity is invalid.
    public func associations<Value: IoEndpointValue>(
        of source: IoSource<Value>, buffering: RuntimeBufferingPolicy = .coalesceLatest
    ) async throws -> AsyncStream<IoAssociationState> {
        do { return try await executor.ioAssociations(of: source, buffering: buffering) }
        catch { throw AxolotyError.caught(error) }
    }

    /// Creates a bounded association snapshot stream for an actor.
    /// - Parameters:
    ///   - actor: The registered actor handle.
    ///   - buffering: The bounded stream buffering policy.
    /// - Returns: A stream beginning with the current complete snapshot.
    /// - Throws: ``AxolotyError`` when the handle or observer capacity is invalid.
    public func associations<Value: IoEndpointValue>(
        of actor: IoActor<Value>, buffering: RuntimeBufferingPolicy = .coalesceLatest
    ) async throws -> AsyncStream<IoAssociationState> {
        do { return try await executor.ioAssociations(of: actor, buffering: buffering) }
        catch { throw AxolotyError.caught(error) }
    }
}

extension ProtocolExecutor {
    func flushPendingIo(at slot: Int, nowMS: UInt32) {
        guard state == .running, typedIoState.isSource(at: slot) else { return }
        guard let pending = typedIoState.endpoints[slot].pending else { return }
        let registration = typedIoState.endpoints[slot].registration
        let association = processor.ioAssociationState(forSource: registration.id.uuid)
        guard association.hasAssociations else { typedIoState.clearEndpoint(at: slot); return }
        guard !typedIoState.endpoints[slot].inFlight,
              outboundQueued < definition.capacities.dispatch else {
            if let request = typedIoState.flushRequest(at: slot, association: association) {
                scheduleIoFlush(request)
            }
            return
        }
        let plan = typedIoState.preparePendingPublication(
            at: slot, association: association, nowMS: nowMS, dispatchAvailable: true
        )
        guard case let .publish(token, sourceID, _) = plan else {
            if let request = typedIoState.flushRequest(at: slot, association: association) {
                scheduleIoFlush(request)
            }
            return
        }
        let outcome = publishTypedIo(.ioValue(sourceID: sourceID.uuid, payload: pending), token: token, nowMS: nowMS)
        if let request = typedIoState.completePendingPublication(
            token, outcome: outcome, nowMS: nowMS, association: association
        ) {
            scheduleIoFlush(request)
        }
    }

    private func scheduleIoFlush(_ request: RuntimeTypedIoState.FlushRequest) {
        guard typedIoState.flushTasks[request.slot] == nil else { return }
        let task = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(Int(request.delayMS))) }
            catch { return }
            await self?.runScheduledIoFlush(request.token)
        }
        typedIoState.installFlushTask(task, for: request)
    }

    func runScheduledIoFlush(_ token: RuntimeTypedIoState.PublicationToken) {
        guard typedIoState.takeFlushTask(for: token) else { return }
        typedIoFlushAttempts &+= 1
        flushPendingIo(at: token.slot, nowMS: monotonicNowMS())
    }

    func typedIoFlushAttemptsForTesting() -> Int { typedIoFlushAttempts }

    func clearIoTransportState() { typedIoState.clearTransportState() }

    func publishIoAdvertisements(nowMS: UInt32) async throws {
        for endpoint in typedIoState.endpointRegistrations {
            let payload = try runtimeAdvertisePayload(objectBytes: endpoint.objectBytes)
            try await publishLifecycle(.advertise(sourceID: endpoint.id.uuid, payload: payload), nowMS: nowMS)
        }
    }

    func publishIoDeadvertisements(nowMS: UInt32) async throws {
        for endpoint in typedIoState.endpointRegistrations {
            let payload = RuntimeLifecyclePayload.deadvertise(objectID: endpoint.id)
            try await publishLifecycle(.deadvertise(sourceID: endpoint.id.uuid, payload: payload), nowMS: nowMS)
        }
    }

    func publishIo<Value: IoEndpointValue>(
        _ encoded: [UInt8], representation: IoValueRepresentation, from source: IoSource<Value>, nowMS: UInt32
    ) -> IoPublicationReceipt {
        guard state == .running else { return .rejected(.malformedPayload) }
        guard let slot = typedIoState.sourceSlot(source), let endpoint = typedIoState.endpoint(at: slot) else {
            return .rejected(.invalidEndpoint)
        }
        let association = processor.ioAssociationState(forSource: endpoint.registration.id.uuid)
        let plan = typedIoState.preparePublication(
            encoded, representation: representation, from: source, association: association,
            nowMS: nowMS, dispatchAvailable: outboundQueued < definition.capacities.dispatch
        )
        switch plan {
        case let .receipt(receipt):
            if receipt == .notAssociated { typedIoState.clearEndpoint(at: slot) }
            return receipt
        case let .queueLatest(token, _):
            guard let completion = typedIoState.completePublication(
                plan, outcome: nil, nowMS: nowMS, association: association
            ) else { return .rejected(.capacityExceeded) }
            if let request = completion.flushRequest { scheduleIoFlush(request) }
            _ = token
            return completion.receipt
        case let .publish(token, sourceID, payload):
            let outcome = publishTypedIo(.ioValue(sourceID: sourceID.uuid, payload: payload), token: token, nowMS: nowMS)
            guard let completion = typedIoState.completePublication(
                plan, outcome: outcome, nowMS: nowMS, association: association
            ) else { return ioPublicationReceipt(for: outcome) }
            if let request = completion.flushRequest { scheduleIoFlush(request) }
            return completion.receipt
        }
    }

    private func publishTypedIo(
        _ operation: RuntimeOperation,
        token: RuntimeTypedIoPublicationToken,
        nowMS: UInt32
    ) -> RuntimeReceipt {
        pendingTypedIoToken = token
        defer { pendingTypedIoToken = nil }
        return publish(operation, nowMS: nowMS)
    }

    func ioState<Value: IoEndpointValue>(of source: IoSource<Value>) throws(ProtocolError) -> IoAssociationState {
        guard let slot = typedIoState.sourceSlot(source), let endpoint = typedIoState.endpoint(at: slot) else {
            throw ProtocolError(.invalidEndpoint)
        }
        return processor.ioAssociationState(forSource: endpoint.registration.id.uuid)
    }

    func ioState<Value: IoEndpointValue>(of actor: IoActor<Value>) throws(ProtocolError) -> IoAssociationState {
        guard let slot = typedIoState.actorSlot(actor), let endpoint = typedIoState.endpoint(at: slot) else {
            throw ProtocolError(.invalidEndpoint)
        }
        return processor.ioAssociationState(forActor: endpoint.registration.id.uuid)
    }

    func ioAssociations<Value: IoEndpointValue>(
        of source: IoSource<Value>, buffering: RuntimeBufferingPolicy
    ) throws(ProtocolError) -> AsyncStream<IoAssociationState> {
        guard let slot = typedIoState.sourceSlot(source), let endpoint = typedIoState.endpoint(at: slot) else {
            throw ProtocolError(.invalidEndpoint)
        }
        let pair = AsyncStream<IoAssociationState>.makeStream(bufferingPolicy: runtimeIoBufferingPolicy(buffering))
        let snapshot = processor.ioAssociationState(forSource: endpoint.registration.id.uuid)
        let registered = try typedIoState.addObserver(
            sourceID: endpoint.registration.id, actorID: nil, snapshot: snapshot,
            buffering: buffering, continuation: pair.continuation
        )
        pair.continuation.yield(registered.snapshot)
        pair.continuation.onTermination = { _ in Task { await self.removeIoObserver(registered.id) } }
        _ = slot
        return pair.stream
    }

    func ioAssociations<Value: IoEndpointValue>(
        of actor: IoActor<Value>, buffering: RuntimeBufferingPolicy
    ) throws(ProtocolError) -> AsyncStream<IoAssociationState> {
        guard let slot = typedIoState.actorSlot(actor), let endpoint = typedIoState.endpoint(at: slot) else {
            throw ProtocolError(.invalidEndpoint)
        }
        let pair = AsyncStream<IoAssociationState>.makeStream(bufferingPolicy: runtimeIoBufferingPolicy(buffering))
        let snapshot = processor.ioAssociationState(forActor: endpoint.registration.id.uuid)
        let registered = try typedIoState.addObserver(
            sourceID: nil, actorID: endpoint.registration.id, snapshot: snapshot,
            buffering: buffering, continuation: pair.continuation
        )
        pair.continuation.yield(registered.snapshot)
        pair.continuation.onTermination = { _ in Task { await self.removeIoObserver(registered.id) } }
        _ = slot
        return pair.stream
    }

    func removeIoObserver(_ id: UInt64) { typedIoState.removeObserver(id) }
    func finishIoObservers() { typedIoState.finishObservers() }

    func notifyIoObservers(sourceIDs: Set<ObjectID>, actorIDs: Set<ObjectID>) {
        typedIoState.notifyObservers(
            sourceState: { id in self.processor.ioAssociationState(forSource: id.uuid) },
            actorState: { id in self.processor.ioAssociationState(forActor: id.uuid) },
            onStrictOverflow: { id in self.failIoObserver(id) },
            sourceIDs: sourceIDs,
            actorIDs: actorIDs
        )
    }

    func failIoObserver(_ id: UInt64) {
        emit(.init(kind: .capacityExceeded, detail: "typed IO association stream is full"))
        failRuntime(code: .capacityExceeded, detail: "strict typed IO association stream is full", diagnostic: .capacityExceeded)
        _ = id
    }

    func dispatchIoActorIfRegistered(_ action: OwnedProtocolAction, nowMS: UInt32) {
        guard case let .deliver(delivery) = action,
              case let .ioActor(actorID) = delivery.deliveryKey,
              let routeKind = IoRouteKind(protocolClassification: delivery.routeClassification),
              let index = typedIoState.actorSlot(forID: ObjectID(uuid: actorID)),
              let handler = typedIoState.endpoints[index].registration.handler else { return }
        let generation = processor.ioAssociationState(forActor: actorID).generation
        let context = IoDeliveryContext(
            sourceUUID: delivery.routingKey.sourceID, actorUUID: actorID, receivedAtMS: nowMS,
            associationGeneration: generation, routeKind: routeKind
        )
        let payload = delivery.payload
        guard activeHandlers < definition.capacities.handlersInFlight else {
            emitIoDiagnostic("IO actor delivery dropped: handler capacity is full")
            return
        }
        activeHandlers += 1
        let handlerID = nextHandlerID
        nextHandlerID &+= 1
        let task = Task { [weak self] in
            do { try await handler(payload, context) }
            catch is CancellationError { }
            catch { await self?.ioHandlerFailed(runtimeErrorDetail(error)) }
            await self?.ioHandlerFinished(handlerID)
        }
        handlerTasks[handlerID] = task
    }

    func ioHandlerFailed(_ detail: String) { emitIoDiagnostic("IO actor delivery dropped: \(detail)") }

    func ioHandlerFinished(_ handlerID: UInt64) {
        activeHandlers = max(0, activeHandlers - 1)
        handlerTasks.removeValue(forKey: handlerID)
    }

    func emitIoDiagnostic(_ detail: String) { emit(.init(kind: .handlerFailed, detail: detail)) }
}

private func ioPublicationReceipt(for outcome: RuntimeReceipt) -> IoPublicationReceipt {
    switch outcome {
    case .accepted: return .published
    case .ignored: return .notAssociated
    case .rejected(.capacityExceeded): return .rejected(.capacityExceeded)
    case let .rejected(.protocol(code)): return .rejected(code)
    case .rejected: return .rejected(.malformedPayload)
    }
}

private func runtimeAdvertisePayload(objectBytes: BoundedIoBytes<2048>) throws(ProtocolError) -> [UInt8] {
    var output = [UInt8](repeating: 0, count: WireBufferConfig.maxPayloadSize)
    var length = 0
    var failed = false
    output.withUnsafeMutableBufferPointer { buffer in
        var writer = WireWriter(buffer: buffer.baseAddress!, capacity: buffer.count)
        do throws(WireEncodeError) {
            try writer.beginObject(); try writer.writeKey("object")
            objectBytes.withBytes { bytes in do { try writer.writeRawValue(bytes) } catch { failed = true } }
            if failed { throw WireEncodeError.bufferOverflow }
            try writer.endObject(); length = writer.position
        } catch { failed = true }
    }
    guard !failed else { throw ProtocolError(.capacityExceeded) }
    output.removeSubrange(length..<output.count)
    return output
}

private func runtimeIoBufferingPolicy(
    _ policy: RuntimeBufferingPolicy
) -> AsyncStream<IoAssociationState>.Continuation.BufferingPolicy {
    switch policy {
    case let .failAfterDrop(capacity), let .dropNewest(capacity): return .bufferingOldest(max(1, capacity))
    case let .fail(capacity), let .dropOldest(capacity): return .bufferingNewest(max(1, capacity))
    case .coalesceLatest: return .bufferingNewest(1)
    }
}

private func encodeRuntimeIoValue<Value: IoEndpointValue>(
    _ value: borrowing Value, representation: IoValueRepresentation
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
    guard result.count <= WireBufferConfig.maxPayloadSize else { throw .capacityExceeded }
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
