// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyWire

/// A closed, borrowed local operation covering every Coaty Core family.
public enum ProtocolLocalOperation {
    /// Publishes an Advertise operation.
    case advertise(sourceID: UUID16, payload: ByteSlice)
    /// Publishes a Deadvertise operation.
    case deadvertise(sourceID: UUID16, payload: ByteSlice)
    /// Publishes a Channel operation.
    case channel(sourceID: UUID16, payload: ByteSlice, identifier: ByteSlice)
    /// Publishes an Associate operation, optionally scoped to an IO context.
    case associate(sourceID: UUID16, payload: ByteSlice, contextName: ByteSlice?)
    /// Publishes an IoValue operation.
    case ioValue(sourceID: UUID16, payload: ByteSlice)
    /// Publishes a Discover request.
    case discover(sourceID: UUID16, correlationID: UUID16, payload: ByteSlice, requestTimeoutMS: UInt32?)
    /// Publishes a Resolve response.
    case resolve(sourceID: UUID16, correlationID: UUID16, payload: ByteSlice)
    /// Publishes a Query request.
    case query(sourceID: UUID16, correlationID: UUID16, payload: ByteSlice, requestTimeoutMS: UInt32?)
    /// Publishes a Retrieve response.
    case retrieve(sourceID: UUID16, correlationID: UUID16, payload: ByteSlice)
    /// Publishes an Update request.
    case update(sourceID: UUID16, correlationID: UUID16, payload: ByteSlice, requestTimeoutMS: UInt32?)
    /// Publishes a Complete response.
    case complete(sourceID: UUID16, correlationID: UUID16, payload: ByteSlice)
    /// Publishes a Call request.
    case call(sourceID: UUID16, correlationID: UUID16, payload: ByteSlice, requestTimeoutMS: UInt32?, operationName: ByteSlice?)
    /// Publishes a Return response.
    case returnEvent(sourceID: UUID16, correlationID: UUID16, payload: ByteSlice)

    /// Creates the closed case corresponding to a capability.
    ///
    /// - Parameters:
    ///   - capability: The Coaty Core family to publish.
    ///   - sourceID: The local source identity.
    ///   - correlationID: The request/response identity when required.
    ///   - payload: Borrowed, already-encoded family data.
    ///   - requestTimeoutMS: Optional timeout for request families.
    /// - Throws: ``ProtocolError`` when correlation presence is invalid.
    public init(capability: ProtocolCapability, sourceID: UUID16, correlationID: UUID16? = nil, payload: ByteSlice, requestTimeoutMS: UInt32? = nil, operationName: ByteSlice? = nil) throws(ProtocolError) {
        _ = try ProtocolRoutingKey(capability: capability, sourceID: sourceID, correlationID: correlationID)
        switch capability {
        case .advertise: self = .advertise(sourceID: sourceID, payload: payload)
        case .deadvertise: self = .deadvertise(sourceID: sourceID, payload: payload)
        case .channel:
            guard let operationName, Self.isValidTopicLevel(operationName) else {
                throw ProtocolError(.malformedFrame)
            }
            self = .channel(sourceID: sourceID, payload: payload, identifier: operationName)
        case .associate:
            if let operationName, !Self.isValidTopicLevel(operationName) {
                throw ProtocolError(.malformedFrame)
            }
            self = .associate(sourceID: sourceID, payload: payload, contextName: operationName)
        case .ioValue: self = .ioValue(sourceID: sourceID, payload: payload)
        case .discover: self = .discover(sourceID: sourceID, correlationID: try requireCorrelation(correlationID), payload: payload, requestTimeoutMS: requestTimeoutMS)
        case .resolve: self = .resolve(sourceID: sourceID, correlationID: try requireCorrelation(correlationID), payload: payload)
        case .query: self = .query(sourceID: sourceID, correlationID: try requireCorrelation(correlationID), payload: payload, requestTimeoutMS: requestTimeoutMS)
        case .retrieve: self = .retrieve(sourceID: sourceID, correlationID: try requireCorrelation(correlationID), payload: payload)
        case .update: self = .update(sourceID: sourceID, correlationID: try requireCorrelation(correlationID), payload: payload, requestTimeoutMS: requestTimeoutMS)
        case .complete: self = .complete(sourceID: sourceID, correlationID: try requireCorrelation(correlationID), payload: payload)
        case .call:
            if let operationName, !Self.isValidTopicLevel(operationName) {
                throw ProtocolError(.malformedFrame)
            }
            self = .call(
                sourceID: sourceID,
                correlationID: try requireCorrelation(correlationID),
                payload: payload,
                requestTimeoutMS: requestTimeoutMS,
                operationName: operationName
            )
        case .returnEvent: self = .returnEvent(sourceID: sourceID, correlationID: try requireCorrelation(correlationID), payload: payload)
        }
    }

    /// The operation's closed capability.
    public var capability: ProtocolCapability {
        switch self { case .advertise: return .advertise; case .deadvertise: return .deadvertise; case .channel: return .channel; case .associate: return .associate; case .ioValue: return .ioValue; case .discover: return .discover; case .resolve: return .resolve; case .query: return .query; case .retrieve: return .retrieve; case .update: return .update; case .complete: return .complete; case .call: return .call; case .returnEvent: return .returnEvent }
    }
    /// The operation's source identity.
    public var sourceID: UUID16 {
        switch self { case let .advertise(id,_), let .deadvertise(id,_), let .channel(id,_,_), let .associate(id,_,_), let .ioValue(id,_), let .discover(id,_,_,_), let .resolve(id,_,_), let .query(id,_,_,_), let .retrieve(id,_,_), let .update(id,_,_,_), let .complete(id,_,_), let .call(id,_,_,_,_), let .returnEvent(id,_,_): return id }
    }
    /// The operation's optional correlation identity.
    public var correlationID: UUID16? {
        switch self { case .advertise, .deadvertise, .channel, .associate, .ioValue: return nil; case let .discover(_,id,_,_), let .resolve(_,id,_), let .query(_,id,_,_), let .retrieve(_,id,_), let .update(_,id,_,_), let .complete(_,id,_), let .call(_,id,_,_,_), let .returnEvent(_,id,_): return id }
    }
    /// The operation's borrowed payload.
    public var payload: ByteSlice {
        switch self { case let .advertise(_,p), let .deadvertise(_,p), let .channel(_,p,_), let .associate(_,p,_), let .ioValue(_,p), let .discover(_,_,p,_), let .resolve(_,_,p), let .query(_,_,p,_), let .retrieve(_,_,p), let .update(_,_,p,_), let .complete(_,_,p), let .call(_,_,p,_,_), let .returnEvent(_,_,p): return p }
    }
    /// The request timeout, when this operation opens a response ledger entry.
    public var requestTimeoutMS: UInt32? {
        switch self { case let .discover(_,_,_,t), let .query(_,_,_,t), let .update(_,_,_,t), let .call(_,_,_,t,_): return t; default: return nil }
    }
    /// The optional IO context, Channel identifier, or Call operation topic filter.
    public var operationName: ByteSlice? {
        switch self {
        case let .channel(_, _, identifier): return identifier
        case let .associate(_, _, contextName): return contextName
        case let .call(_, _, _, _, name): return name
        default: return nil
        }
    }

    private static func isValidTopicLevel(_ value: ByteSlice) -> Bool {
        guard value.length > 0, value.length <= 128 else { return false }
        for index in 0..<value.length {
            guard let byte = value.byte(at: index),
                  byte != 0, byte != 0x2F, byte != 0x23, byte != 0x2B else {
                return false
            }
        }
        return true
    }

    var hasValidTopicFilter: Bool {
        switch capability {
        case .channel:
            guard let operationName else { return false }
            return Self.isValidTopicLevel(operationName)
        case .associate:
            guard let operationName else { return true }
            return Self.isValidTopicLevel(operationName)
        case .call:
            guard let operationName else { return true }
            return Self.isValidTopicLevel(operationName)
        default:
            return true
        }
    }
}

private func requireCorrelation(_ correlationID: UUID16?) throws(ProtocolError) -> UUID16 {
    guard let correlationID else { throw ProtocolError(.invalidCorrelation) }
    return correlationID
}
