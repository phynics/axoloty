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

    /// Creates finite runtime limits.
    public init(
        ingress: Int = 64,
        dispatch: Int = 64,
        handlers: Int = 64,
        handlersInFlight: Int = 16,
        stream: Int = 64
    ) throws {
        guard ingress > 0, dispatch > 0, handlers > 0,
              handlersInFlight > 0, stream > 0 else {
            throw AxolotyError.invalidArgument(
                argument: "capacities",
                reason: "all runtime capacities must be greater than zero"
            )
        }
        guard ingress <= 64, dispatch <= 64, handlers <= 64,
              handlersInFlight <= 64, stream <= 64 else {
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
    }
}

/// An owned inbound frame copied at the transport boundary.
public struct RuntimeInboundFrame: Sendable, Equatable {
    /// The complete MQTT topic.
    public let topic: String
    /// The copied event payload.
    public let payload: [UInt8]

    /// Creates an owned inbound frame.
    public init(topic: String, payload: [UInt8]) {
        self.topic = topic
        self.payload = payload
    }
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

    /// Creates an owned local operation.
    public init(
        capability: ProtocolCapability,
        sourceID: UUID16,
        correlationID: UUID16? = nil,
        payload: [UInt8],
        requestTimeoutMS: UInt32? = nil
    ) {
        self.capability = capability
        self.sourceID = sourceID
        self.correlationID = correlationID
        self.payload = payload
        self.requestTimeoutMS = requestTimeoutMS
    }
}

/// The result of a bounded runtime transition.
public enum RuntimeReceipt: Sendable, Equatable {
    /// The protocol processor accepted the transition.
    case accepted
    /// The binding did not own the supplied route.
    case ignored
    /// The transition was rejected without state mutation.
    case rejected(String)
    /// The bounded ingress or dispatch queue was full.
    case capacityExceeded
}

/// A materialized invocation delivered to an application handler.
public struct RuntimeInvocation: Sendable, Equatable {
    /// The normalized protocol action.
    public let action: OwnedProtocolAction

    /// Creates an invocation from an owned action.
    init(action: OwnedProtocolAction) {
        self.action = action
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
    /// Publishes an owned normalized protocol action.
    func send(_ action: OwnedProtocolAction, namespace: String) async throws
    /// Stops the transport and releases its callbacks.
    func stop() async
}

/// A handler retained by a sealed runtime definition.
public struct RuntimeHandlerRegistration: Sendable {
    /// The capability family delivered to this handler.
    public let capability: ProtocolCapability
    /// An optional application-level operation label.
    public let operation: String?
    /// The bounded asynchronous handler.
    public let handler: @Sendable (RuntimeInvocation) async throws -> RuntimeHandlerResult

    /// Creates a handler registration.
    public init(
        capability: ProtocolCapability,
        operation: String? = nil,
        handler: @escaping @Sendable (RuntimeInvocation) async throws -> RuntimeHandlerResult
    ) {
        self.capability = capability
        self.operation = operation
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
    /// The fixed limits for this runtime.
    public let capacities: RuntimeCapacities

    private var registrations: [RuntimeHandlerRegistration] = []
    private var sealed = false

    /// Creates an empty runtime definition.
    public init(namespace: String, sourceID: UUID16, capacities: RuntimeCapacities) throws {
        guard !namespace.isEmpty, !namespace.contains("/"), !namespace.contains("#"), !namespace.contains("+") else {
            throw AxolotyError.invalidArgument(argument: "namespace", reason: "must be a non-empty MQTT topic level")
        }
        self.namespace = namespace
        self.sourceID = sourceID
        self.capacities = capacities
        self.registrations.reserveCapacity(capacities.handlers)
    }

    /// Registers one bounded application handler.
    @discardableResult
    public mutating func register(
        capability: ProtocolCapability,
        operation: String? = nil,
        handler: @escaping @Sendable (RuntimeInvocation) async throws -> RuntimeHandlerResult
    ) throws -> Int {
        guard !sealed else {
            throw AxolotyError.runtime(code: .notStarted, reason: "the runtime definition is already sealed")
        }
        guard registrations.count < capacities.handlers else {
            throw AxolotyError.runtime(code: .subscriptionFailed, reason: "runtime handler capacity is full")
        }
        if let operation {
            guard !operation.isEmpty, !operation.contains("/") else {
                throw AxolotyError.invalidArgument(argument: "operation", reason: "must be a non-empty name without '/'")
            }
        }
        registrations.append(RuntimeHandlerRegistration(capability: capability, operation: operation, handler: handler))
        return registrations.count - 1
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
            capacities: copy.capacities,
            registrations: copy.registrations
        )
    }
}

/// An immutable runtime definition accepted by ``AxolotyRuntime``.
public struct SealedRuntimeDefinition: Sendable {
    /// The namespace used by the host transport binding.
    public let namespace: String
    /// The local protocol source identity.
    public let sourceID: UUID16
    /// The fixed limits for this runtime.
    public let capacities: RuntimeCapacities
    let registrations: [RuntimeHandlerRegistration]

    /// The number of registered handlers.
    public var handlerCount: Int { registrations.count }

    init(namespace: String, sourceID: UUID16, capacities: RuntimeCapacities, registrations: [RuntimeHandlerRegistration]) {
        self.namespace = namespace
        self.sourceID = sourceID
        self.capacities = capacities
        self.registrations = registrations
    }
}
