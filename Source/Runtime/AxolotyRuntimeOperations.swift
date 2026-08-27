// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@_spi(AxolotyRuntimeAdapter) import AxolotyProtocol

import AxolotyWire

/// One-way local operation accepted by the runtime facade.
public enum RuntimeOneWayOperation: Sendable, Equatable {
    case advertise([UInt8])
    case deadvertise([UInt8])
    case channel(identifier: String, payload: [UInt8])
    case associate([UInt8])
    /// Associates IO routes scoped to a context name.
    case associateInContext(contextName: String, payload: [UInt8])
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
    /// The optional Channel identifier or Call operation encoded as the topic filter.
    public let operationName: String?

    /// Creates an owned local operation inside the runtime boundary.
    init(
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
        case let .channel(identifier, payload): self.init(
            capability: .channel,
            sourceID: sourceID,
            payload: payload,
            operationName: identifier
        )
        case let .associate(payload): self.init(capability: .associate, sourceID: sourceID, payload: payload)
        case let .associateInContext(contextName, payload): self.init(
            capability: .associate,
            sourceID: sourceID,
            payload: payload,
            operationName: contextName
        )
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
    /// Creates a Channel operation with its required topic identifier.
    public static func channel(sourceID: UUID16, identifier: String, payload: [UInt8]) -> Self {
        Self(capability: .channel, sourceID: sourceID, payload: payload, operationName: identifier)
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
