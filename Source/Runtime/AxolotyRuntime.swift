// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyProtocol
import AxolotyObjectModel
import AxolotyWire
import Foundation

// The executor deliberately keeps lifecycle, ingress, dispatch, and handler
// supervision in one serialized owner. Keep this suppression scoped to the
// owner rather than weakening the repository-wide type-size rule.
// swiftlint:disable:next type_body_length
actor ProtocolExecutor {
    let definition: RuntimeDefinition
    let transport: AxolotyRuntimeTransport
    var processor: ProtocolProcessor<64>
    var actionSink = ReusableProtocolActionSink(capacity: 64)
    /// Actions retained for ``conformanceObservation()``. Every other buffer
    /// owned by this executor is capacity-bounded; this one must be too, or a
    /// production runtime that never calls the conformance SPI accumulates one
    /// copied action per dispatched action for the life of the instance. Bound
    /// it to the same dispatch capacity used for the live action sink rather
    /// than an invented constant, and drop the oldest entry once full so a
    /// draining consumer still observes the most recent activity.
    var conformanceActions: [OwnedProtocolAction] = []
    /// One-way operations accepted while the transport is reconnecting.
    /// This queue is bounded by the dispatch capacity and is replayed in
    /// publication order after a successful reconnect.
    private var offlineOperations: [RuntimeOperation] = []
    var state: RuntimeLifecycleState = .stopped
    private var hasStarted = false
    var lifecycleAdvertisementActive = false
    var activeHandlers = 0
    var handlerInFlight: [Int: Int] = [:]
    var nextHandlerID: UInt64 = 1
    var handlerTasks: [UInt64: Task<Void, Never>] = [:]
    private var terminalFailureValue: (AxolotyError.RuntimeErrorCode, String)?
    private var failureTeardownScheduled = false
    private let ingressOverflowGate = RuntimeOverflowGate()
    private var transportEpoch: UInt64 = 0
    private var transportIngressContinuation: AsyncStream<RuntimeInboundFrame>.Continuation?
    private var transportIngressTask: Task<Void, Never>?
    private var outboundContinuation: AsyncStream<RuntimeTransportEffectBatch>.Continuation?
    private var outboundTask: Task<Void, Never>?
    var outboundQueued = 0
    private var queuedTransportEffects = 0
    /// Effects handed to the outbound pump that have not yet been confirmed
    /// delivered, in publication order. A transport failure discards the
    /// pump and its `AsyncStream` buffer, but the caller already received an
    /// `.accepted` receipt for this work; `transportFailed(_:)` leaves this
    /// queue intact so `reconnect()` can replay it once the transport is
    /// back, instead of silently losing already-accepted publications.
    /// Bounded by `definition.capacities.dispatch`, mirroring
    /// `queuedTransportEffects`.
    private var pendingOutboundEffects: [RuntimeQueuedTransportEffect] = []
    var diagnosticsSnapshotValue = RuntimeDiagnostics()
    var typedIoState: RuntimeTypedIoState
    var pendingTypedIoToken: RuntimeTypedIoPublicationToken? = nil
    var typedIoFlushAttempts = 0
    var runtimeModuleTasks: [Task<Void, Never>] = []
    private let eventRegistrations: [RuntimeEventRegistration]

    private let eventStream: AsyncStream<RuntimeEvent>
    let eventContinuation: AsyncStream<RuntimeEvent>.Continuation
    private let diagnosticStream: AsyncStream<RuntimeDiagnostic>
    private let diagnosticContinuation: AsyncStream<RuntimeDiagnostic>.Continuation

    init(definition: RuntimeDefinition, transport: AxolotyRuntimeTransport) {
        self.definition = definition
        self.transport = transport
        self.processor = ProtocolProcessor<64>(
            capabilities: definition.capacities.protocolCapabilities,
            maximumPayloadBytes: definition.capacities.protocolMaximumPayloadBytes,
            maximumObjects: definition.capacities.protocolMaximumObjects,
            maximumPendingCorrelations: definition.capacities.protocolMaximumPendingCorrelations
        )
        self.eventRegistrations = definition.registrations.eventRegistrations
        self.typedIoState = RuntimeTypedIoState(registrations: definition.registrations)
        self.actionSink = ReusableProtocolActionSink(capacity: definition.capacities.dispatch)
        let events = AsyncStream<RuntimeEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(definition.capacities.stream)
        )
        self.eventStream = events.stream
        self.eventContinuation = events.continuation
        let diagnostics = AsyncStream<RuntimeDiagnostic>.makeStream(
            bufferingPolicy: .bufferingNewest(definition.capacities.stream)
        )
        self.diagnosticStream = diagnostics.stream
        self.diagnosticContinuation = diagnostics.continuation
    }

    func start() async -> (AxolotyError.RuntimeErrorCode, String)? {
        switch state {
        case .running:
            return (.notStarted, "runtime is already running")
        case .closed:
            return (.notStarted, "runtime is closed")
        case .starting, .reconnecting, .stopping:
            return (.notStarted, "runtime lifecycle transition is already in progress")
        case .failed:
            return (.notStarted, "runtime failed; stop it before restarting")
        case .stopped:
            guard !hasStarted else {
                return (.notStarted, "runtime instances are single-use; construct a new instance")
            }
            break
        }
        hasStarted = true
        state = .starting
        transportEpoch &+= 1
        let epoch = transportEpoch
        let ingressPipe = AsyncStream<RuntimeInboundFrame>.makeStream(
            bufferingPolicy: .bufferingOldest(definition.capacities.ingress)
        )
        ingressOverflowGate.reset()
        transportIngressContinuation = ingressPipe.continuation
        transportIngressTask = Task { [weak self, stream = ingressPipe.stream] in
            for await frame in stream {
                guard !Task.isCancelled else { break }
                await self?.receiveTransport(frame, epoch: epoch)
            }
        }
        outboundContinuation?.finish()
        outboundTask?.cancel()
        outboundContinuation = nil
        outboundTask = nil
        outboundQueued = 0
        queuedTransportEffects = 0
        installOutboundPump()
        do {
            await transport.setFailureHandler { [weak self] error in
                Task { await self?.transportFailed(runtimeErrorDetail(error)) }
            }
            try await transport.start { [weak self, continuation = ingressPipe.continuation, overflowGate = ingressOverflowGate] frame in
                let result = continuation.yield(frame)
                if case .dropped = result, overflowGate.claim() {
                    Task { await self?.ingressOverflow() }
                }
            }
            guard state == .starting, transportEpoch == epoch else {
                await transport.stop()
                return (.notStarted, "runtime start was superseded by another lifecycle transition")
            }
            try await transport.installSubscriptions(namespace: definition.namespace)
            guard state == .starting, transportEpoch == epoch else {
                await transport.stop()
                return (.notStarted, "runtime start was superseded while installing subscriptions")
            }
            try await publishLifecycleAdvertisement(nowMS: monotonicNowMS())
            try await publishIoAdvertisements(nowMS: monotonicNowMS())
            guard state == .starting, transportEpoch == epoch else {
                await transport.stop()
                return (.notStarted, "runtime start was superseded during advertisement")
            }
            state = .running
            await startRuntimeModules()
            return nil
        } catch {
            cancelIngressPump()
            outboundContinuation?.finish()
            // A concurrent stop/close may have advanced the epoch while the
            // transport was suspended. Preserve that terminal transition
            // instead of resurrecting the runtime as failed.
            if state == .starting, transportEpoch == epoch {
                failRuntime(
                    code: .brokerUnavailable,
                    detail: runtimeErrorDetail(error),
                    diagnostic: .transportFailed
                )
            }
            return (.brokerUnavailable, runtimeErrorDetail(error))
        }
    }

    func stop() async {
        guard state == .running || state == .starting || state == .reconnecting || state == .failed else { return }
        await stopRuntimeModules()
        state = .stopping
        offlineOperations.removeAll(keepingCapacity: true)
        pendingOutboundEffects.removeAll(keepingCapacity: true)
        transportEpoch &+= 1
        let stoppingEpoch = transportEpoch
        await cancelAndDrainHandlers()
        typedIoState.clearTransportState()
        finishIoObservers()
        cancelIngressPump()
        let hasLifecycleEffects = lifecycleAdvertisementActive || typedIoState.hasEndpoints
        do {
            try enqueueIoDeadvertisements(nowMS: monotonicNowMS())
            try enqueueLifecycleDeadvertisement(nowMS: monotonicNowMS())
        } catch {
            emit(.init(kind: .transportFailed, detail: runtimeErrorDetail(error)))
        }
        if hasLifecycleEffects {
            await drainOutboundPump()
        }
        do {
            try await transport.removeSubscriptions(namespace: definition.namespace)
        } catch {
            emit(.init(kind: .transportFailed, detail: runtimeErrorDetail(error)))
        }
        await transport.stop()
        if !hasLifecycleEffects {
            await drainOutboundPump()
        }
        guard state == .stopping, transportEpoch == stoppingEpoch else { return }
        state = .stopped
    }

    func close() async {
        guard state != .closed else { return }
        if state == .running || state == .starting || state == .reconnecting || state == .failed {
            await stop()
        }
        state = .closed
        finishIoObservers()
        for registration in eventRegistrations {
            registration.continuation.finish()
        }
        eventContinuation.finish()
        diagnosticContinuation.finish()
    }

    func reconnect() async {
        guard state == .running || state == .reconnecting else { return }
        state = .reconnecting
        transportEpoch &+= 1
        let epoch = transportEpoch
        processor.resetTransport()
        clearIoTransportState()
        diagnosticsSnapshotValue.reconnects += 1
        transportIngressContinuation?.finish()
        transportIngressTask?.cancel()
        let ingressPipe = AsyncStream<RuntimeInboundFrame>.makeStream(
            bufferingPolicy: .bufferingOldest(definition.capacities.ingress)
        )
        ingressOverflowGate.reset()
        transportIngressContinuation = ingressPipe.continuation
        transportIngressTask = Task { [weak self, stream = ingressPipe.stream] in
            for await frame in stream {
                guard !Task.isCancelled else { break }
                await self?.receiveTransport(frame, epoch: epoch)
            }
        }
        do {
            await stopOutboundPump()
            // A broker-side close can race this explicit reconnect.  The
            // binding may therefore already have lost its subscription
            // session; removal is best-effort in that path and a fresh
            // subscription installation below is authoritative.
            try? await transport.removeSubscriptions(namespace: definition.namespace)
            await transport.stop()
            installOutboundPump()
            await transport.setFailureHandler { [weak self] error in
                Task { await self?.transportFailed(runtimeErrorDetail(error)) }
            }
            try await transport.start { [weak self, continuation = ingressPipe.continuation, overflowGate = ingressOverflowGate] frame in
                let result = continuation.yield(frame)
                if case .dropped = result, overflowGate.claim() {
                    Task { await self?.ingressOverflow() }
                }
            }
            guard state == .reconnecting, transportEpoch == epoch else { return }
            try await transport.installSubscriptions(namespace: definition.namespace)
            guard state == .reconnecting, transportEpoch == epoch else { return }
            try await publishLifecycleAdvertisement(nowMS: monotonicNowMS())
            try await publishIoAdvertisements(nowMS: monotonicNowMS())
            guard state == .reconnecting, transportEpoch == epoch else { return }
            state = .running
            await startRuntimeModules(restarting: true)
            // Replay effects that were already accepted before the last
            // transport failure ahead of operations accepted while
            // reconnecting, preserving publication order.
            replayQueuedOutboundEffects()
            flushOfflineOperations(nowMS: monotonicNowMS())
        } catch {
            guard state == .reconnecting, transportEpoch == epoch else { return }
            // A transport failure while recovering is no more terminal than one
            // during normal operation. `transportFailed(_:)` deliberately parks
            // the executor in `.reconnecting` so the caller can restore the
            // network path and invoke `reconnect()` again; failing the runtime
            // here contradicted that contract and destroyed a recoverable
            // instance the first time a restarted broker was not yet accepting
            // connections. Stay `.reconnecting` and report the attempt so the
            // caller can retry.
            diagnosticsSnapshotValue.transportFailures += 1
            emit(.init(kind: .transportFailed, detail: runtimeErrorDetail(error)))
        }
    }

    private func ingressOverflow() {
        guard state == .running else { return }
        diagnosticsSnapshotValue.ingressSaturation += 1
        failRuntime(
            code: .capacityExceeded,
            detail: "transport ingress queue is full",
            diagnostic: .capacityExceeded
        )
    }

    func lifecycleState() -> RuntimeLifecycleState { state }

    func runtimeState() -> RuntimeState {
        switch state {
        case .stopped: return hasStarted ? .stopped : .initialized
        case .starting: return .starting
        case .running: return .running
        case .reconnecting: return .reconnecting
        case .stopping: return .stopping
        case .failed, .closed: return .failed
        }
    }

    func sourceID() -> UUID16 { definition.sourceID }

    func events() -> AsyncStream<RuntimeEvent> { eventStream }

    func diagnostics() -> AsyncStream<RuntimeDiagnostic> { diagnosticStream }
    func diagnosticsSnapshot() -> RuntimeDiagnostics { diagnosticsSnapshotValue }

    func terminalFailure() -> (AxolotyError.RuntimeErrorCode, String)? { terminalFailureValue }

    func expire(nowMS: UInt32) -> Bool {
        guard state == .running else { return false }
        let didExpire = processor.expire(nowMS: nowMS)
        if didExpire { diagnosticsSnapshotValue.expiredRequests += 1 }
        return didExpire
    }

    func cancel(correlationID: UUID16) -> Bool {
        guard state == .running else { return false }
        return processor.cancel(correlationID: correlationID)
    }

    private func decrementOutbound() {
        outboundQueued = max(0, outboundQueued - 1)
    }

    /// - Parameter delivered: `true` once `transport.perform` has actually
    ///   succeeded for this effect. Only a delivered effect is popped from
    ///   `pendingOutboundEffects`; an effect that failed to send stays queued
    ///   there so it is replayed after the next successful `reconnect()`.
    private func transportEffectCompleted(_ queuedEffect: RuntimeQueuedTransportEffect, delivered: Bool) {
        if delivered, !pendingOutboundEffects.isEmpty {
            pendingOutboundEffects.removeFirst()
        }
        queuedTransportEffects = max(0, queuedTransportEffects - 1)
        switch queuedEffect {
        case .publish:
            decrementOutbound()
        case let .typedIoPublication(_, token: typedToken):
            decrementOutbound()
            guard typedIoState.completeTransportPublication(typedToken) else { return }
            flushPendingIo(at: typedToken.slot, nowMS: monotonicNowMS())
        case .externalRouteActivated, .externalRouteDeactivated:
            break
        }
    }

    private func installOutboundPump() {
        let outboundPipe = AsyncStream<RuntimeTransportEffectBatch>.makeStream(
            bufferingPolicy: .bufferingOldest(definition.capacities.dispatch)
        )
        outboundContinuation = outboundPipe.continuation
        outboundTask = Task { [weak self, stream = outboundPipe.stream, transport, namespace = definition.namespace] in
            for await batch in stream {
                guard !Task.isCancelled else { break }
                for queuedEffect in batch.effects {
                    guard !Task.isCancelled else { break }
                    do {
                        try await transport.perform(queuedEffect.transportEffect, namespace: namespace)
                        await self?.transportEffectCompleted(queuedEffect, delivered: true)
                    } catch {
                        await self?.transportEffectCompleted(queuedEffect, delivered: false)
                        await self?.transportFailed(runtimeErrorDetail(error))
                        break
                    }
                }
            }
        }
    }

    private func stopOutboundPump() async {
        let task = outboundTask
        outboundContinuation?.finish()
        outboundTask?.cancel()
        outboundContinuation = nil
        outboundTask = nil
        await task?.value
        outboundQueued = 0
        queuedTransportEffects = 0
    }

    private func drainOutboundPump() async {
        let task = outboundTask
        outboundContinuation?.finish()
        outboundContinuation = nil
        outboundTask = nil
        await task?.value
        outboundQueued = 0
        queuedTransportEffects = 0
    }

    func receive(_ frame: RuntimeInboundFrame) -> RuntimeReceipt {
        guard state == .running else {
            return .rejected(.notRunning(state))
        }
        // There is no separate holding queue here: `processInbound` is
        // synchronous, so the only real bound on outstanding inbound work is
        // the `AsyncStream` feeding `receiveTransport(_:epoch:)`
        // (`.bufferingOldest(definition.capacities.ingress)`) together with
        // `RuntimeOverflowGate`; saturation there is reported by
        // `ingressOverflow()`. A frame reaching this method has already
        // cleared that bound and is processed immediately.
        return processInbound(frame)
    }

    func publish(_ operation: RuntimeOperation, nowMS: UInt32) -> RuntimeReceipt {
        if operation.capability == .channel, operation.operationName == nil {
            return .rejected(.invalidOperationName)
        }
        if let operationName = operation.operationName,
           (operation.capability != .call && operation.capability != .channel && operation.capability != .associate)
            || !RuntimeOperationValidation.isValidCallOperation(operationName) {
            return .rejected(.invalidOperationName)
        }
        guard !operation.payload.isEmpty else {
            return .rejected(.malformedPayload)
        }
        if state == .reconnecting {
            guard operation.capability.isOneWay, operation.correlationID == nil else {
                return .rejected(.notRunning(state))
            }
            guard offlineOperations.count < definition.capacities.dispatch else {
                diagnosticsSnapshotValue.dispatchSaturation += 1
                return .rejected(.capacityExceeded)
            }
            offlineOperations.append(operation)
            eventContinuation.yield(.transition(.accepted))
            return .accepted
        }
        guard state == .running else {
            return .rejected(.notRunning(state))
        }
        guard queuedTransportEffects < definition.capacities.dispatch else {
            diagnosticsSnapshotValue.dispatchSaturation += 1
            return .rejected(.capacityExceeded)
        }
        let remainingTransportCapacity = definition.capacities.dispatch - queuedTransportEffects
        let maximumActionCount = operation.capability == .associate
            ? min(definition.capacities.dispatch, remainingTransportCapacity + 1)
            : remainingTransportCapacity
        let outcome = processOutboundOperation(
            operation,
            nowMS: nowMS,
            maximumActionCount: maximumActionCount
        ) {
            dispatchActions(nowMS: nowMS)
        }
        let receipt = receipt(for: outcome)
        eventContinuation.yield(.transition(receipt))
        guard case .accepted = receipt else { return receipt }
        return receipt
    }

    private func flushOfflineOperations(nowMS: UInt32) {
        while let operation = offlineOperations.first {
            let receipt = publish(operation, nowMS: nowMS)
            switch receipt {
            case .accepted:
                offlineOperations.removeFirst()
            case .rejected(.capacityExceeded):
                return
            case let .rejected(rejection):
                offlineOperations.removeFirst()
                emit(.init(kind: .malformedFrame, detail: "offline operation dropped during replay: \(rejection)"))
            case .ignored:
                offlineOperations.removeFirst()
            }
        }
    }

    private func processInbound(_ frame: RuntimeInboundFrame) -> RuntimeReceipt {
        let outcome: ProtocolProcessOutcome
        var parseFailure: String?
        switch frame {
        case .profile(var topic, let payload, let nowMS):
            guard !topic.isEmpty else { return .rejected(.malformedFrame(.malformedFrame)) }
            guard !payload.isEmpty else { return .rejected(.malformedPayload) }
            outcome = topic.withUTF8 { topicBuffer in
                guard let topicBase = topicBuffer.baseAddress else {
                    parseFailure = "topic is empty"
                    return .rejected(.malformedFrame)
                }
                let topicView = TopicView(topicBytes: topicBase, length: topicBuffer.count)
                do throws(WireDecodeError) {
                    try topicView.validate(
                        maximumTopicLength: definition.capacities.protocolMaximumTopicBytes
                    )
                } catch {
                    parseFailure = runtimeErrorDetail(error)
                    return .rejected(.malformedFrame)
                }
                return payload.withUnsafeBufferPointer { payloadBuffer in
                    guard let payloadBase = payloadBuffer.baseAddress else {
                        parseFailure = "payload is empty"
                        return .rejected(.malformedPayload)
                    }
                    do throws(ProtocolError) {
                        let borrowed = try BorrowedProtocolFrame(
                            topic: topicView,
                            payload: ByteSlice(bytes: payloadBase, length: payloadBuffer.count),
                            maximumTopicLength: definition.capacities.protocolMaximumTopicBytes
                        )
                        actionSink.removeAll()
                        let remainingTransportCapacity = definition.capacities.dispatch - queuedTransportEffects
                        let maximumActionCount = borrowed.routingKey.capability == .associate
                            ? min(definition.capacities.dispatch, remainingTransportCapacity + 1)
                            : remainingTransportCapacity
                        actionSink.prepare(maximumActionCount: maximumActionCount)
                        let outcome = processor.processInbound(
                            .profile(borrowed),
                            nowMS: nowMS,
                            classifier: TransportRouteClassifier(transport: transport),
                            maximumTopicLength: definition.capacities.protocolMaximumTopicBytes,
                            sink: &actionSink
                        )
                        if case .accepted = outcome {
                            dispatchActions(nowMS: nowMS)
                        }
                        return outcome
                    } catch {
                        parseFailure = runtimeErrorDetail(error)
                        return .rejected(.malformedFrame)
                    }
                }
            }
        case .externalIo(var route, let payload, let nowMS):
            guard !route.isEmpty,
                  route.utf8.count <= WireBufferConfig.maxTopicLength,
                  payload.count <= WireBufferConfig.maxPayloadSize else {
                return .rejected(.malformedPayload)
            }
            outcome = route.withUTF8 { routeBuffer in
                guard let routeBase = routeBuffer.baseAddress else {
                    return .rejected(.malformedPayload)
                }
                return payload.withUnsafeBufferPointer { payloadBuffer in
                    let payloadSlice = payloadBuffer.baseAddress.map {
                        ByteSlice(bytes: $0, length: payloadBuffer.count)
                    } ?? .empty
                    let routeSlice = ByteSlice(bytes: routeBase, length: routeBuffer.count)
                    actionSink.removeAll()
                    actionSink.prepare(maximumActionCount: definition.capacities.dispatch)
                    let outcome = processor.processInbound(
                        .externalIo(route: routeSlice, payload: payloadSlice),
                        nowMS: nowMS,
                        classifier: TransportRouteClassifier(transport: transport),
                        sink: &actionSink
                    )
                    if case .accepted = outcome {
                        dispatchActions(nowMS: nowMS)
                    }
                    return outcome
                }
            }
        }
        if let parseFailure {
            diagnosticsSnapshotValue.malformedFrames += 1
            emit(.init(kind: .malformedFrame, detail: parseFailure))
        }
        let receipt = receipt(for: outcome)
        eventContinuation.yield(.transition(receipt))
        guard case .accepted = receipt else { return receipt }
        return receipt
    }

    private func dispatchActions(nowMS: UInt32) {
        guard actionSink.count <= definition.capacities.dispatch else {
            emit(.init(kind: .capacityExceeded, detail: "dispatch queue is full"))
            actionSink.removeAll()
            return
        }
        var effects: [RuntimeQueuedTransportEffect] = []
        effects.reserveCapacity(actionSink.count)
        var changedSourceIDs: Set<ObjectID> = []
        var changedActorIDs: Set<ObjectID> = []
        for index in 0..<actionSink.count {
            guard let borrowed = actionSink[index] else { continue }
            let action = borrowed.owned()
            recordConformanceAction(action)
            switch borrowed {
            case .deliver(let delivery):
                emitRegisteredEvents(for: delivery, owned: action, nowMS: nowMS)
                dispatchToHandler(action, operation: operationName(for: delivery))
                dispatchIoActorIfRegistered(action, nowMS: nowMS)
            case .associationChanged(let transition):
                emitRegisteredEvents(for: transition.delivery, owned: action, nowMS: nowMS)
                dispatchToHandler(action, operation: operationName(for: transition.delivery))
                changedSourceIDs.insert(ObjectID(uuid: transition.sourceID))
                changedActorIDs.insert(ObjectID(uuid: transition.actorID))
            case .publish(let publication):
                if publication.isApplicationDelivery,
                   let delivery = syntheticDelivery(for: publication) {
                    emitRegisteredEvents(for: delivery, owned: action, nowMS: nowMS)
                }
                if case .publish(let ownedPublication) = action {
                    if ownedPublication.routingKey.capability == .ioValue,
                       let token = pendingTypedIoToken {
                        effects.append(.typedIoPublication(ownedPublication, token: token))
                        pendingTypedIoToken = nil
                    } else {
                        effects.append(.publish(ownedPublication))
                    }
                }
            case .externalRouteActivated(let transition):
                effects.append(.externalRouteActivated(transition.owned()))
            case .externalRouteDeactivated(let transition):
                effects.append(.externalRouteDeactivated(transition.owned()))
            }
        }
        actionSink.removeAll()
        enqueueTransportEffects(effects)
        notifyIoObservers(sourceIDs: changedSourceIDs, actorIDs: changedActorIDs)
    }

    func emitRegisteredEvents(for delivery: BorrowedProtocolDelivery, owned: OwnedProtocolAction, nowMS: UInt32) {
        let payload: [UInt8]
        switch owned {
        case .deliver(let value): payload = value.payload
        case .publish(let value): payload = value.payload
        case .associationChanged(let value): payload = value.delivery.payload
        case .externalRouteActivated, .externalRouteDeactivated: return
        }
        for registration in eventRegistrations {
            guard matches(registration.selector, delivery: delivery) else { continue }
            let value = RuntimeEventValue(
                family: eventFamily(for: delivery.routingKey.capability),
                context: RuntimeEventContext(
                    sourceID: delivery.routingKey.sourceID,
                    correlationID: delivery.routingKey.correlationID,
                    namespace: definition.namespace,
                    route: delivery.routeClassification,
                    channelIdentifier: channelIdentifier(for: delivery),
                    receiptTimeMS: nowMS,
                    provenance: owned.isPublication ? .local : .transport
                ),
                value: payload
            )
            let result = registration.continuation.yield(value)
            if case .dropped = result {
                diagnosticsSnapshotValue.dispatchSaturation += 1
                emit(.init(kind: .capacityExceeded, detail: "application event stream is full"))
                switch registration.policy {
                case .failAfterDrop, .fail:
                    failRuntime(
                        code: .capacityExceeded,
                        detail: "strict application event stream is full",
                        diagnostic: .capacityExceeded
                    )
                case .dropOldest, .dropNewest, .coalesceLatest:
                    break
                }
            }
        }
    }

    private func matches(_ selector: RuntimeEventSelector, delivery: BorrowedProtocolDelivery) -> Bool {
        switch selector {
        case let .family(family):
            return eventFamily(for: delivery.routingKey.capability) == family
        case let .advertise(objectType):
            guard delivery.routingKey.capability == .advertise else { return false }
            guard let objectType else { return true }
            guard case let .advertiseFilter(filter) = delivery.deliveryKey else { return false }
            return filter.utf8Equals(objectType)
        case let .channel(identifier):
            guard delivery.routingKey.capability == .channel,
                  case let .channel(channel) = delivery.deliveryKey else { return false }
            return channel.utf8Equals(identifier)
        case let .ioActor(actorID):
            guard case let .ioActor(value) = delivery.deliveryKey else { return false }
            return value == actorID
        case let .correlatedResponse(capability, correlationID):
            return delivery.routingKey.capability == capability && delivery.routingKey.correlationID == correlationID
        }
    }
    private func syntheticDelivery(for publication: BorrowedProtocolPublication) -> BorrowedProtocolDelivery? {
        let deliveryKey: BorrowedProtocolDeliveryKey
        let routeClassification: ProtocolRouteClassification
        switch publication.target {
        case .profile(let filter, _):
            routeClassification = .coaty
            switch publication.routingKey.capability {
            case .advertise: deliveryKey = filter.map { .advertiseFilter($0) } ?? .capability(.advertise)
            case .channel: deliveryKey = filter.map { .channel($0) } ?? .capability(.channel)
            default: deliveryKey = .capability(publication.routingKey.capability)
            }
        case .associationRoute(_, let kind):
            routeClassification = kind
            deliveryKey = .capability(publication.routingKey.capability)
        }
        return BorrowedProtocolDelivery(
            routingKey: publication.routingKey,
            deliveryKey: deliveryKey,
            routeClassification: routeClassification,
            topic: nil,
            payload: publication.payload
        )
    }
    private func channelIdentifier(for delivery: BorrowedProtocolDelivery) -> String? {
        guard delivery.routingKey.capability == .channel,
              case let .channel(identifier) = delivery.deliveryKey else { return nil }
        return identifier.withBytes { pointer, length in
            String(decoding: UnsafeBufferPointer(start: pointer.assumingMemoryBound(to: UInt8.self), count: length), as: UTF8.self)
        }
    }
    private func eventFamily(for capability: ProtocolCapability) -> RuntimeEventFamily {
        switch capability {
        case .advertise: return .advertise
        case .deadvertise: return .deadvertise
        case .channel: return .channel
        case .associate: return .associate
        case .ioValue: return .ioValue
        case .discover: return .discover
        case .resolve: return .resolve
        case .query: return .query
        case .retrieve: return .retrieve
        case .update: return .update
        case .complete: return .complete
        case .call: return .call
        case .returnEvent: return .returnEvent
        }
    }
    private func receiveTransport(_ frame: RuntimeInboundFrame, epoch: UInt64) {
        guard epoch == transportEpoch else {
            // A frame from a superseded transport epoch is routine during a
            // reconnect, not capacity exhaustion -- keep it out of the
            // capacity/saturation signal.
            emit(.init(kind: .staleTransportFrame, detail: "stale transport frame ignored"))
            return
        }
        _ = receive(frame)
    }

    private func operationName(for delivery: BorrowedProtocolDelivery) -> String? {
        guard delivery.routingKey.capability == .call, let topic = delivery.topic else { return nil }
        return topic.withBytes { pointer, length in
            let view = TopicView(topicBytes: pointer.assumingMemoryBound(to: UInt8.self), length: length)
            guard let filter = view.eventTypeFilter else { return nil }
            return filter.withBytes { filterPointer, filterLength in
                String(decoding: UnsafeBufferPointer(
                    start: filterPointer.assumingMemoryBound(to: UInt8.self),
                    count: filterLength
                ), as: UTF8.self)
            }
        }
    }

    private func enqueueTransportEffects(_ effects: [RuntimeQueuedTransportEffect]) {
        guard !effects.isEmpty else { return }
        // `pendingOutboundEffects` mirrors `queuedTransportEffects`, and
        // every caller of this method already bounds that count to
        // `definition.capacities.dispatch` before reaching here, so this
        // branch is not expected to fire in current call graphs. It stays as
        // an explicit, deterministic shed-and-fail rather than letting
        // retained outbound state grow past the dispatch capacity if a
        // future caller changes that invariant.
        guard pendingOutboundEffects.count + effects.count <= definition.capacities.dispatch else {
            diagnosticsSnapshotValue.dispatchSaturation += 1
            emit(.init(kind: .capacityExceeded, detail: "outbound retention queue is full"))
            failRuntime(
                code: .capacityExceeded,
                detail: "outbound retention queue is full",
                diagnostic: .capacityExceeded
            )
            return
        }
        queuedTransportEffects += effects.count
        outboundQueued += effects.reduce(into: 0) { count, effect in
            if case .publish = effect { count += 1 }
            if case .typedIoPublication = effect { count += 1 }
        }
        let result = outboundContinuation?.yield(RuntimeTransportEffectBatch(effects: effects))
        if case .dropped = result {
            queuedTransportEffects = max(0, queuedTransportEffects - effects.count)
            outboundQueued = max(0, outboundQueued - effects.reduce(into: 0) { count, effect in
                if case .publish = effect { count += 1 }
                if case .typedIoPublication = effect { count += 1 }
            })
            diagnosticsSnapshotValue.dispatchSaturation += 1
            emit(.init(kind: .capacityExceeded, detail: "outbound dispatch queue is full"))
            failRuntime(
                code: .capacityExceeded,
                detail: "outbound dispatch queue is full",
                diagnostic: .capacityExceeded
            )
            return
        }
        pendingOutboundEffects.append(contentsOf: effects)
    }

    /// Re-enqueues effects that were queued-but-unsent when the transport
    /// last failed, in publication order, after a successful reconnect.
    /// Called before `flushOfflineOperations(nowMS:)` so already-accepted
    /// work is replayed ahead of operations accepted while reconnecting.
    private func replayQueuedOutboundEffects() {
        guard !pendingOutboundEffects.isEmpty else { return }
        let effects = pendingOutboundEffects
        pendingOutboundEffects.removeAll(keepingCapacity: true)
        enqueueTransportEffects(effects)
    }

    private func enqueueLifecycleOperation(_ operation: RuntimeOperation, nowMS: UInt32) throws {
        let availableCapacity = max(0, definition.capacities.dispatch - queuedTransportEffects)
        var effects: [RuntimeQueuedTransportEffect] = []
        let outcome = processOutboundOperation(
            operation,
            nowMS: nowMS,
            maximumActionCount: availableCapacity
        ) {
            effects.reserveCapacity(actionSink.count)
            for index in 0..<actionSink.count {
                guard let action = actionSink[index] else { continue }
                switch action {
                case .publish(let publication):
                    effects.append(.publish(publication.owned()))
                case .externalRouteActivated(let transition):
                    effects.append(.externalRouteActivated(transition.owned()))
                case .externalRouteDeactivated(let transition):
                    effects.append(.externalRouteDeactivated(transition.owned()))
                case .deliver, .associationChanged:
                    break
                }
            }
            actionSink.removeAll()
        }
        guard case .accepted = outcome else {
            throw AxolotyError.runtime(
                code: .brokerUnavailable,
                reason: "lifecycle operation rejected by protocol: \(outcome)"
            )
        }
        enqueueTransportEffects(effects)
    }

    private func enqueueIoDeadvertisements(nowMS: UInt32) throws {
        for endpoint in typedIoState.endpointRegistrations {
            let payload = RuntimeLifecyclePayload.deadvertise(objectID: endpoint.id)
            try enqueueLifecycleOperation(
                .deadvertise(sourceID: endpoint.id.uuid, payload: payload),
                nowMS: nowMS
            )
        }
    }

    private func enqueueLifecycleDeadvertisement(nowMS: UInt32) throws {
        guard lifecycleAdvertisementActive, let identity = definition.identity else { return }
        let operation = RuntimeOperation.deadvertise(
            sourceID: identity.id,
            payload: RuntimeLifecyclePayload.deadvertise(identity)
        )
        try enqueueLifecycleOperation(operation, nowMS: nowMS)
        lifecycleAdvertisementActive = false
    }

    private func cancelIngressPump() {
        transportIngressContinuation?.finish()
        transportIngressContinuation = nil
        transportIngressTask?.cancel()
        transportIngressTask = nil
    }

    private func transportFailed(_ detail: String) {
        diagnosticsSnapshotValue.transportFailures += 1
        guard state == .running || state == .reconnecting || state == .starting else { return }
        emit(.init(kind: .transportFailed, detail: detail))
        // Established-connection loss is recoverable transport state, not a
        // terminal runtime failure.  Leave the executor in an explicit
        // reconnecting state so the caller can restore the network path and
        // invoke `reconnect()` without losing the immutable definition.
        guard state == .running else { return }
        state = .reconnecting
        transportEpoch &+= 1
        processor.resetTransport()
        clearIoTransportState()
        diagnosticsSnapshotValue.reconnects += 1
        transportIngressContinuation?.finish()
        transportIngressTask?.cancel()
        transportIngressContinuation = nil
        transportIngressTask = nil
        outboundContinuation?.finish()
        outboundTask?.cancel()
        outboundContinuation = nil
        outboundTask = nil
        outboundQueued = 0
        queuedTransportEffects = 0
    }

    func failRuntime(
        code: AxolotyError.RuntimeErrorCode,
        detail: String,
        diagnostic: RuntimeDiagnostic.Kind
    ) {
        if terminalFailureValue == nil {
            terminalFailureValue = (code, detail)
        }
        emit(.init(kind: diagnostic, detail: detail))
        guard state != .stopping, state != .stopped, state != .closed else { return }
        state = .failed
        transportEpoch &+= 1
        cancelIngressPump()
        outboundContinuation?.finish()
        guard !failureTeardownScheduled else { return }
        failureTeardownScheduled = true
        Task { [weak self] in
            await self?.stop()
        }
    }

    func emit(_ diagnostic: RuntimeDiagnostic) {
        diagnosticContinuation.yield(diagnostic)
    }

    /// Appends one copied action for ``conformanceObservation()``, bounded by
    /// `definition.capacities.dispatch` so a production runtime that never
    /// drains the conformance SPI cannot grow this buffer without bound.
    private func recordConformanceAction(_ action: OwnedProtocolAction) {
        if conformanceActions.count >= definition.capacities.dispatch {
            conformanceActions.removeFirst()
        }
        conformanceActions.append(action)
    }

}
