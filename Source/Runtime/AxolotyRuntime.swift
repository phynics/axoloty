// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyProtocol
import AxolotyWire
import Foundation

/// Host runtime facade backed by one private protocol executor.
///
/// The executor owns the only mutable ``ProtocolProcessor`` instance. Inbound
/// transport data is copied before it enters the actor, and normalized actions
/// are copied before they are dispatched to application handlers.
public final class AxolotyRuntime: Sendable {
    private let executor: ProtocolExecutor

    /// Creates a stopped runtime from an immutable definition.
    public init(definition: SealedRuntimeDefinition, transport: AxolotyRuntimeTransport) {
        self.executor = ProtocolExecutor(definition: definition, transport: transport)
    }

    /// Starts the runtime transport and protocol executor.
    public func start() async throws {
        if let failure = await executor.start() {
            throw AxolotyError.runtime(code: failure.0, reason: failure.1)
        }
    }

    /// Runs the runtime until a caller invokes ``stop()``. The transport
    /// remains owned by the runtime for the duration of this call.
    public func run() async throws {
        try await start()
        do {
            while true {
                switch await lifecycleState() {
                case .running, .starting, .reconnecting, .stopping:
                    try await Task.sleep(for: .milliseconds(25))
                case .failed:
                    let failure = await executor.terminalFailure()
                    await stop()
                    if let failure {
                        throw AxolotyError.runtime(code: failure.0, reason: failure.1)
                    }
                    return
                case .stopped, .closed:
                    if let failure = await executor.terminalFailure() {
                        throw AxolotyError.runtime(code: failure.0, reason: failure.1)
                    }
                    return
                }
            }
        } catch is CancellationError {
            await stop()
        } catch {
            await stop()
            throw error
        }
    }

    /// Stops the runtime. Stopping is idempotent.
    public func stop() async {
        await executor.stop()
    }

    /// Permanently closes the runtime and finishes its streams.
    public func close() async {
        await executor.close()
    }

    /// Advances the transport epoch and clears transport-scoped pending work.
    public func reconnect() async {
        await executor.reconnect()
    }

    /// Returns the current lifecycle state.
    public func lifecycleState() async -> RuntimeLifecycleState {
        await executor.lifecycleState()
    }

    /// Returns the modern lifecycle spelling used by G4 callers.
    public func state() async -> RuntimeState {
        await executor.runtimeState()
    }

    /// Submits one owned inbound frame to the bounded ingress queue.
    public func receive(_ frame: RuntimeInboundFrame) async -> RuntimeReceipt {
        await executor.receive(frame)
    }

    /// Submits one owned local operation to ``ProtocolProcessor``.
    public func publish(_ operation: RuntimeOperation, nowMS: UInt32? = nil) async -> RuntimeReceipt {
        await executor.publish(operation, nowMS: nowMS ?? monotonicNowMS())
    }

    /// Publishes a closed one-way operation through the shared processor.
    public func publish(_ operation: RuntimeOneWayOperation, nowMS: UInt32? = nil) async -> RuntimeReceipt {
        await publish(RuntimeOperation(oneWay: operation, sourceID: await executor.sourceID()), nowMS: nowMS)
    }

    /// Starts a bounded request correlation through the shared processor.
    public func request(_ request: RuntimeRequest, nowMS: UInt32? = nil) async -> RuntimeReceipt {
        await publish(RuntimeOperation(request: request, sourceID: await executor.sourceID()), nowMS: nowMS)
    }

    /// Publishes a responder response through the shared processor.
    public func respond(_ response: RuntimeResponse, nowMS: UInt32? = nil) async -> RuntimeReceipt {
        await publish(RuntimeOperation(response: response, sourceID: await executor.sourceID()), nowMS: nowMS)
    }

    /// Expires request correlations using caller-supplied monotonic time.
    @discardableResult
    public func expire(nowMS: UInt32) async -> Bool {
        await executor.expire(nowMS: nowMS)
    }

    /// Cancels one request correlation before it reaches the wire.
    @discardableResult
    public func cancel(correlationID: UUID16) async -> Bool {
        await executor.cancel(correlationID: correlationID)
    }

    /// Returns the bounded runtime event stream.
    public func events() async -> AsyncStream<RuntimeEvent> {
        await executor.events()
    }

    /// Returns the bounded supervision diagnostic stream.
    public func diagnostics() async -> AsyncStream<RuntimeDiagnostic> {
        await executor.diagnostics()
    }

    /// Returns coalesced supervision counters without exposing transport state.
    public func diagnosticsSnapshot() async -> RuntimeDiagnostics {
        await executor.diagnosticsSnapshot()
    }
}

// The executor deliberately keeps lifecycle, ingress, dispatch, and handler
// supervision in one serialized owner. Keep this suppression scoped to the
// owner rather than weakening the repository-wide type-size rule.
// swiftlint:disable:next type_body_length
private actor ProtocolExecutor {
    private let definition: SealedRuntimeDefinition
    private let transport: AxolotyRuntimeTransport
    private var processor = ProtocolProcessor<64>()
    private var actionSink = ReusableProtocolActionSink(capacity: 64)
    /// One-way operations accepted while the transport is reconnecting.
    /// This queue is bounded by the dispatch capacity and is replayed in
    /// publication order after a successful reconnect.
    private var offlineOperations: [RuntimeOperation] = []
    private var state: RuntimeLifecycleState = .stopped
    private var hasStarted = false
    private var ingress: [RuntimeInboundFrame] = []
    private var activeHandlers = 0
    private var handlerInFlight: [Int: Int] = [:]
    private var nextHandlerID: UInt64 = 1
    private var handlerTasks: [UInt64: Task<Void, Never>] = [:]
    private var terminalFailureValue: (AxolotyError.RuntimeErrorCode, String)?
    private var failureTeardownScheduled = false
    private let ingressOverflowGate = RuntimeOverflowGate()
    private var transportEpoch: UInt64 = 0
    private var transportIngressContinuation: AsyncStream<RuntimeInboundFrame>.Continuation?
    private var transportIngressTask: Task<Void, Never>?
    private var outboundContinuation: AsyncStream<OwnedProtocolAction>.Continuation?
    private var outboundTask: Task<Void, Never>?
    private var outboundQueued = 0
    private var diagnosticsSnapshotValue = RuntimeDiagnostics()
    private let eventRegistrations: [RuntimeEventRegistration]

    private let eventStream: AsyncStream<RuntimeEvent>
    private let eventContinuation: AsyncStream<RuntimeEvent>.Continuation
    private let diagnosticStream: AsyncStream<RuntimeDiagnostic>
    private let diagnosticContinuation: AsyncStream<RuntimeDiagnostic>.Continuation

    init(definition: SealedRuntimeDefinition, transport: AxolotyRuntimeTransport) {
        self.definition = definition
        self.transport = transport
        self.eventRegistrations = definition.eventRegistrations
        self.ingress.reserveCapacity(definition.capacities.ingress)
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
            try await transport.advertise(identity: definition.identity, namespace: definition.namespace)
            guard state == .starting, transportEpoch == epoch else {
                await transport.stop()
                return (.notStarted, "runtime start was superseded during advertisement")
            }
            state = .running
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
        state = .stopping
        offlineOperations.removeAll(keepingCapacity: true)
        transportEpoch &+= 1
        let stoppingEpoch = transportEpoch
        await cancelAndDrainHandlers()
        do {
            try await transport.deadvertise(identity: definition.identity, namespace: definition.namespace)
            try await transport.removeSubscriptions(namespace: definition.namespace)
        } catch {
            emit(.init(kind: .transportFailed, detail: runtimeErrorDetail(error)))
        }
        await transport.stop()
        guard state == .stopping, transportEpoch == stoppingEpoch else { return }
        cancelIngressPump()
        await stopOutboundPump()
        state = .stopped
    }

    func close() async {
        guard state != .closed else { return }
        if state == .running || state == .starting || state == .reconnecting || state == .failed {
            await stop()
        }
        state = .closed
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
            // A broker-side close can race this explicit reconnect.  The
            // binding may therefore already have lost its subscription
            // session; removal is best-effort in that path and a fresh
            // subscription installation below is authoritative.
            try? await transport.removeSubscriptions(namespace: definition.namespace)
            await transport.stop()
            // Stop the socket before awaiting the old pump. A transport send
            // is allowed to suspend until the socket closes; draining first
            // would make reconnect dependent on an unbounded cancellation
            // guarantee that the transport protocol does not provide.
            await stopOutboundPump()
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
            try await transport.advertise(identity: definition.identity, namespace: definition.namespace)
            guard state == .reconnecting, transportEpoch == epoch else { return }
            state = .running
            flushOfflineOperations(nowMS: monotonicNowMS())
        } catch {
            guard state == .reconnecting, transportEpoch == epoch else { return }
            failRuntime(
                code: .brokerUnavailable,
                detail: runtimeErrorDetail(error),
                diagnostic: .transportFailed
            )
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

    private func installOutboundPump() {
        let outboundPipe = AsyncStream<OwnedProtocolAction>.makeStream(
            bufferingPolicy: .bufferingOldest(definition.capacities.dispatch)
        )
        outboundContinuation = outboundPipe.continuation
        outboundTask = Task { [weak self, stream = outboundPipe.stream, transport, namespace = definition.namespace] in
            for await action in stream {
                guard !Task.isCancelled else { break }
                await self?.decrementOutbound()
                do {
                    try await transport.send(action, namespace: namespace)
                } catch {
                    await self?.transportFailed(runtimeErrorDetail(error))
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
        outboundQueued = 0
        await task?.value
    }

    func receive(_ frame: RuntimeInboundFrame) -> RuntimeReceipt {
        guard state == .running else {
            return .rejected(.notRunning(state))
        }
        guard ingress.count < definition.capacities.ingress else {
            diagnosticsSnapshotValue.ingressSaturation += 1
            emit(.init(kind: .capacityExceeded, detail: "inbound frame queue is full"))
            return .rejected(.capacityExceeded)
        }
        ingress.append(frame)
        let next = ingress.removeFirst()
        return processInbound(next)
    }

    func publish(_ operation: RuntimeOperation, nowMS: UInt32) -> RuntimeReceipt {
        if let operationName = operation.operationName,
           operation.capability != .call || !RuntimeOperationValidation.isValidCallOperation(operationName) {
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
        guard outboundQueued < definition.capacities.dispatch else {
            diagnosticsSnapshotValue.dispatchSaturation += 1
            return .rejected(.capacityExceeded)
        }
        let operationNameBytes: [UInt8] = operation.operationName.map { Array($0.utf8) } ?? []
        let outcome: ProtocolProcessOutcome = operation.payload.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return .rejected(.malformedPayload) }
            let payload = ByteSlice(bytes: base, length: buffer.count)
            return operationNameBytes.withUnsafeBufferPointer { operationBuffer in
                let operationName = operationBuffer.baseAddress.map {
                    ByteSlice(bytes: $0, length: operationBuffer.count)
                }
                guard let local = try? ProtocolLocalOperation(
                    capability: operation.capability,
                    sourceID: operation.sourceID,
                    correlationID: operation.correlationID,
                    payload: payload,
                    requestTimeoutMS: operation.requestTimeoutMS,
                    operationName: operationName
                ) else {
                    return .rejected(.invalidCorrelation)
                }
                actionSink.removeAll()
                let outcome = processor.processOutbound(
                    local,
                    nowMS: nowMS,
                    classifier: TransportRouteClassifier(transport: transport),
                    sink: &actionSink
                )
                // The processor emits borrowed action views into `operation.payload`.
                // Drain them before this buffer borrow ends; only owned values may
                // escape the closure into runtime queues or application streams.
                if case .accepted = outcome {
                    dispatchActions(nowMS: nowMS)
                }
                return outcome
            }
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
        guard !frame.topic.isEmpty else { return .rejected(.malformedFrame(.malformedFrame)) }
        guard !frame.payload.isEmpty else { return .rejected(.malformedPayload) }

        var parseFailure: String?
        var topic = frame.topic
        let outcome: ProtocolProcessOutcome = topic.withUTF8 { topicBuffer in
            guard let topicBase = topicBuffer.baseAddress else {
                parseFailure = "topic is empty"
                return .rejected(.malformedFrame)
            }
            let topicView = TopicView(topicBytes: topicBase, length: topicBuffer.count)
            do throws(WireDecodeError) {
                try topicView.validate()
            } catch {
                parseFailure = runtimeErrorDetail(error)
                return .rejected(.malformedFrame)
            }
            return frame.payload.withUnsafeBufferPointer { payloadBuffer in
                guard let payloadBase = payloadBuffer.baseAddress else {
                    parseFailure = "payload is empty"
                    return .rejected(.malformedPayload)
                }
                do throws(ProtocolError) {
                    let borrowed = try BorrowedProtocolFrame(
                        topic: topicView,
                        payload: ByteSlice(bytes: payloadBase, length: payloadBuffer.count)
                    )
                    actionSink.removeAll()
                    let outcome = processor.processInbound(
                        borrowed,
                        nowMS: frame.nowMS,
                        classifier: TransportRouteClassifier(transport: transport),
                        sink: &actionSink
                    )
                    // The processor's delivery key, topic, and payload are
                    // borrowed from this frame. Dispatch synchronously while
                    // both topic and payload buffers remain valid.
                    if case .accepted = outcome {
                        dispatchActions(nowMS: frame.nowMS)
                    }
                    return outcome
                } catch {
                    parseFailure = runtimeErrorDetail(error)
                    return .rejected(.malformedFrame)
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
        for index in 0..<actionSink.count {
            guard let borrowed = actionSink[index] else { continue }
            let action = borrowed.owned()
            emitRegisteredEvents(for: borrowed, owned: action, nowMS: nowMS)
            switch action.kind {
            case .publish:
                enqueueOutbound(action)
            case .deliver, .associate, .disassociate:
                dispatchToHandler(action, operation: operationName(for: borrowed))
            }
        }
        actionSink.removeAll()
    }

    private func emitRegisteredEvents(for borrowed: BorrowedProtocolAction, owned: OwnedProtocolAction, nowMS: UInt32) {
        for registration in eventRegistrations {
            guard matches(registration.selector, action: borrowed) else { continue }
            let value = RuntimeEventValue(
                family: eventFamily(for: borrowed.routingKey.capability),
                context: RuntimeEventContext(
                    sourceID: borrowed.routingKey.sourceID,
                    correlationID: borrowed.routingKey.correlationID,
                    namespace: definition.namespace,
                    route: borrowed.routeClassification,
                    receiptTimeMS: nowMS,
                    provenance: borrowed.kind == .publish ? .local : .transport
                ),
                value: owned.payload
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

    private func matches(_ selector: RuntimeEventSelector, action: BorrowedProtocolAction) -> Bool {
        switch selector {
        case let .family(family):
            return eventFamily(for: action.routingKey.capability) == family
        case let .advertise(objectType):
            guard action.routingKey.capability == .advertise else { return false }
            guard let objectType else { return true }
            guard case let .advertiseFilter(filter) = action.deliveryKey else { return false }
            return filter.utf8Equals(objectType)
        case let .channel(identifier):
            guard action.routingKey.capability == .channel,
                  case let .channel(channel) = action.deliveryKey else { return false }
            return channel.utf8Equals(identifier)
        case let .ioActor(actorID):
            guard case let .ioActor(value) = action.deliveryKey else { return false }
            return value == actorID
        case let .correlatedResponse(capability, correlationID):
            return action.routingKey.capability == capability && action.routingKey.correlationID == correlationID
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
            emit(.init(kind: .capacityExceeded, detail: "stale transport frame ignored"))
            return
        }
        _ = receive(frame)
    }

    private func dispatchToHandler(_ action: OwnedProtocolAction, operation: String?) {
        guard let match = definition.registrations.enumerated().first(where: {
            guard $0.element.capability == action.kindCapability else { return false }
            return $0.element.operation == nil || $0.element.operation == operation
        }) else {
            return
        }
        let registrationIndex = match.offset
        let registration = match.element
        guard activeHandlers < definition.capacities.handlersInFlight else {
            diagnosticsSnapshotValue.handlerSaturation += 1
            emit(.init(kind: .capacityExceeded, detail: "handler supervision capacity is full"))
            return
        }
        guard handlerInFlight[registrationIndex, default: 0] < registration.maximumConcurrentInvocations else {
            diagnosticsSnapshotValue.handlerSaturation += 1
            emit(.init(kind: .capacityExceeded, detail: "handler registration concurrency is full"))
            return
        }
        activeHandlers += 1
        handlerInFlight[registrationIndex, default: 0] += 1
        let handlerID = nextHandlerID
        nextHandlerID &+= 1
        let invocation = RuntimeInvocation(
            action: action,
            operation: operation,
            registrationIndex: registrationIndex,
            handlerID: handlerID
        )
        eventContinuation.yield(.invocation(invocation))
        let task = Task { [weak self] in
            do {
                let result = try await registration.handler(invocation)
                guard !Task.isCancelled else {
                    await self?.handlerCancelled(invocation)
                    return
                }
                await self?.complete(invocation: invocation, result: result)
            } catch is CancellationError {
                await self?.handlerCancelled(invocation)
            } catch {
                await self?.handlerFailed(
                    runtimeErrorDetail(error),
                    registrationIndex: registrationIndex
                )
            }
            await self?.handlerTaskFinished(handlerID)
        }
        handlerTasks[handlerID] = task
    }

    private func complete(invocation: RuntimeInvocation, result: RuntimeHandlerResult) {
        activeHandlers = max(0, activeHandlers - 1)
        decrementHandler(registrationIndex: invocation.registrationIndex)
        guard let correlation = invocation.action.routingKey.correlationID else { return }
        let responseCapability: ProtocolCapability
        switch invocation.action.routingKey.capability {
        case .discover: responseCapability = .resolve
        case .query: responseCapability = .retrieve
        case .update: responseCapability = .complete
        case .call: responseCapability = .returnEvent
        default:
            emit(.init(kind: .handlerFailed, detail: "handler completion is not a request family"))
            return
        }
        guard case let .response(payload) = result else {
            if case let .remoteError(code, message) = result {
                guard let payload = makeErrorResponsePayload(
                    capability: responseCapability,
                    code: code,
                    message: message
                ) else {
                    emit(.init(kind: .handlerFailed, detail: "remote error could not be encoded"))
                    return
                }
                _ = publish(
                    RuntimeOperation(
                        capability: responseCapability,
                        sourceID: definition.sourceID,
                        correlationID: correlation,
                        payload: payload
                    ),
                    nowMS: 0
                )
            }
            return
        }
        _ = publish(
            RuntimeOperation(
                capability: responseCapability,
                sourceID: definition.sourceID,
                correlationID: correlation,
                payload: payload
            ),
            nowMS: 0
        )
    }

    private func handlerFailed(_ detail: String, registrationIndex: Int = -1) {
        activeHandlers = max(0, activeHandlers - 1)
        decrementHandler(registrationIndex: registrationIndex)
        emit(.init(kind: .handlerFailed, detail: detail))
    }

    private func handlerCancelled(_ invocation: RuntimeInvocation) {
        activeHandlers = max(0, activeHandlers - 1)
        decrementHandler(registrationIndex: invocation.registrationIndex)
    }

    private func handlerTaskFinished(_ handlerID: UInt64) {
        handlerTasks.removeValue(forKey: handlerID)
    }

    private func cancelAndDrainHandlers() async {
        let tasks = Array(handlerTasks.values)
        handlerTasks.removeAll(keepingCapacity: true)
        for task in tasks { task.cancel() }
        for task in tasks { _ = await task.value }
        activeHandlers = 0
        handlerInFlight.removeAll(keepingCapacity: true)
    }

    private func decrementHandler(registrationIndex: Int) {
        guard registrationIndex >= 0 else { return }
        let remaining = max(0, handlerInFlight[registrationIndex, default: 0] - 1)
        if remaining == 0 {
            handlerInFlight.removeValue(forKey: registrationIndex)
        } else {
            handlerInFlight[registrationIndex] = remaining
        }
    }

    /// Extracts a binding-owned Call operation while the action still borrows
    /// the transport topic. The resulting string is copied before the handler
    /// task crosses the actor boundary.
    private func operationName(for action: BorrowedProtocolAction) -> String? {
        guard action.routingKey.capability == .call, let topic = action.topic else { return nil }
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

    /// Encodes a structured handler failure through the response family codec.
    /// The Core profile has no common error envelope, so request families use
    /// their optional private-data field while Return uses its canonical error
    /// field. This keeps the response wire shape valid for every family.
    private func makeErrorResponsePayload(
        capability: ProtocolCapability,
        code: UInt16,
        message: String
    ) -> [UInt8]? {
        guard let error = try? JSONSerialization.data(
            withJSONObject: ["code": code, "message": message],
            options: [.sortedKeys]
        ) else { return nil }
        let errorBytes = Array(error)
        let event: OwnedWireEvent?
        switch capability {
        case .resolve:
            event = try? .resolve(OwnedResolveWireData(object: Array("{}".utf8), relatedObjects: nil, privateData: errorBytes))
        case .retrieve:
            event = try? .retrieve(OwnedRetrieveWireData(objects: Array("[]".utf8), privateData: errorBytes))
        case .complete:
            event = try? .complete(OwnedCompleteWireData(object: nil, privateData: errorBytes))
        case .returnEvent:
            event = try? .returnEvent(OwnedReturnWireData(result: nil, executionInfo: nil, error: errorBytes))
        default:
            event = nil
        }
        guard let event else { return nil }

        var output = [UInt8](repeating: 0, count: 1024)
        guard let length = output.withUnsafeMutableBufferPointer({ buffer -> Int? in
            guard let baseAddress = buffer.baseAddress else { return nil }
            var writer = WireWriter(buffer: baseAddress, capacity: buffer.count)
            guard (try? event.encode(to: &writer)) != nil else { return nil }
            return writer.position
        }) else { return nil }
        output.removeSubrange(length..<output.count)
        return output
    }

    private func enqueueOutbound(_ action: OwnedProtocolAction) {
        outboundQueued += 1
        let result = outboundContinuation?.yield(action)
        if case .dropped = result {
            outboundQueued = max(0, outboundQueued - 1)
            diagnosticsSnapshotValue.dispatchSaturation += 1
            emit(.init(kind: .capacityExceeded, detail: "outbound dispatch queue is full"))
            failRuntime(
                code: .capacityExceeded,
                detail: "outbound dispatch queue is full",
                diagnostic: .capacityExceeded
            )
        }
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
    }

    private func failRuntime(
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

    private func emit(_ diagnostic: RuntimeDiagnostic) {
        diagnosticContinuation.yield(diagnostic)
    }

    private func receipt(for outcome: ProtocolProcessOutcome) -> RuntimeReceipt {
        switch outcome {
        case .accepted: return .accepted
        case .ignored: return .ignored
        case let .rejected(code): return .rejected(.protocol(code))
        }
    }
}
