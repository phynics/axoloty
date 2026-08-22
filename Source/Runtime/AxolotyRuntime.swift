// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyProtocol
import AxolotyWire

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
        while await lifecycleState() == .running {
            await Task.yield()
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
        switch await lifecycleState() {
        case .stopped: return .stopped
        case .starting: return .starting
        case .running: return .running
        case .stopping: return .stopping
        case .failed, .closed: return .failed
        }
    }

    /// Submits one owned inbound frame to the bounded ingress queue.
    public func receive(_ frame: RuntimeInboundFrame) async -> RuntimeReceipt {
        await executor.receive(frame)
    }

    /// Submits one owned local operation to ``ProtocolProcessor``.
    public func publish(_ operation: RuntimeOperation, nowMS: UInt32 = 0) async -> RuntimeReceipt {
        await executor.publish(operation, nowMS: nowMS)
    }

    /// Publishes a closed one-way operation through the shared processor.
    public func publish(_ operation: RuntimeOneWayOperation, nowMS: UInt32 = 0) async -> RuntimeReceipt {
        await publish(RuntimeOperation(oneWay: operation, sourceID: await executor.sourceID()), nowMS: nowMS)
    }

    /// Starts a bounded request correlation through the shared processor.
    public func request(_ request: RuntimeRequest, nowMS: UInt32 = 0) async -> RuntimeReceipt {
        await publish(RuntimeOperation(request: request, sourceID: await executor.sourceID()), nowMS: nowMS)
    }

    /// Publishes a responder response through the shared processor.
    public func respond(_ response: RuntimeResponse, nowMS: UInt32 = 0) async -> RuntimeReceipt {
        await publish(RuntimeOperation(response: response, sourceID: await executor.sourceID()), nowMS: nowMS)
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

private actor ProtocolExecutor {
    private let definition: SealedRuntimeDefinition
    private let transport: AxolotyRuntimeTransport
    private var processor = ProtocolProcessor<64>()
    private var actionSink = ReusableProtocolActionSink(capacity: 64)
    private var state: RuntimeLifecycleState = .stopped
    private var hasStarted = false
    private var ingress: [RuntimeInboundFrame] = []
    private var activeHandlers = 0
    private var transportEpoch: UInt64 = 0
    private var transportIngressContinuation: AsyncStream<RuntimeInboundFrame>.Continuation?
    private var transportIngressTask: Task<Void, Never>?
    private var outboundContinuation: AsyncStream<OwnedProtocolAction>.Continuation?
    private var outboundTask: Task<Void, Never>?
    private var diagnosticsSnapshotValue = RuntimeDiagnostics()

    private let eventStream: AsyncStream<RuntimeEvent>
    private let eventContinuation: AsyncStream<RuntimeEvent>.Continuation
    private let diagnosticStream: AsyncStream<RuntimeDiagnostic>
    private let diagnosticContinuation: AsyncStream<RuntimeDiagnostic>.Continuation

    init(definition: SealedRuntimeDefinition, transport: AxolotyRuntimeTransport) {
        self.definition = definition
        self.transport = transport
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
        case .starting, .stopping:
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
            bufferingPolicy: .bufferingNewest(definition.capacities.ingress)
        )
        transportIngressContinuation = ingressPipe.continuation
        transportIngressTask = Task { [weak self, stream = ingressPipe.stream] in
            for await frame in stream {
                guard !Task.isCancelled else { break }
                await self?.receiveTransport(frame, epoch: epoch)
            }
        }
        let outboundPipe = AsyncStream<OwnedProtocolAction>.makeStream(
            bufferingPolicy: .bufferingNewest(definition.capacities.dispatch)
        )
        outboundContinuation = outboundPipe.continuation
        outboundTask = Task { [weak self, stream = outboundPipe.stream, transport, namespace = definition.namespace] in
            for await action in stream {
                guard !Task.isCancelled else { break }
                do {
                    try await transport.send(action, namespace: namespace)
                } catch {
                    await self?.transportFailed(String(describing: error))
                }
            }
        }
        do {
            try await transport.start { [continuation = ingressPipe.continuation] frame in
                continuation.yield(frame)
            }
            state = .running
            return nil
        } catch {
            cancelTransportPumps()
            state = .failed
            return (.brokerUnavailable, String(describing: error))
        }
    }

    func stop() async {
        guard state == .running || state == .starting || state == .failed else { return }
        state = .stopping
        transportEpoch &+= 1
        await transport.stop()
        cancelTransportPumps()
        state = .stopped
    }

    func close() async {
        guard state != .closed else { return }
        if state == .running || state == .starting || state == .failed {
            await stop()
        }
        state = .closed
        eventContinuation.finish()
        diagnosticContinuation.finish()
    }

    func reconnect() async {
        guard state == .running else { return }
        state = .reconnecting
        transportEpoch &+= 1
        processor.resetTransport()
        diagnosticsSnapshotValue.reconnects += 1
        state = .running
    }

    func lifecycleState() -> RuntimeLifecycleState { state }

    func sourceID() -> UUID16 { definition.sourceID }

    func events() -> AsyncStream<RuntimeEvent> { eventStream }

    func diagnostics() -> AsyncStream<RuntimeDiagnostic> { diagnosticStream }

    func diagnosticsSnapshot() -> RuntimeDiagnostics { diagnosticsSnapshotValue }

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
        guard state == .running else {
            return .rejected(.notRunning(state))
        }
        guard !operation.payload.isEmpty else {
            return .rejected(.malformedPayload)
        }
        let outcome: ProtocolProcessOutcome = operation.payload.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return .rejected(.malformedPayload) }
            let payload = ByteSlice(bytes: base, length: buffer.count)
            guard let local = try? ProtocolLocalOperation(
                capability: operation.capability,
                sourceID: operation.sourceID,
                correlationID: operation.correlationID,
                payload: payload,
                requestTimeoutMS: operation.requestTimeoutMS
            ) else {
                return .rejected(.invalidCorrelation)
            }
            actionSink.removeAll()
            return processor.processOutbound(local, nowMS: nowMS, sink: &actionSink)
        }
        let receipt = receipt(for: outcome)
        eventContinuation.yield(.transition(receipt))
        guard case .accepted = receipt else { return receipt }
        dispatchActions()
        return receipt
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
                parseFailure = String(describing: error)
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
                    return processor.processInbound(
                        borrowed,
                        nowMS: frame.nowMS,
                        classifier: ExactProtocolRouteClassifier(externalRoute: "external/wire-compat-v1/io-external-1"),
                        sink: &actionSink
                    )
                } catch {
                    parseFailure = String(describing: error)
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
        dispatchActions()
        return receipt
    }

    private func dispatchActions() {
        guard actionSink.count <= definition.capacities.dispatch else {
            emit(.init(kind: .capacityExceeded, detail: "dispatch queue is full"))
            actionSink.removeAll()
            return
        }
        for index in 0..<actionSink.count {
            guard let borrowed = actionSink[index] else { continue }
            let action = borrowed.owned()
            switch action.kind {
            case .publish:
                enqueueOutbound(action)
            case .deliver, .associate, .disassociate:
                dispatchToHandler(action)
            }
        }
        actionSink.removeAll()
    }

    private func receiveTransport(_ frame: RuntimeInboundFrame, epoch: UInt64) {
        guard epoch == transportEpoch else {
            emit(.init(kind: .capacityExceeded, detail: "stale transport frame ignored"))
            return
        }
        _ = receive(frame)
    }

    private func dispatchToHandler(_ action: OwnedProtocolAction) {
        guard let registration = definition.registrations.first(where: { $0.capability == action.kindCapability }) else {
            return
        }
        eventContinuation.yield(.invocation(RuntimeInvocation(action: action)))
        guard activeHandlers < definition.capacities.handlersInFlight else {
            diagnosticsSnapshotValue.handlerSaturation += 1
            emit(.init(kind: .capacityExceeded, detail: "handler supervision capacity is full"))
            return
        }
        activeHandlers += 1
        let invocation = RuntimeInvocation(action: action)
        Task { [weak self] in
            do {
                let result = try await registration.handler(invocation)
                await self?.complete(invocation: invocation, result: result)
            } catch {
                await self?.handlerFailed(String(describing: error))
            }
        }
    }

    private func complete(invocation: RuntimeInvocation, result: RuntimeHandlerResult) {
        activeHandlers = max(0, activeHandlers - 1)
        guard case let .response(payload) = result,
              let correlation = invocation.action.routingKey.correlationID else { return }
        _ = publish(
            RuntimeOperation(
                capability: .returnEvent,
                sourceID: definition.sourceID,
                correlationID: correlation,
                payload: payload
            ),
            nowMS: 0
        )
    }

    private func handlerFailed(_ detail: String) {
        activeHandlers = max(0, activeHandlers - 1)
        emit(.init(kind: .handlerFailed, detail: detail))
    }

    private func enqueueOutbound(_ action: OwnedProtocolAction) {
        let result = outboundContinuation?.yield(action)
        if case .dropped = result {
            diagnosticsSnapshotValue.dispatchSaturation += 1
            emit(.init(kind: .capacityExceeded, detail: "outbound dispatch queue is full"))
        }
    }

    private func cancelTransportPumps() {
        transportIngressContinuation?.finish()
        outboundContinuation?.finish()
        transportIngressContinuation = nil
        outboundContinuation = nil
        transportIngressTask?.cancel()
        outboundTask?.cancel()
        transportIngressTask = nil
        outboundTask = nil
    }

    private func transportFailed(_ detail: String) {
        diagnosticsSnapshotValue.transportFailures += 1
        emit(.init(kind: .transportFailed, detail: detail))
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

private extension OwnedProtocolAction {
    var kindCapability: ProtocolCapability { routingKey.capability }
}
