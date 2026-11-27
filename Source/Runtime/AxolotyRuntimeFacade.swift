// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyProtocol
import AxolotyWire
import Foundation

struct RuntimePresencePublicationToken: Sendable, Equatable {
    let sourceID: UUID16
    let objectID: UUID16
    let transportEpoch: UInt64
    let batchID: UInt64
}

enum RuntimeQueuedTransportEffect: Sendable {
    case publish(OwnedProtocolPublication)
    case typedIoPublication(OwnedProtocolPublication, token: RuntimeTypedIoPublicationToken)
    case presencePublication(OwnedProtocolPublication, token: RuntimePresencePublicationToken, completesBatch: Bool)
    case externalRouteActivated(OwnedExternalRouteTransition)
    case externalRouteDeactivated(OwnedExternalRouteTransition)

    var isPublication: Bool {
        switch self {
        case .publish, .typedIoPublication, .presencePublication: return true
        case .externalRouteActivated, .externalRouteDeactivated: return false
        }
    }

    /// Resolves this effect against `namespace` and `profile` into a transport effect.
    ///
    /// Publications carry a routing key and a target until this point; the
    /// route is synthesized here so every transport receives finished bytes.
    func transportEffect(namespace: String, profile: WireProfile) throws(AxolotyError) -> RuntimeTransportEffect {
        switch self {
        case let .publish(publication), let .typedIoPublication(publication, _), let .presencePublication(publication, _, _):
            return .publish(try RuntimeOutboundMessage(publication, namespace: namespace, profile: profile))
        case let .externalRouteActivated(transition): return .externalRouteActivated(transition)
        case let .externalRouteDeactivated(transition): return .externalRouteDeactivated(transition)
        }
    }
}

extension RuntimeOutboundMessage {
    /// Resolves a publication's target into a finished route.
    init(_ publication: OwnedProtocolPublication, namespace: String, profile: WireProfile) throws(AxolotyError) {
        switch publication.target {
        case let .profile(eventTypeFilter, filterKind):
            try self.init(
                route: try CoatyRoute.route(
                    for: publication.routingKey,
                    namespace: namespace,
                    eventTypeFilter: eventTypeFilter,
                    eventTypeFilterKind: filterKind,
                    profile: profile
                ),
                payload: publication.payload
            )
        case let .associationRoute(route, kind):
            guard kind != .unrelated else {
                throw AxolotyError.invalidArgument(
                    argument: "route",
                    reason: "unrelated routes cannot be published"
                )
            }
            try self.init(route: String(decoding: route, as: UTF8.self), payload: publication.payload)
        }
    }
}

struct RuntimeTransportEffectBatch: Sendable {
    let effects: [RuntimeQueuedTransportEffect]

    var count: Int { effects.count }
}

/// Host runtime facade backed by one private protocol executor.
///
/// The executor owns the only mutable `ProtocolProcessor` instance. Inbound
/// transport data is copied before it enters the actor, and normalized actions
/// are copied before they are dispatched to application handlers.
public final class AxolotyRuntime: Sendable {
    private let executor: ProtocolExecutor

    /// Creates a stopped runtime from an immutable definition.
    public init(definition: RuntimeDefinition, transport: AxolotyRuntimeTransport) {
        self.executor = ProtocolExecutor(
            definition: definition,
            transport: transport,
            presence: RuntimePresenceEnvironment()
        )
    }

    package init(
        definition: RuntimeDefinition,
        transport: AxolotyRuntimeTransport,
        presence environment: RuntimePresenceEnvironment
    ) {
        self.executor = ProtocolExecutor(definition: definition, transport: transport, presence: environment)
    }

    /// The executor-backed typed IO capability.
    public var io: RuntimeIO { RuntimeIO(executor: executor) }

    /// Starts the runtime transport and protocol executor.
    public func start() async throws {
        if let failure = await executor.start() {
            throw failure
        }
    }

    /// Runs the runtime until a caller invokes ``stop()``. Task cancellation
    /// requests the same graceful stop and is consumed after cleanup. The
    /// transport remains owned by the runtime for the duration of this call.
    public func run() async throws {
        var stopOnExit = false
        defer {
            if stopOnExit {
                await stop()
            }
        }
        do {
            try await withTaskCancellationHandler(operation: {
                try await start()
            }, onCancel: {
                Task { await self.stop() }
            })
            stopOnExit = true
            _ = await executor.waitForTermination()
            try Task.checkCancellation()
            if let failure = await executor.terminalFailure() {
                throw AxolotyError.runtime(code: failure.0, reason: failure.1)
            }
        } catch is CancellationError {
            stopOnExit = true
        } catch {
            if Task.isCancelled {
                stopOnExit = true
                return
            }
            if await lifecycleState() == .failed {
                stopOnExit = true
            }
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
    package func receive(_ frame: RuntimeInboundFrame) async -> RuntimeReceipt {
        await executor.receive(frame)
    }

    /// Submits one owned local operation to `ProtocolProcessor`.
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

    /// Publishes one local object with a soft-state presence lease.
    ///
    /// The runtime refreshes the accepted bytes until you publish a Deadvertise
    /// for the object or stop the runtime. Repeating the same declaration is
    /// idempotent. Withdraw the object before declaring different bytes or a
    /// different lease for that identity.
    ///
    /// - Parameters:
    ///   - objectID: The local object identity to advertise.
    ///   - object: The complete CBOR object, with an `objectId` matching `objectID`.
    ///   - leaseMS: Declared lease in milliseconds, `1000...3_600_000`.
    /// - Returns: The admission receipt. Presence must be enabled and the
    ///   runtime must be running on an `axoloty/1` transport.
    public func advertise(
        objectID: UUID16,
        object: [UInt8],
        leaseMS: UInt32
    ) async -> RuntimeReceipt {
        await executor.advertisePresence(objectID: objectID, object: object, leaseMS: leaseMS)
    }

    /// Returns the bounded stream of peer objects removed by presence expiry.
    ///
    /// The stream finishes at shutdown and is empty and finished when presence
    /// is disabled. When its buffer fills, it retains the older reports.
    /// - Returns: The runtime's presence expiry stream.
    public func presenceExpiries() async -> AsyncStream<RuntimePresenceExpiry> {
        await executor.presenceExpiries()
    }

    /// Returns coalesced supervision counters without exposing transport state.
    public func diagnosticsSnapshot() async -> RuntimeDiagnostics {
        await executor.diagnosticsSnapshot()
    }

    /// Returns an owned conformance observation from the production executor.
    ///
    /// This SPI is restricted to first-party profile conformance tests. It
    /// exposes copied actions and bounded state, never borrowed wire values or
    /// a mutation handle.
    package func conformanceObservation() async -> RuntimeConformanceObservation {
        await executor.conformanceObservation()
    }

    func typedIoFlushAttemptsForTesting() async -> Int {
        await executor.typedIoFlushAttemptsForTesting()
    }
}

/// A copied protocol state used by first-party profile conformance tests.
package struct RuntimeConformanceState: Sendable, Equatable {
    /// Active advertised object identities.
    public let activeObjectIDs: [UUID16]
    /// Outstanding request correlations.
    public let pendingCorrelationIDs: [UUID16]
    /// Active association source identities.
    public let associationSourceIDs: [UUID16]
    /// Current protocol generation.
    public let generation: UInt32

    /// Creates a copied state projection.
    public init(
        activeObjectIDs: [UUID16],
        pendingCorrelationIDs: [UUID16],
        associationSourceIDs: [UUID16],
        generation: UInt32
    ) {
        self.activeObjectIDs = activeObjectIDs
        self.pendingCorrelationIDs = pendingCorrelationIDs
        self.associationSourceIDs = associationSourceIDs
        self.generation = generation
    }
}

/// Owned actions and state captured from one production runtime operation.
package struct RuntimeConformanceObservation: Sendable, Equatable {
    /// Actions emitted by the operation in order.
    public let actions: [OwnedProtocolAction]
    /// State after the operation.
    public let state: RuntimeConformanceState

    /// Creates a conformance observation.
    public init(actions: [OwnedProtocolAction], state: RuntimeConformanceState) {
        self.actions = actions
        self.state = state
    }
}
