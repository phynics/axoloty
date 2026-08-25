// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyProtocol
import AxolotyWire
import Foundation

struct RuntimeTransportEffectBatch: Sendable {
    let effects: [RuntimeTransportEffect]

    var count: Int { effects.count }
}

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

    /// The executor-backed typed IO capability.
    public var io: RuntimeIO { RuntimeIO(executor: executor) }

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
