// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@_spi(AxolotyRuntimeAdapter) import AxolotyProtocol

import AxolotyObjectModel
import AxolotyWire

/// Boundary validation shared by Call responders and filtered Call requests.
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

/// The finite, value-semantic registration draft owned by ``RuntimeBuilder``.
///
/// Runtime registrations are never exposed as mutable storage. Every builder
/// operation copies this value, validates the complete proposed state, and
/// commits it only after the operation succeeds.
struct RuntimeRegistrations: Sendable {
    let capacities: RuntimeCapacities
    let registryID: ObjectID
    var handlers: [RuntimeHandlerRegistration]
    var eventRegistrations: [RuntimeEventRegistration]
    var ioEndpointRegistrations: [RuntimeIoEndpointRegistration]
    var endpointGenerations: [UInt32]
    var modules: [RuntimeModuleRegistration]
    var moduleKeys: Set<String>
    var moduleCorrelationOrdinal: UInt32

    init(capacities: RuntimeCapacities, registryID: ObjectID = runtimeRegistryNonce()) {
        self.capacities = capacities
        self.registryID = registryID
        self.handlers = []
        self.eventRegistrations = []
        self.ioEndpointRegistrations = []
        self.endpointGenerations = []
        self.modules = []
        self.moduleKeys = []
        self.moduleCorrelationOrdinal = 0
        handlers.reserveCapacity(capacities.handlers)
        ioEndpointRegistrations.reserveCapacity(min(capacities.ioEndpoints, capacities.ioCatalogue))
        endpointGenerations.reserveCapacity(min(capacities.ioEndpoints, capacities.ioCatalogue))
        modules.reserveCapacity(4)
    }

    mutating func reserveModuleCorrelationID() -> UUID16 {
        moduleCorrelationOrdinal &+= 1
        let ordinal = moduleCorrelationOrdinal
        let base = registryID.uuid.bytes
        return UUID16(bytes: (
            base.0, base.1, base.2, base.3, base.4, base.5, base.6, base.7,
            base.8, base.9, base.10, base.11,
            UInt8(truncatingIfNeeded: ordinal >> 24),
            UInt8(truncatingIfNeeded: ordinal >> 16),
            UInt8(truncatingIfNeeded: ordinal >> 8),
            UInt8(truncatingIfNeeded: ordinal)
        ))
    }

    func finishNewEventStreams(after count: Int) {
        guard eventRegistrations.count > count else { return }
        for registration in eventRegistrations[count...] {
            registration.continuation.finish()
        }
    }
}

/// A pre-start runtime registration builder.
public struct RuntimeBuilder: Sendable {
    /// The namespace used by the host transport binding.
    public let namespace: String
    /// The local protocol source identity.
    public let sourceID: UUID16
    /// Optional modern identity metadata used by the binding advertisement.
    public let identity: RuntimeIdentity?
    /// The fixed limits for this runtime.
    public var capacities: RuntimeCapacities { registrations.capacities }

    var registrations: RuntimeRegistrations

    /// Creates a builder from a complete runtime identity.
    ///
    /// - Parameters:
    ///   - identity: The stable identity used by this runtime.
    ///   - namespace: The validated runtime namespace.
    ///   - capacities: Optional finite runtime limits.
    /// - Throws: ``AxolotyError`` when namespace or capacities are invalid.
    public init(
        identity: RuntimeIdentity,
        namespace: String,
        capacities: RuntimeCapacities? = nil
    ) throws {
        let resolvedCapacities = try capacities ?? RuntimeCapacities()
        try self.init(sourceID: identity.id, namespace: namespace, identity: identity, capacities: resolvedCapacities)
    }

    /// Creates a builder from a source identity and optional metadata.
    ///
    /// - Parameters:
    ///   - sourceID: The stable protocol source identity.
    ///   - namespace: The validated runtime namespace.
    ///   - identity: Optional identity metadata whose ID must match `sourceID`.
    ///   - capacities: Optional finite runtime limits.
    /// - Throws: ``AxolotyError`` when namespace, identity, or capacities are invalid.
    public init(
        sourceID: UUID16,
        namespace: String,
        identity: RuntimeIdentity? = nil,
        capacities: RuntimeCapacities? = nil
    ) throws {
        guard !namespace.isEmpty,
              namespace.utf8.count <= 64,
              !namespace.contains("/"),
              !namespace.contains("#"),
              !namespace.contains("+"),
              !namespace.utf8.contains(0) else {
            throw AxolotyError.invalidArgument(argument: "namespace", reason: "must contain 1...64 UTF-8 bytes and no route separators")
        }
        if let identity, identity.id != sourceID {
            throw AxolotyError.invalidArgument(argument: "identity", reason: "identity id must equal sourceID")
        }
        let resolvedCapacities = try capacities ?? RuntimeCapacities()
        self.namespace = namespace
        self.sourceID = sourceID
        self.identity = identity
        self.registrations = RuntimeRegistrations(capacities: resolvedCapacities)
    }

    mutating func commit<T>(_ operation: (inout RuntimeRegistrations) throws -> T) throws -> T {
        var draft = registrations
        let eventCount = draft.eventRegistrations.count
        do {
            let result = try operation(&draft)
            registrations = draft
            return result
        } catch {
            draft.finishNewEventStreams(after: eventCount)
            throw error
        }
    }

    /// Registers one bounded application handler.
    ///
    /// - Parameters:
    ///   - capability: The closed protocol family handled by the callback.
    ///   - operation: Optional Call operation filter.
    ///   - maximumConcurrentInvocations: The callback's in-flight bound.
    ///   - handler: The asynchronous owned invocation callback.
    /// - Returns: The registration index in the finished definition.
    /// - Throws: ``AxolotyError`` when validation or capacity checks fail.
    @discardableResult
    public mutating func respond(
        to capability: ProtocolCapability,
        operation: String? = nil,
        maximumConcurrentInvocations: Int = 1,
        handler: @escaping @Sendable (RuntimeInvocation) async throws -> RuntimeHandlerResult
    ) throws -> Int {
        return try commit { draft in
            guard draft.handlers.count < draft.capacities.handlers else {
                throw AxolotyError.runtime(code: .subscriptionFailed, reason: "runtime handler capacity is full")
            }
            if let operation {
                guard capability == .call else {
                    throw AxolotyError.invalidArgument(argument: "operation", reason: "operation filters are only valid for Call handlers")
                }
                guard RuntimeOperationValidation.isValidCallOperation(operation) else {
                    throw AxolotyError.invalidArgument(argument: "operation", reason: "must contain 1 to 128 UTF-8 bytes and no route separators")
                }
            }
            guard maximumConcurrentInvocations > 0,
                  maximumConcurrentInvocations <= draft.capacities.handlersInFlight else {
                throw AxolotyError.invalidArgument(argument: "maximumConcurrentInvocations", reason: "must fit the runtime handler limit")
            }
            draft.handlers.append(RuntimeHandlerRegistration(capability: capability, operation: operation, maximumConcurrentInvocations: maximumConcurrentInvocations, handler: handler))
            return draft.handlers.count - 1
        }
    }

    /// Registers a bounded responder for a request family.
    ///
    /// - Parameters:
    ///   - selector: The request family and optional Call operation filter.
    ///   - maximumConcurrentInvocations: The callback's in-flight bound.
    ///   - handler: The asynchronous owned invocation callback.
    /// - Returns: The registration index in the finished definition.
    /// - Throws: ``AxolotyError`` when validation or capacity checks fail.
    @discardableResult
    public mutating func respond(
        to selector: RuntimeResponderSelector,
        maximumConcurrentInvocations: Int = 1,
        handler: @escaping @Sendable (RuntimeInvocation) async throws -> RuntimeHandlerResult
    ) throws -> Int {
        try respond(to: selector.capability, operation: selector.operation, maximumConcurrentInvocations: maximumConcurrentInvocations, handler: handler)
    }

    /// Registers a normalized event stream before startup.
    ///
    /// - Parameters:
    ///   - selector: The normalized event selector.
    ///   - policy: The bounded application buffering policy.
    /// - Returns: An owned stream of normalized event values.
    /// - Throws: ``AxolotyError`` when policy or stream capacity validation fails.
    public mutating func events(
        matching selector: RuntimeEventSelector,
        buffering policy: RuntimeBufferingPolicy = .failAfterDrop(capacity: 64)
    ) throws -> RuntimeEventStream {
        return try commit { draft in
            let capacity: Int
            switch policy {
            case let .failAfterDrop(value), let .fail(value), let .dropOldest(value), let .dropNewest(value):
                guard value > 0, value <= draft.capacities.stream else {
                    throw AxolotyError.invalidArgument(argument: "capacity", reason: "stream capacity must be in 1...runtime stream capacity")
                }
                capacity = value
            case .coalesceLatest: capacity = 1
            }
            let buffering: AsyncStream<RuntimeEventValue>.Continuation.BufferingPolicy
            switch policy {
            case .failAfterDrop, .dropNewest: buffering = .bufferingOldest(capacity)
            case .fail, .dropOldest: buffering = .bufferingNewest(capacity)
            case .coalesceLatest: buffering = .bufferingNewest(1)
            }
            guard draft.eventRegistrations.count < draft.capacities.eventStreams else {
                throw AxolotyError.runtime(code: .capacityExceeded, reason: "runtime event-stream capacity is full")
            }
            let pair = AsyncStream<RuntimeEventValue>.makeStream(bufferingPolicy: buffering)
            draft.eventRegistrations.append(RuntimeEventRegistration(selector: selector, policy: policy, continuation: pair.continuation))
            return RuntimeEventStream(stream: pair.stream, continuation: pair.continuation)
        }
    }

    /// Returns the number of event streams currently registered in this
    /// provisional builder.
    package var eventStreamCount: Int {
        registrations.eventRegistrations.count
    }

    /// Finishes event streams provisionally registered after the supplied count.
    ///
    /// - Parameter count: The number of streams retained before the provisional draft.
    package mutating func finishNewRuntimeEventStreams(after count: Int) {
        registrations.finishNewEventStreams(after: count)
    }

    /// Finishes registration and returns the immutable runtime definition.
    ///
    /// - Returns: The immutable definition containing the committed registration graph.
    /// - Throws: An error reserved for future final validation of the graph.
    public consuming func finish() throws -> RuntimeDefinition {
        RuntimeDefinition(namespace: namespace, sourceID: sourceID, identity: identity, registrations: registrations)
    }

    /// Performs one first-party module registration as an atomic draft.
    ///
    /// - Parameters:
    ///   - key: The stable internal module key.
    ///   - body: The module registration draft.
    /// - Returns: The value produced by the draft body.
    /// - Throws: ``AxolotyError`` when the key or registration is invalid.
    package mutating func withRuntimeModule<T>(
        key: String,
        _ body: (inout RuntimeBuilder) throws -> (RuntimeModuleRegistration, T)
    ) throws -> T {
        guard !key.isEmpty, key.utf8.count <= 64 else {
            throw AxolotyError.invalidArgument(argument: "key", reason: "runtime module key must contain 1...64 UTF-8 bytes")
        }
        guard !registrations.moduleKeys.contains(key) else {
            throw AxolotyError.runtime(code: .capacityExceeded, reason: "runtime module key is already registered")
        }
        var draft = self
        let eventCount = draft.registrations.eventRegistrations.count
        guard draft.registrations.modules.count < 4 else {
            throw AxolotyError.runtime(code: .capacityExceeded, reason: "runtime module capacity is full")
        }
        draft.registrations.moduleKeys.insert(key)
        do {
            let (registration, result) = try body(&draft)
            guard draft.registrations.modules.count < 4 else {
                throw AxolotyError.runtime(code: .capacityExceeded, reason: "runtime module capacity is full")
            }
            draft.registrations.modules.append(registration)
            self = draft
            return result
        } catch {
            draft.registrations.finishNewEventStreams(after: eventCount)
            throw error
        }
    }

    /// Registers a prebuilt first-party module under a stable key.
    ///
    /// - Parameters:
    ///   - key: The stable internal module key.
    ///   - registration: The module lifecycle registration.
    /// - Throws: ``AxolotyError`` when the key is invalid or already registered.
    package mutating func withRuntimeModule(
        key: String,
        registration: RuntimeModuleRegistration
    ) throws {
        try registerRuntimeModule(registration, key: key)
    }
}

/// An immutable runtime definition accepted by ``AxolotyRuntime``.
public struct RuntimeDefinition: Sendable {
    /// The namespace used by the host transport binding.
    public let namespace: String
    /// The local protocol source identity.
    public let sourceID: UUID16
    /// Optional modern identity metadata used by the binding advertisement.
    public let identity: RuntimeIdentity?
    /// The fixed limits for this runtime.
    public var capacities: RuntimeCapacities { registrations.capacities }

    let registrations: RuntimeRegistrations

    init(namespace: String, sourceID: UUID16, identity: RuntimeIdentity?, registrations: RuntimeRegistrations) {
        self.namespace = namespace
        self.sourceID = sourceID
        self.identity = identity
        self.registrations = registrations
    }

    /// The number of registered handlers.
    public var handlerCount: Int { registrations.handlers.count }
    /// The number of registered event streams.
    public var eventStreamCount: Int { registrations.eventRegistrations.count }
    /// The number of registered typed IO endpoints.
    public var ioEndpointCount: Int { registrations.ioEndpointRegistrations.count }
    /// The number of registered first-party runtime modules.
    public var moduleCount: Int { registrations.modules.count }
}
