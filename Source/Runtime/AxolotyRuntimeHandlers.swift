// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@_spi(AxolotyRuntimeAdapter) import AxolotyProtocol

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

/// A handler retained by an immutable runtime definition.
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
