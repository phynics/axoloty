// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyProtocol
import AxolotyWire

/// Fixed limits used by one host runtime instance.
public struct RuntimeCapacities: Sendable, Equatable {
    /// Maximum owned frames waiting for protocol processing.
    public let ingress: Int
    /// Maximum normalized actions retained for dispatch.
    public let dispatch: Int
    /// Maximum registered handlers.
    public let handlers: Int
    /// Maximum simultaneously supervised handler tasks.
    public let handlersInFlight: Int
    /// Maximum values retained by each public runtime stream.
    public let stream: Int
    /// Maximum event streams registered before startup.
    public let eventStreams: Int

    /// Creates finite runtime limits.
    public init(
        ingress: Int = 64,
        dispatch: Int = 64,
        handlers: Int = 64,
        handlersInFlight: Int = 16,
        stream: Int = 64,
        eventStreams: Int = 64
    ) throws {
        guard ingress > 0, dispatch > 0, handlers > 0,
              handlersInFlight > 0, stream > 0, eventStreams > 0 else {
            throw AxolotyError.invalidArgument(
                argument: "capacities",
                reason: "all runtime capacities must be greater than zero"
            )
        }
        guard ingress <= 64, dispatch <= 64, handlers <= 64,
              handlersInFlight <= 64, stream <= 64, eventStreams <= 64 else {
            throw AxolotyError.invalidArgument(
                argument: "capacities",
                reason: "host runtime capacities cannot exceed 64"
            )
        }
        self.ingress = ingress
        self.dispatch = dispatch
        self.handlers = handlers
        self.handlersInFlight = handlersInFlight
        self.stream = stream
        self.eventStreams = eventStreams
    }
}

/// Stable identity supplied to a runtime before it starts.
public struct RuntimeIdentity: Sendable, Equatable {
    /// The protocol identity used in routing keys.
    public let id: UUID16
    /// A bounded human-readable name used by advertisements and diagnostics.
    public let name: String

    /// Creates a runtime identity.
    public init(id: UUID16, name: String) throws {
        guard !name.isEmpty, name.utf8.count <= 128 else {
            throw AxolotyError.invalidArgument(argument: "name", reason: "must contain 1 to 128 UTF-8 bytes")
        }
        self.id = id
        self.name = name
    }
}

/// Lifecycle state exposed by a runtime instance.
public enum RuntimeState: Sendable, Equatable {
    /// Configuration exists but transport has not started.
    case initialized
    /// Subscriptions and transport are being installed.
    case starting
    /// The runtime accepts protocol work.
    case running
    /// Transport is reconnecting and old requests are being resolved.
    case reconnecting
    /// Shutdown is draining bounded work.
    case stopping
    /// The instance stopped and cannot be started again.
    case stopped
    /// A terminal startup or transport failure occurred.
    case failed
}

/// Provenance of a normalized runtime event.
public enum RuntimeEventProvenance: Sendable, Equatable {
    /// Decoded from an owned transport frame.
    case transport
    /// Created by a local runtime operation.
    case local
    /// Replayed by a bounded test or diagnostic adapter.
    case replay
}

/// The thirteen closed Coaty Core families exposed by the host runtime.
public enum RuntimeEventFamily: Sendable, Equatable, CaseIterable {
    case advertise, deadvertise, channel, associate, ioValue
    case discover, resolve, query, retrieve, update, complete, call, returnEvent
}

/// Context attached to a normalized event. It deliberately contains no raw
/// MQTT topic or transport-owned buffer.
public struct RuntimeEventContext: Sendable, Equatable {
    /// The source that produced the event.
    public let sourceID: UUID16
    /// The request correlation, when the family carries one.
    public let correlationID: UUID16?
    /// The configured namespace.
    public let namespace: String
    /// Binding-owned route classification.
    public let route: ProtocolRouteClassification
    /// Monotonic receipt time supplied by the binding.
    public let receiptTimeMS: UInt32
    /// Whether the event came from transport, a local operation, or replay.
    public let provenance: RuntimeEventProvenance

    /// Creates event context from boundary-owned values.
    public init(
        sourceID: UUID16,
        correlationID: UUID16? = nil,
        namespace: String,
        route: ProtocolRouteClassification = .coaty,
        receiptTimeMS: UInt32,
        provenance: RuntimeEventProvenance = .transport
    ) {
        self.sourceID = sourceID
        self.correlationID = correlationID
        self.namespace = namespace
        self.route = route
        self.receiptTimeMS = receiptTimeMS
        self.provenance = provenance
    }
}

/// Application stream buffering policy. Transport ingress never uses a lossy
/// policy; these policies apply only after normalized actions are owned.
public enum RuntimeBufferingPolicy: Sendable, Equatable {
    /// Fails the runtime after ``AsyncStream`` reports a rejected event.
    /// The triggering value is not delivered because `AsyncStream` has no
    /// synchronous reservation API; callers that require lossless delivery
    /// must use a larger bound or a request/response API.
    case failAfterDrop(capacity: Int)
    case fail(capacity: Int)
    case dropOldest(capacity: Int)
    case dropNewest(capacity: Int)
    case coalesceLatest
}

/// A typed selector for one bounded application event stream.
public enum RuntimeEventSelector: Sendable, Equatable {
    /// Matches every action in one Coaty family.
    case family(RuntimeEventFamily)
    /// Matches Advertise actions, optionally narrowed by an object type.
    case advertise(objectType: String?)
    /// Matches a Channel identifier.
    case channel(identifier: String)
    /// Matches IoValue actions addressed to one actor.
    case ioActor(UUID16)
    /// Matches one correlated response family and identity.
    case correlatedResponse(capability: ProtocolCapability, correlationID: UUID16)
}

/// A bounded asynchronous sequence registered before runtime startup.
public struct RuntimeEventStream: AsyncSequence, Sendable {
    /// The value yielded by this stream.
    public typealias Element = RuntimeEventValue

    private let stream: AsyncStream<RuntimeEventValue>

    init(stream: AsyncStream<RuntimeEventValue>) {
        self.stream = stream
    }

    /// Creates an iterator over owned, normalized event values.
    public func makeAsyncIterator() -> AsyncStream<RuntimeEventValue>.Iterator {
        stream.makeAsyncIterator()
    }
}

struct RuntimeEventRegistration: Sendable {
    let selector: RuntimeEventSelector
    let policy: RuntimeBufferingPolicy
    let continuation: AsyncStream<RuntimeEventValue>.Continuation
}

/// The closed responder selector used by the definition builder.
public enum RuntimeResponderSelector: Sendable, Equatable {
    /// Responds to Discover requests.
    case discover
    /// Responds to Query requests.
    case query
    /// Responds to Update requests.
    case update
    /// Responds to Call requests, optionally narrowed by operation name.
    case call(operation: String?)

    var capability: ProtocolCapability {
        switch self {
        case .discover: return .discover
        case .query: return .query
        case .update: return .update
        case .call: return .call
        }
    }

    var operation: String? {
        if case let .call(operation) = self { return operation }
        return nil
    }
}

/// Boundary validation shared by Call responders and filtered Call requests.
///
/// Operation names become one MQTT topic filter level. Keeping the limit and
/// character rule in one helper prevents a value accepted by the definition
/// builder from producing an unroutable topic when it is submitted directly
/// as a ``RuntimeOperation``.
enum RuntimeOperationValidation {
    static let maximumUTF8Bytes = 128

    static func isValidCallOperation(_ operation: String) -> Bool {
        !operation.isEmpty
            && operation.utf8.count <= maximumUTF8Bytes
            && !operation.contains("/")
            && !operation.contains("#")
            && !operation.contains("+")
            && !operation.utf8.contains(0)
    }
}

/// One-way local operation accepted by the runtime facade.
public enum RuntimeOneWayOperation: Sendable, Equatable {
    case advertise([UInt8])
    case deadvertise([UInt8])
    case channel([UInt8])
    case associate([UInt8])
    case ioValue([UInt8])
}

/// A request operation that may have one or more responses.
public enum RuntimeRequest: Sendable, Equatable {
    /// Discover may remain active until explicitly canceled when `timeoutMS`
    /// is `nil`.
    case discover(correlationID: UUID16, payload: [UInt8], timeoutMS: UInt32?)
    case query(correlationID: UUID16, payload: [UInt8], timeoutMS: UInt32)
    case update(correlationID: UUID16, payload: [UInt8], timeoutMS: UInt32)
    case call(correlationID: UUID16, payload: [UInt8], timeoutMS: UInt32)
    /// Issues a Call request with the operation name encoded as the Coaty topic filter.
    case callWithOperation(correlationID: UUID16, operation: String, payload: [UInt8], timeoutMS: UInt32)

    /// Creates a filtered Call request while preserving the compact legacy spelling.
    public static func call(
        correlationID: UUID16,
        operation: String,
        payload: [UInt8],
        timeoutMS: UInt32
    ) -> Self {
        .callWithOperation(correlationID: correlationID, operation: operation, payload: payload, timeoutMS: timeoutMS)
    }
}

/// A response operation produced by a responder.
public enum RuntimeResponse: Sendable, Equatable {
    case resolve(correlationID: UUID16, payload: [UInt8])
    case retrieve(correlationID: UUID16, payload: [UInt8])
    case complete(correlationID: UUID16, payload: [UInt8])
    case returnEvent(correlationID: UUID16, payload: [UInt8])
}

/// A normalized event delivered by a host runtime stream.
public struct RuntimeEventValue: Sendable, Equatable {
    /// The closed family.
    public let family: RuntimeEventFamily
    /// Boundary-owned event context.
    public let context: RuntimeEventContext
    /// Owned, family-codec payload bytes. These bytes are never borrowed.
    public let value: [UInt8]

    /// Creates an owned normalized event value.
    public init(family: RuntimeEventFamily, context: RuntimeEventContext, value: [UInt8]) {
        self.family = family
        self.context = context
        self.value = value
    }
}

/// An owned inbound frame copied at the transport boundary.
public struct RuntimeInboundFrame: Sendable, Equatable {
    /// The complete MQTT topic.
    public let topic: String
    /// The copied event payload.
    public let payload: [UInt8]
    /// Monotonic receipt time supplied by the transport binding.
    public let nowMS: UInt32

    /// Creates an owned inbound frame.
    public init(topic: String, payload: [UInt8], nowMS: UInt32 = 0) {
        self.topic = topic
        self.payload = payload
        self.nowMS = nowMS
    }
}

/// Coalesced supervision counters for a runtime instance.
public struct RuntimeDiagnostics: Sendable, Equatable {
    public var ingressSaturation = 0
    public var dispatchSaturation = 0
    public var handlerSaturation = 0
    public var reconnects = 0
    public var expiredRequests = 0
    public var malformedFrames = 0
    public var transportFailures = 0

    /// Creates an empty diagnostics snapshot.
    public init() {}
}

/// The externally visible lifecycle of a host runtime instance.
public enum RuntimeLifecycleState: UInt8, Sendable, Equatable {
    /// The runtime is not connected and may be started.
    case stopped
    /// The transport is being opened.
    case starting
    /// The transport and protocol executor are accepting work.
    case running
    /// The transport epoch is being replaced.
    case reconnecting
    /// The transport is being closed.
    case stopping
    /// Startup or transport initialization failed.
    case failed
    /// The runtime can no longer be started.
    case closed
}

/// A structured reason for a rejected runtime transition.
public enum RuntimeRejection: Sendable, Equatable {
    /// The runtime is not accepting work in its current lifecycle state.
    case notRunning(RuntimeLifecycleState)
    /// The inbound topic is empty or malformed.
    case malformedFrame(ProtocolError.Code)
    /// The operation payload is empty or invalid for its family.
    case malformedPayload
    /// A filtered Call operation name cannot be represented as one MQTT topic level.
    case invalidOperationName
    /// A processor-defined rejection code.
    case `protocol`(ProtocolError.Code)
    /// The finite runtime storage is saturated.
    case capacityExceeded
    /// A transport callback belongs to an earlier start epoch.
    case staleTransport
}

/// An owned local operation submitted to the shared protocol processor.
public struct RuntimeOperation: Sendable, Equatable {
    /// The Coaty capability to publish.
    public let capability: ProtocolCapability
    /// The publication source identity.
    public let sourceID: UUID16
    /// The request/response correlation identity, when applicable.
    public let correlationID: UUID16?
    /// The already encoded bounded payload.
    public let payload: [UInt8]
    /// The request timeout for request capabilities.
    public let requestTimeoutMS: UInt32?
    /// The optional Call operation name encoded as the topic filter.
    public let operationName: String?

    /// Creates an owned local operation.
    public init(
        capability: ProtocolCapability,
        sourceID: UUID16,
        correlationID: UUID16? = nil,
        payload: [UInt8],
        requestTimeoutMS: UInt32? = nil,
        operationName: String? = nil
    ) {
        self.capability = capability
        self.sourceID = sourceID
        self.correlationID = correlationID
        self.payload = payload
        self.requestTimeoutMS = requestTimeoutMS
        self.operationName = operationName
    }

    /// Creates an operation from the closed one-way family values.
    public init(oneWay: RuntimeOneWayOperation, sourceID: UUID16) {
        switch oneWay {
        case let .advertise(payload): self.init(capability: .advertise, sourceID: sourceID, payload: payload)
        case let .deadvertise(payload): self.init(capability: .deadvertise, sourceID: sourceID, payload: payload)
        case let .channel(payload): self.init(capability: .channel, sourceID: sourceID, payload: payload)
        case let .associate(payload): self.init(capability: .associate, sourceID: sourceID, payload: payload)
        case let .ioValue(payload): self.init(capability: .ioValue, sourceID: sourceID, payload: payload)
        }
    }

    /// Creates an operation from a closed request family value.
    public init(request: RuntimeRequest, sourceID: UUID16) {
        switch request {
        case let .discover(id, payload, timeout): self.init(capability: .discover, sourceID: sourceID, correlationID: id, payload: payload, requestTimeoutMS: timeout)
        case let .query(id, payload, timeout): self.init(capability: .query, sourceID: sourceID, correlationID: id, payload: payload, requestTimeoutMS: timeout)
        case let .update(id, payload, timeout): self.init(capability: .update, sourceID: sourceID, correlationID: id, payload: payload, requestTimeoutMS: timeout)
        case let .call(id, payload, timeout): self.init(capability: .call, sourceID: sourceID, correlationID: id, payload: payload, requestTimeoutMS: timeout)
        case let .callWithOperation(id, operation, payload, timeout): self.init(capability: .call, sourceID: sourceID, correlationID: id, payload: payload, requestTimeoutMS: timeout, operationName: operation)
        }
    }

    /// Creates an operation from a closed responder value.
    public init(response: RuntimeResponse, sourceID: UUID16) {
        switch response {
        case let .resolve(id, payload): self.init(capability: .resolve, sourceID: sourceID, correlationID: id, payload: payload)
        case let .retrieve(id, payload): self.init(capability: .retrieve, sourceID: sourceID, correlationID: id, payload: payload)
        case let .complete(id, payload): self.init(capability: .complete, sourceID: sourceID, correlationID: id, payload: payload)
        case let .returnEvent(id, payload): self.init(capability: .returnEvent, sourceID: sourceID, correlationID: id, payload: payload)
        }
    }

    /// Creates an Advertise operation.
    public static func advertise(sourceID: UUID16, payload: [UInt8]) -> Self {
        Self(capability: .advertise, sourceID: sourceID, payload: payload)
    }
    /// Creates a Deadvertise operation.
    public static func deadvertise(sourceID: UUID16, payload: [UInt8]) -> Self {
        Self(capability: .deadvertise, sourceID: sourceID, payload: payload)
    }
    /// Creates a Channel operation.
    public static func channel(sourceID: UUID16, payload: [UInt8]) -> Self {
        Self(capability: .channel, sourceID: sourceID, payload: payload)
    }
    /// Creates an Associate operation.
    public static func associate(sourceID: UUID16, payload: [UInt8]) -> Self {
        Self(capability: .associate, sourceID: sourceID, payload: payload)
    }
    /// Creates an IoValue operation.
    public static func ioValue(sourceID: UUID16, payload: [UInt8]) -> Self {
        Self(capability: .ioValue, sourceID: sourceID, payload: payload)
    }
    /// Creates a Discover request.
    public static func discover(sourceID: UUID16, correlationID: UUID16, payload: [UInt8], timeoutMS: UInt32?) -> Self {
        Self(capability: .discover, sourceID: sourceID, correlationID: correlationID, payload: payload, requestTimeoutMS: timeoutMS)
    }
    /// Creates a Resolve response.
    public static func resolve(sourceID: UUID16, correlationID: UUID16, payload: [UInt8]) -> Self {
        Self(capability: .resolve, sourceID: sourceID, correlationID: correlationID, payload: payload)
    }
    /// Creates a Query request.
    public static func query(sourceID: UUID16, correlationID: UUID16, payload: [UInt8], timeoutMS: UInt32) -> Self {
        Self(capability: .query, sourceID: sourceID, correlationID: correlationID, payload: payload, requestTimeoutMS: timeoutMS)
    }
    /// Creates a Retrieve response.
    public static func retrieve(sourceID: UUID16, correlationID: UUID16, payload: [UInt8]) -> Self {
        Self(capability: .retrieve, sourceID: sourceID, correlationID: correlationID, payload: payload)
    }
    /// Creates an Update request.
    public static func update(sourceID: UUID16, correlationID: UUID16, payload: [UInt8], timeoutMS: UInt32) -> Self {
        Self(capability: .update, sourceID: sourceID, correlationID: correlationID, payload: payload, requestTimeoutMS: timeoutMS)
    }
    /// Creates a Complete response.
    public static func complete(sourceID: UUID16, correlationID: UUID16, payload: [UInt8]) -> Self {
        Self(capability: .complete, sourceID: sourceID, correlationID: correlationID, payload: payload)
    }
    /// Creates a Call request.
    public static func call(sourceID: UUID16, correlationID: UUID16, payload: [UInt8], timeoutMS: UInt32) -> Self {
        Self(capability: .call, sourceID: sourceID, correlationID: correlationID, payload: payload, requestTimeoutMS: timeoutMS)
    }
    /// Creates a Return response.
    public static func returnEvent(sourceID: UUID16, correlationID: UUID16, payload: [UInt8]) -> Self {
        Self(capability: .returnEvent, sourceID: sourceID, correlationID: correlationID, payload: payload)
    }
}

/// The result of a bounded runtime transition.
public enum RuntimeReceipt: Sendable, Equatable {
    /// The protocol processor accepted the transition.
    case accepted
    /// The binding did not own the supplied route.
    case ignored
    /// The transition was rejected without state mutation.
    case rejected(RuntimeRejection)
}

/// A materialized invocation delivered to an application handler.
public struct RuntimeInvocation: Sendable, Equatable {
    /// The normalized protocol action.
    public let action: OwnedProtocolAction
    /// The binding-supplied operation name for a Call, when present.
    public let operation: String?

    /// Internal registration identity used to account for bounded handler
    /// concurrency. It never participates in the public protocol contract.
    let registrationIndex: Int
    /// Internal task identity used to cancel and drain handler work.
    let handlerID: UInt64

    /// Creates an invocation from an owned action.
    init(
        action: OwnedProtocolAction,
        operation: String? = nil,
        registrationIndex: Int = -1,
        handlerID: UInt64 = 0
    ) {
        self.action = action
        self.operation = operation
        self.registrationIndex = registrationIndex
        self.handlerID = handlerID
    }
}

/// The result returned by an application handler.
public enum RuntimeHandlerResult: Sendable, Equatable {
    /// Sends a response payload using the incoming correlation identity.
    case response([UInt8])
    /// Delivers no response for the invocation.
    case noResponse
    /// Sends a structured remote error message.
    case remoteError(code: UInt16, message: String)
}

/// A bounded runtime event, suitable for an asynchronous consumer.
public enum RuntimeEvent: Sendable, Equatable {
    /// An owned protocol action was delivered to a registered handler.
    case invocation(RuntimeInvocation)
    /// A protocol transition completed with a receipt.
    case transition(RuntimeReceipt)
}

/// A bounded diagnostic emitted by the runtime supervision layer.
public struct RuntimeDiagnostic: Sendable, Equatable {
    /// Stable diagnostic category.
    public enum Kind: String, Sendable {
        /// A bounded queue could not accept more work.
        case capacityExceeded
        /// A handler task returned an error.
        case handlerFailed
        /// A transport operation failed.
        case transportFailed
        /// An inbound frame could not be parsed or validated.
        case malformedFrame
    }

    /// The diagnostic category.
    public let kind: Kind
    /// A bounded human-readable detail.
    public let detail: String

    /// Creates a diagnostic.
    public init(kind: Kind, detail: String) {
        self.kind = kind
        self.detail = detail
    }
}

/// A transport boundary for the host runtime.
///
/// Implementations own networking and invoke `receive` only with copied data.
/// The runtime never exposes borrowed wire views through this protocol.
public protocol AxolotyRuntimeTransport: AnyObject, Sendable {
    /// Starts the transport and installs the owned-frame receive callback.
    func start(receive: @escaping @Sendable (RuntimeInboundFrame) -> Void) async throws
    /// Installs a callback for failures after startup has completed.
    ///
    /// The callback is invoked with an owned error value and may be called
    /// from a transport event-loop thread. Implementations must not retain
    /// borrowed protocol data in this callback.
    func setFailureHandler(_ handler: @escaping @Sendable (Error) -> Void) async
    /// Publishes an owned normalized protocol action.
    func send(_ action: OwnedProtocolAction, namespace: String) async throws
    /// Stops the transport and releases its callbacks.
    func stop() async

    /// Installs binding subscriptions before identity is advertised.
    func installSubscriptions(namespace: String) async throws
    /// Removes binding subscriptions during graceful shutdown.
    func removeSubscriptions(namespace: String) async throws
    /// Publishes the binding-specific identity advertisement.
    func advertise(identity: RuntimeIdentity?, namespace: String) async throws
    /// Publishes the binding-specific deadvertisement.
    func deadvertise(identity: RuntimeIdentity?, namespace: String) async throws
    /// Classifies an association route using binding-owned knowledge.
    ///
    /// The borrowed route is valid only for this synchronous call. The
    /// transport must not retain it or impose a profile-wide route grammar.
    func classifyRoute(_ route: ByteSlice) -> ProtocolRouteClassification
}

public extension AxolotyRuntimeTransport {
    func setFailureHandler(_ handler: @escaping @Sendable (Error) -> Void) async { _ = handler }
    func installSubscriptions(namespace: String) async throws {}
    func removeSubscriptions(namespace: String) async throws {}
    func advertise(identity: RuntimeIdentity?, namespace: String) async throws {}
    func deadvertise(identity: RuntimeIdentity?, namespace: String) async throws {}
    func classifyRoute(_ route: ByteSlice) -> ProtocolRouteClassification {
        route.length == 0 ? .unrelated : .coaty
    }
}

/// A handler retained by a sealed runtime definition.
public struct RuntimeHandlerRegistration: Sendable {
    /// The capability family delivered to this handler.
    public let capability: ProtocolCapability
    /// An optional application-level operation label.
    public let operation: String?
    /// Maximum number of concurrent invocations for this registration.
    public let maximumConcurrentInvocations: Int
    /// The bounded asynchronous handler.
    public let handler: @Sendable (RuntimeInvocation) async throws -> RuntimeHandlerResult

    /// Creates a handler registration.
    public init(
        capability: ProtocolCapability,
        operation: String? = nil,
        maximumConcurrentInvocations: Int = 1,
        handler: @escaping @Sendable (RuntimeInvocation) async throws -> RuntimeHandlerResult
    ) {
        self.capability = capability
        self.operation = operation
        self.maximumConcurrentInvocations = maximumConcurrentInvocations
        self.handler = handler
    }
}

/// A pre-start runtime definition builder.
///
/// Registration is finite and mutable only until ``seal()`` consumes the
/// builder. The sealed definition has no registration API.
public struct RuntimeDefinition: Sendable {
    /// The namespace used by the host transport binding.
    public let namespace: String
    /// The local protocol source identity.
    public let sourceID: UUID16
    /// Optional modern identity metadata used by the binding advertisement.
    public let identity: RuntimeIdentity?
    /// The fixed limits for this runtime.
    public let capacities: RuntimeCapacities

    private var registrations: [RuntimeHandlerRegistration] = []
    private var eventRegistrations: [RuntimeEventRegistration] = []
    private var sealed = false

    /// Creates an empty runtime definition.
    public init(namespace: String, sourceID: UUID16, identity: RuntimeIdentity? = nil, capacities: RuntimeCapacities) throws {
        guard !namespace.isEmpty,
              !namespace.contains("/"),
              !namespace.contains("#"),
              !namespace.contains("+"),
              !namespace.utf8.contains(0) else {
            throw AxolotyError.invalidArgument(argument: "namespace", reason: "must be a non-empty MQTT topic level")
        }
        self.namespace = namespace
        self.sourceID = sourceID
        self.identity = identity
        self.capacities = capacities
        self.registrations.reserveCapacity(capacities.handlers)
    }

    /// Registers one bounded application handler.
    @discardableResult
    public mutating func register(
        capability: ProtocolCapability,
        operation: String? = nil,
        maximumConcurrentInvocations: Int = 1,
        handler: @escaping @Sendable (RuntimeInvocation) async throws -> RuntimeHandlerResult
    ) throws -> Int {
        guard !sealed else {
            throw AxolotyError.runtime(code: .notStarted, reason: "the runtime definition is already sealed")
        }
        guard registrations.count < capacities.handlers else {
            throw AxolotyError.runtime(code: .subscriptionFailed, reason: "runtime handler capacity is full")
        }
        if let operation {
            guard capability == .call else {
                throw AxolotyError.invalidArgument(
                    argument: "operation",
                    reason: "operation filters are only valid for Call handlers"
                )
            }
            guard RuntimeOperationValidation.isValidCallOperation(operation) else {
                throw AxolotyError.invalidArgument(
                    argument: "operation",
                    reason: "must contain 1 to 128 UTF-8 bytes and no MQTT topic separators"
                )
            }
        }
        guard maximumConcurrentInvocations > 0,
              maximumConcurrentInvocations <= capacities.handlersInFlight else {
            throw AxolotyError.invalidArgument(
                argument: "maximumConcurrentInvocations",
                reason: "must fit the runtime handler limit"
            )
        }
        registrations.append(RuntimeHandlerRegistration(
            capability: capability,
            operation: operation,
            maximumConcurrentInvocations: maximumConcurrentInvocations,
            handler: handler
        ))
        return registrations.count - 1
    }

    /// Registers a bounded normalized event stream before startup.
    public mutating func registerEvents(
        matching selector: RuntimeEventSelector,
        buffering policy: RuntimeBufferingPolicy
    ) throws -> RuntimeEventStream {
        let capacity: Int
        switch policy {
        case let .failAfterDrop(value), let .fail(value), let .dropOldest(value), let .dropNewest(value):
            guard value > 0, value <= capacities.stream else {
                throw AxolotyError.invalidArgument(argument: "capacity", reason: "stream capacity must be in 1...runtime stream capacity")
            }
            capacity = value
        case .coalesceLatest:
            capacity = 1
        }
        let buffering: AsyncStream<RuntimeEventValue>.Continuation.BufferingPolicy
        switch policy {
        case .failAfterDrop, .dropNewest: buffering = .bufferingOldest(capacity)
        case .fail, .dropOldest: buffering = .bufferingNewest(capacity)
        case .coalesceLatest: buffering = .bufferingNewest(1)
        }
        guard eventRegistrations.count < capacities.eventStreams else {
            throw AxolotyError.runtime(code: .capacityExceeded, reason: "runtime event-stream capacity is full")
        }
        let pair = AsyncStream<RuntimeEventValue>.makeStream(bufferingPolicy: buffering)
        eventRegistrations.append(RuntimeEventRegistration(selector: selector, policy: policy, continuation: pair.continuation))
        return RuntimeEventStream(stream: pair.stream)
    }

    /// Seals this definition and prevents further registration.
    public consuming func seal() throws -> SealedRuntimeDefinition {
        guard !sealed else {
            throw AxolotyError.runtime(code: .notStarted, reason: "the runtime definition is already sealed")
        }
        var copy = self
        copy.sealed = true
        return SealedRuntimeDefinition(
            namespace: copy.namespace,
            sourceID: copy.sourceID,
            identity: copy.identity,
            capacities: copy.capacities,
            registrations: copy.registrations,
            eventRegistrations: copy.eventRegistrations
        )
    }
}

/// An immutable runtime definition accepted by ``AxolotyRuntime``.
public struct SealedRuntimeDefinition: Sendable {
    /// The namespace used by the host transport binding.
    public let namespace: String
    /// The local protocol source identity.
    public let sourceID: UUID16
    /// Optional modern identity metadata used by the binding advertisement.
    public let identity: RuntimeIdentity?
    /// The fixed limits for this runtime.
    public let capacities: RuntimeCapacities
    let registrations: [RuntimeHandlerRegistration]
    let eventRegistrations: [RuntimeEventRegistration]

    /// The number of registered handlers.
    public var handlerCount: Int { registrations.count }

    init(namespace: String, sourceID: UUID16, identity: RuntimeIdentity? = nil, capacities: RuntimeCapacities, registrations: [RuntimeHandlerRegistration], eventRegistrations: [RuntimeEventRegistration] = []) {
        self.namespace = namespace
        self.sourceID = sourceID
        self.identity = identity
        self.capacities = capacities
        self.registrations = registrations
        self.eventRegistrations = eventRegistrations
    }
}

public extension RuntimeDefinition {
    /// Mutable pre-start configuration builder. Calling ``finish()`` seals
    /// the definition and makes its registration graph immutable.
    struct Builder {
        private var definition: RuntimeDefinition
        private var identity: RuntimeIdentity

        /// Creates a builder with the host defaults.
        public init(
            identity: RuntimeIdentity,
            namespace: String,
            limits: RuntimeCapacities? = nil
        ) throws {
            self.identity = identity
            let resolvedLimits: RuntimeCapacities
            if let limits {
                resolvedLimits = limits
            } else {
                resolvedLimits = try RuntimeCapacities()
            }
            self.definition = try RuntimeDefinition(
                namespace: namespace,
                sourceID: identity.id,
                identity: identity,
                capacities: resolvedLimits
            )
        }

        /// Registers a family handler before startup.
        @discardableResult
        public mutating func respond(
            to capability: ProtocolCapability,
            operation: String? = nil,
            maximumConcurrentInvocations: Int = 1,
            handler: @escaping @Sendable (RuntimeInvocation) async throws -> RuntimeHandlerResult
        ) throws -> Int {
            try definition.register(
                capability: capability,
                operation: operation,
                maximumConcurrentInvocations: maximumConcurrentInvocations,
                handler: handler
            )
        }

        /// Registers an event stream in the immutable runtime definition.
        public mutating func events(
            matching selector: RuntimeEventSelector,
            buffering policy: RuntimeBufferingPolicy = .failAfterDrop(capacity: 64)
        ) throws -> RuntimeEventStream {
            try definition.registerEvents(matching: selector, buffering: policy)
        }

        /// Registers a bounded responder for a request family.
        @discardableResult
        public mutating func respond(
            to selector: RuntimeResponderSelector,
            maximumConcurrentInvocations: Int = 1,
            handler: @escaping @Sendable (RuntimeInvocation) async throws -> RuntimeHandlerResult
        ) throws -> Int {
            guard maximumConcurrentInvocations > 0, maximumConcurrentInvocations <= definition.capacities.handlersInFlight else {
                throw AxolotyError.invalidArgument(argument: "maximumConcurrentInvocations", reason: "must fit the runtime handler limit")
            }
            return try definition.register(
                capability: selector.capability,
                operation: selector.operation,
                maximumConcurrentInvocations: maximumConcurrentInvocations,
                handler: handler
            )
        }

        /// Finishes registration and returns the immutable definition.
        public consuming func finish() throws -> SealedRuntimeDefinition {
            _ = identity
            return try definition.seal()
        }
    }
}
