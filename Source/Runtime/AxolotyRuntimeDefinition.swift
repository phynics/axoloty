// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@_spi(AxolotyRuntimeAdapter) import AxolotyProtocol

import AxolotyObjectModel

import AxolotyWire

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
    let registryID: ObjectID

    private var registrations: [RuntimeHandlerRegistration] = []
    private var eventRegistrations: [RuntimeEventRegistration] = []
    var ioEndpointRegistrations: [RuntimeIoEndpointRegistration] = []
    var runtimeComponents: [RuntimeComponentRegistration] = []
    var runtimeComponentCorrelationOrdinal: UInt32 = 0
    var sealed = false

    /// Keeps one ProtocolProcessor object slot available for runtime identity.
    var endpointRegistrationLimit: Int {
        let reservedIdentitySlot = identity == nil ? 0 : 1
        return min(capacities.ioEndpoints, capacities.ioCatalogue, 64 - reservedIdentitySlot)
    }

    /// Creates an empty runtime definition.
    public init(namespace: String, sourceID: UUID16, identity: RuntimeIdentity? = nil, capacities: RuntimeCapacities) throws {
        guard !namespace.isEmpty,
              namespace.utf8.count <= 64,
              !namespace.contains("/"),
              !namespace.contains("#"),
              !namespace.contains("+"),
              !namespace.utf8.contains(0) else {
            throw AxolotyError.invalidArgument(
                argument: "namespace",
                reason: "must contain 1...64 UTF-8 bytes and no MQTT topic separators"
            )
        }
        self.namespace = namespace
        self.sourceID = sourceID
        self.identity = identity
        self.capacities = capacities
        self.registryID = runtimeRegistryNonce()
        self.registrations.reserveCapacity(capacities.handlers)
        self.ioEndpointRegistrations.reserveCapacity(endpointRegistrationLimit)
        self.runtimeComponents.reserveCapacity(4)
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
            eventRegistrations: copy.eventRegistrations,
            registryID: copy.registryID,
            ioEndpointRegistrations: copy.ioEndpointRegistrations,
            runtimeComponents: copy.runtimeComponents
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
    let registryID: ObjectID
    let registrations: [RuntimeHandlerRegistration]
    let eventRegistrations: [RuntimeEventRegistration]
    let ioEndpointRegistrations: [RuntimeIoEndpointRegistration]
    let runtimeComponents: [RuntimeComponentRegistration]

    /// The number of registered handlers.
    public var handlerCount: Int { registrations.count }
    /// The number of registered typed IO endpoints.
    public var ioEndpointCount: Int { ioEndpointRegistrations.count }

    init(namespace: String, sourceID: UUID16, identity: RuntimeIdentity? = nil, capacities: RuntimeCapacities, registrations: [RuntimeHandlerRegistration], eventRegistrations: [RuntimeEventRegistration] = [], registryID: ObjectID, ioEndpointRegistrations: [RuntimeIoEndpointRegistration] = [], runtimeComponents: [RuntimeComponentRegistration] = []) {
        self.namespace = namespace
        self.sourceID = sourceID
        self.identity = identity
        self.capacities = capacities
        self.registryID = registryID
        self.registrations = registrations
        self.eventRegistrations = eventRegistrations
        self.ioEndpointRegistrations = ioEndpointRegistrations
        self.runtimeComponents = runtimeComponents
    }
}

public extension RuntimeDefinition {
    /// Mutable pre-start configuration builder. Calling ``finish()`` seals
    /// the definition and makes its registration graph immutable.
    struct Builder {
        var definition: RuntimeDefinition
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
