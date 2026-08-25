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
    var lastGeneration: UInt32
    let policy: RuntimeBufferingPolicy
}

/// Executor-backed typed IO operations for a running host runtime.
public struct RuntimeIO: Sendable {
    private let executor: ProtocolExecutor

    init(executor: ProtocolExecutor) {
        self.executor = executor
    }

    /// Publishes one typed value from a registered source.
    ///
    /// - Parameters:
    ///   - value: The value to encode and publish.
    ///   - source: The registered source handle.
    ///   - nowMS: Optional wrapping monotonic time; the runtime clock is used when omitted.
    /// - Returns: The bounded publication admission receipt.
    /// - Throws: ``AxolotyError`` when encoding or handle validation fails.
    public func publish<Value: IoEndpointValue>(
        _ value: borrowing Value,
        from source: IoSource<Value>,
        nowMS: UInt32? = nil
    ) async throws -> IoPublicationReceipt {
        let representation: IoValueRepresentation
        let encoded: [UInt8]
        do {
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
        } catch {
            throw AxolotyError.caught(error)
        }
        return await executor.publishIo(
            encoded,
            representation: representation,
            from: source,
            nowMS: nowMS ?? monotonicNowMS()
        )
    }

    /// Returns the current association state for a source.
    ///
    /// - Parameter source: The registered source handle.
    /// - Returns: The complete processor-owned association projection.
    /// - Throws: ``AxolotyError`` for an invalid or foreign handle.
    public func state<Value: IoEndpointValue>(
        of source: IoSource<Value>
    ) async throws -> IoAssociationState {
        do { return try await executor.ioState(of: source) }
        catch { throw AxolotyError.caught(error) }
    }

    /// Returns the current association state for an actor.
    ///
    /// - Parameter actor: The registered actor handle.
    /// - Returns: The complete processor-owned association projection.
    /// - Throws: ``AxolotyError`` for an invalid or foreign handle.
    public func state<Value: IoEndpointValue>(
        of actor: IoActor<Value>
    ) async throws -> IoAssociationState {
        do { return try await executor.ioState(of: actor) }
        catch { throw AxolotyError.caught(error) }
    }

    /// Creates a bounded association snapshot stream for a source.
    ///
    /// - Parameters:
    ///   - source: The registered source handle.
    ///   - buffering: The bounded stream buffering policy.
    /// - Returns: A stream beginning with the current complete snapshot.
    /// - Throws: ``AxolotyError`` when the handle or observer capacity is invalid.
    public func associations<Value: IoEndpointValue>(
        of source: IoSource<Value>,
        buffering: RuntimeBufferingPolicy = .coalesceLatest
    ) async throws -> AsyncStream<IoAssociationState> {
        do { return try await executor.ioAssociations(of: source, buffering: buffering) }
        catch { throw AxolotyError.caught(error) }
    }

    /// Creates a bounded association snapshot stream for an actor.
    ///
    /// - Parameters:
    ///   - actor: The registered actor handle.
    ///   - buffering: The bounded stream buffering policy.
    /// - Returns: A stream beginning with the current complete snapshot.
    /// - Throws: ``AxolotyError`` when the handle or observer capacity is invalid.
    public func associations<Value: IoEndpointValue>(
        of actor: IoActor<Value>,
        buffering: RuntimeBufferingPolicy = .coalesceLatest
    ) async throws -> AsyncStream<IoAssociationState> {
        do { return try await executor.ioAssociations(of: actor, buffering: buffering) }
        catch { throw AxolotyError.caught(error) }
    }
}

extension ProtocolExecutor {
    /// Attempts one pending latest value per source after the previous
    /// publication batch has completed. The source scan is stable and stops
    /// at the first bounded dispatch failure.
    func flushPendingIo(nowMS: UInt32) {
        guard state == .running else { return }
        for index in ioStates.indices {
            guard ioStates[index].registration.role == .source,
                  let pending = ioStates[index].pending else { continue }
            let registration = ioStates[index].registration
            let association = processor.ioAssociationState(forSource: registration.id.uuid)
            guard association.hasAssociations else {
                ioStates[index].pending = nil
                ioStates[index].machine.clear()
                ioStates[index].inFlight = false
                continue
            }
            guard !ioStates[index].inFlight,
                  outboundQueued < definition.capacities.dispatch else { return }
            let decision = ioStates[index].machine.decision(
                policy: registration.publication,
                association: association,
                nowMS: nowMS
            )
            guard case .emitCurrent = decision else {
                if case .replaceLatest = decision {
                    scheduleIoFlush(for: index, registration: registration, association: association)
                }
                continue
            }
            switch publish(.ioValue(sourceID: registration.id.uuid, payload: pending), nowMS: nowMS) {
            case .accepted:
                ioStates[index].pending = nil
                ioStates[index].machine.commitEmission(at: nowMS)
                ioStates[index].inFlight = true
            case .ignored:
                ioStates[index].pending = nil
                ioStates[index].machine.clear()
                ioStates[index].inFlight = false
            case .rejected:
                return
            }
        }
    }

    private func scheduleIoFlush(
        for index: Int,
        registration: RuntimeIoEndpointRegistration,
        association: IoAssociationState
    ) {
        guard ioFlushTasks[index] == nil else { return }
        let localInterval: UInt32
        switch registration.publication {
        case .immediate: localInterval = 0
        case .latest(let interval), .throttle(let interval): localInterval = interval
        }
        let delay = max(1, max(localInterval, association.recommendedUpdateRateMS ?? 0))
        ioFlushTasks[index] = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(Int(delay)))
            } catch {
                return
            }
            await self?.runScheduledIoFlush(for: index)
        }
    }

    func runScheduledIoFlush(for index: Int) {
        ioFlushTasks.removeValue(forKey: index)
        flushPendingIo(nowMS: monotonicNowMS())
    }

    func clearIoTransportState() {
        for task in ioFlushTasks.values { task.cancel() }
        ioFlushTasks.removeAll(keepingCapacity: true)
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
            guard canQueueLatest(at: index) else { return .rejected(.capacityExceeded) }
            ioStates[index].pending = encoded
            scheduleIoFlush(for: index, registration: registration, association: association)
            return .queuedLatest
        case .emitCurrent:
            if ioStates[index].inFlight || outboundQueued >= definition.capacities.dispatch {
                if case .latest = registration.publication {
                    guard canQueueLatest(at: index) else { return .rejected(.capacityExceeded) }
                    ioStates[index].pending = encoded
                    scheduleIoFlush(for: index, registration: registration, association: association)
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
                    guard canQueueLatest(at: index) else { return .rejected(.capacityExceeded) }
                    ioStates[index].pending = encoded
                    scheduleIoFlush(for: index, registration: registration, association: association)
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
        guard ioObservers.count < definition.capacities.ioObservers else {
            throw ProtocolError(.capacityExceeded)
        }
        let snapshot = processor.ioAssociationState(forSource: ioStates[index].registration.id.uuid)
        ioObservers[observerID] = RuntimeIoObserver(
            sourceID: ioStates[index].registration.id,
            actorID: nil,
            continuation: pair.continuation,
            lastGeneration: snapshot.generation,
            policy: buffering
        )
        pair.continuation.yield(snapshot)
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
        guard ioObservers.count < definition.capacities.ioObservers else {
            throw ProtocolError(.capacityExceeded)
        }
        let snapshot = processor.ioAssociationState(forActor: ioStates[index].registration.id.uuid)
        ioObservers[observerID] = RuntimeIoObserver(
            sourceID: nil,
            actorID: ioStates[index].registration.id,
            continuation: pair.continuation,
            lastGeneration: snapshot.generation,
            policy: buffering
        )
        pair.continuation.yield(snapshot)
        pair.continuation.onTermination = { _ in
            Task { await self.removeIoObserver(observerID) }
        }
        return pair.stream
    }

    func removeIoObserver(_ id: UInt64) {
        ioObservers.removeValue(forKey: id)
    }

    func finishIoObservers() {
        for observer in ioObservers.values {
            observer.continuation.finish()
        }
        ioObservers.removeAll(keepingCapacity: true)
    }

    func notifyIoObservers() {
        for id in Array(ioObservers.keys) {
            guard var observer = ioObservers[id] else { continue }
            let state: IoAssociationState
            if let sourceID = observer.sourceID {
                state = processor.ioAssociationState(forSource: sourceID.uuid)
            } else if let actorID = observer.actorID {
                state = processor.ioAssociationState(forActor: actorID.uuid)
            } else {
                continue
            }
            guard state.generation != observer.lastGeneration else { continue }
            observer.lastGeneration = state.generation
            ioObservers[id] = observer
            let result = observer.continuation.yield(state)
            if case .dropped = result {
                switch observer.policy {
                case .failAfterDrop, .fail:
                    observer.continuation.finish()
                    ioObservers.removeValue(forKey: id)
                    failIoObserver(id)
                case .dropOldest, .dropNewest, .coalesceLatest:
                    break
                }
            }
        }
    }

    func failIoObserver(_ id: UInt64) {
        emit(.init(kind: .capacityExceeded, detail: "typed IO association stream is full"))
        failRuntime(
            code: .capacityExceeded,
            detail: "strict typed IO association stream is full",
            diagnostic: .capacityExceeded
        )
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
        guard activeHandlers < definition.capacities.handlersInFlight else {
            emitIoDiagnostic("IO actor delivery dropped: handler capacity is full")
            return
        }
        activeHandlers += 1
        let handlerID = nextHandlerID
        nextHandlerID &+= 1
        let task = Task { [weak self] in
            do {
                try await handler(payload, context)
            } catch is CancellationError {
                // Cancellation is expected during stop and does not produce a diagnostic.
            } catch {
                await self?.ioHandlerFailed(runtimeErrorDetail(error))
            }
            await self?.ioHandlerFinished(handlerID)
        }
        handlerTasks[handlerID] = task
    }

    func ioHandlerFailed(_ detail: String) {
        emitIoDiagnostic("IO actor delivery dropped: \(detail)")
    }

    func ioHandlerFinished(_ handlerID: UInt64) {
        activeHandlers = max(0, activeHandlers - 1)
        handlerTasks.removeValue(forKey: handlerID)
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

    private func canQueueLatest(at index: Int) -> Bool {
        if ioStates[index].pending != nil { return true }
        let pendingCount = ioStates.reduce(into: 0) { count, state in
            if state.pending != nil { count += 1 }
        }
        return pendingCount < definition.capacities.ioPendingLatest
    }

    func emitIoDiagnostic(_ detail: String) {
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
