// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyWire

/// A typed local operation submitted to the shared protocol processor.
public struct ProtocolLocalOperation {
    /// The profile family to publish.
    public let capability: ProtocolCapability
    /// The local source identity.
    public let sourceID: UUID16
    /// The optional request/response correlation.
    public let correlationID: UUID16?
    /// The borrowed, already-encoded family payload.
    public let payload: ByteSlice

    /// Creates a local operation without copying its payload.
    public init(
        capability: ProtocolCapability,
        sourceID: UUID16,
        correlationID: UUID16? = nil,
        payload: ByteSlice
    ) throws(ProtocolError) {
        self.capability = capability
        self.sourceID = sourceID
        self.correlationID = correlationID
        self.payload = payload
        _ = try ProtocolRoutingKey(
            capability: capability,
            sourceID: sourceID,
            correlationID: correlationID
        )
    }
}

/// The result of one atomic processor operation.
public enum ProtocolProcessOutcome: Sendable, Equatable {
    /// The operation was accepted and its action was placed in the sink.
    case accepted
    /// The route is unrelated to the binding and was intentionally ignored.
    case ignored
    /// The operation was rejected before state or sink mutation.
    case rejected(ProtocolError.Code)
}

/// A compact snapshot used by host/static replay assertions.
public struct ProtocolStateSnapshot: Sendable, Equatable {
    /// Number of active object/association records.
    public let activeRecords: Int
    /// Number of active association routes.
    public let activeAssociations: Int
    /// Current generation counter.
    public let generation: UInt32
}

/// Shared fixed-inline processor for host and Embedded protocol adapters.
public struct ProtocolProcessor<let capacity: Int>: ~Copyable {
    private struct Association {
        var sourceID = UUID16.zero
        var actorID = UUID16.zero
        var active = false
        var routeLength = 0
        var route = InlineArray<128, UInt8>(repeating: 0)
        var external = false
    }

    private var associations: InlineArray<capacity, Association>
    private var pending = ProtocolPendingRequest()
    private var lastCorrelation = UUID16.zero
    private var hasLastCorrelation = false
    private var generation: UInt32 = 0
    private let capabilities: ProtocolCapabilities
    private let maximumPayloadBytes: Int

    /// Creates a processor with caller-selected capabilities and limits.
    public init(
        capabilities: ProtocolCapabilities = .coatyCore3,
        maximumPayloadBytes: Int = 512
    ) {
        self.capabilities = capabilities
        self.maximumPayloadBytes = maximumPayloadBytes
        self.associations = InlineArray(repeating: Association())
    }

    /// Current fixed-storage state.
    public var state: ProtocolStateSnapshot {
        var records = 0
        var routes = 0
        for index in 0..<capacity where associations[index].active {
            records += 1
            routes += 1
        }
        return ProtocolStateSnapshot(activeRecords: records, activeAssociations: routes, generation: generation)
    }

    /// Starts a single bounded request for a response family.
    public mutating func beginRequest(correlationID: UUID16, nowMS: UInt32, timeoutMS: UInt32) -> Bool {
        pending.begin(correlationID: correlationID, nowMS: nowMS, timeoutMS: timeoutMS)
    }

    /// Expires the request ledger using caller-supplied monotonic time.
    public mutating func expire(nowMS: UInt32) -> Bool { pending.expire(nowMS: nowMS) }

    /// Processes one validated inbound frame and appends at most one action.
    public mutating func processInbound<S: ~Copyable & ProtocolActionSink>(
        _ frame: BorrowedProtocolFrame,
        nowMS: UInt32,
        sink: inout S
    ) -> ProtocolProcessOutcome {
        processInbound(frame, nowMS: nowMS, classifier: AnyProtocolRouteClassifier(), sink: &sink)
    }

    /// Processes an inbound frame using a binding-supplied route classifier.
    public mutating func processInbound<Classifier: ProtocolRouteClassifier, S: ~Copyable & ProtocolActionSink>(
        _ frame: BorrowedProtocolFrame,
        nowMS: UInt32,
        classifier: Classifier,
        sink: inout S
    ) -> ProtocolProcessOutcome {
        guard capabilities.contains(frame.routingKey.capability) else { return .rejected(.unsupportedCapability) }
        guard frame.payload.length <= maximumPayloadBytes else { return .rejected(.capacityExceeded) }
        guard sink.preflight(actionCount: 1) else { return .rejected(.capacityExceeded) }

        if frame.routingKey.capability == .resolve {
            guard let correlation = frame.routingKey.correlationID else { return .rejected(.correlationMismatch) }
            let result = pending.accept(correlationID: correlation, nowMS: nowMS)
            switch result {
            case .accepted: break
            case .duplicate: return .rejected(.duplicate)
            case .wrongCorrelation: return .rejected(.correlationMismatch)
            case .expired: return .rejected(.deadlineExpired)
            }
            lastCorrelation = correlation
            hasLastCorrelation = true
        } else if let correlation = frame.routingKey.correlationID, correlation == lastCorrelation, hasLastCorrelation {
            return .rejected(.duplicate)
        }

        if frame.routingKey.capability == .associate {
            switch consumeAssociation(frame.payload, classifier: classifier) {
            case .accepted: break
            case .ignored: return .ignored
            case .rejected(let code): return .rejected(code)
            }
        }

        let action = BorrowedProtocolAction(
            kind: .deliver,
            routingKey: frame.routingKey,
            payload: frame.payload
        )
        guard sink.append(action) else { return .rejected(.capacityExceeded) }
        generation &+= 1
        return .accepted
    }

    /// Processes a typed local operation through the same action seam.
    public mutating func processOutbound<S: ~Copyable & ProtocolActionSink>(
        _ operation: ProtocolLocalOperation,
        sink: inout S
    ) -> ProtocolProcessOutcome {
        guard capabilities.contains(operation.capability) else { return .rejected(.unsupportedCapability) }
        guard operation.payload.length <= maximumPayloadBytes else { return .rejected(.capacityExceeded) }
        guard sink.preflight(actionCount: 1) else { return .rejected(.capacityExceeded) }
        guard let key = try? ProtocolRoutingKey(
            capability: operation.capability,
            sourceID: operation.sourceID,
            correlationID: operation.correlationID
        ) else { return .rejected(.invalidCorrelation) }
        guard sink.append(BorrowedProtocolAction(kind: .publish, routingKey: key, payload: operation.payload)) else {
            return .rejected(.capacityExceeded)
        }
        generation &+= 1
        return .accepted
    }

    private enum AssociationResult { case accepted, ignored, rejected(ProtocolError.Code) }

    private mutating func consumeAssociation<Classifier: ProtocolRouteClassifier>(
        _ payload: ByteSlice, classifier: Classifier
    ) -> AssociationResult {
        let reader = payload.withBytes { pointer, length in
            WireReader(bytes: pointer.assumingMemoryBound(to: UInt8.self), length: length)
        }
        guard let event = try? AssociateWireData(from: reader) else { return .rejected(.malformedPayload) }
        guard let route = event.associatingRoute else {
            for index in 0..<capacity where associations[index].active && associations[index].sourceID == event.ioSourceId && associations[index].actorID == event.ioActorId {
                associations[index].active = false
                associations[index].routeLength = 0
                return .accepted
            }
            return .ignored
        }
        guard route.length > 0, route.length <= 128 else { return .rejected(.capacityExceeded) }
        let classification = classifier.classify(route)
        if let explicit = event.isExternalRoute {
            if explicit != (classification == .external) { return .rejected(.externalRouteMismatch) }
        }
        if classification == .unrelated { return .ignored }
        for index in 0..<capacity where associations[index].active && associations[index].sourceID == event.ioSourceId && associations[index].actorID == event.ioActorId {
            associations[index].routeLength = min(route.length, 128)
            for offset in 0..<associations[index].routeLength { associations[index].route[offset] = route.byte(at: offset) ?? 0 }
            associations[index].external = classification == .external
            return .accepted
        }
        for index in 0..<capacity where !associations[index].active {
            var association = Association()
            association.sourceID = event.ioSourceId
            association.actorID = event.ioActorId
            association.active = true
            association.routeLength = min(route.length, 128)
            association.external = classification == .external
            for offset in 0..<association.routeLength { association.route[offset] = route.byte(at: offset) ?? 0 }
            associations[index] = association
            return .accepted
        }
        return .rejected(.capacityExceeded)
    }
}

private struct AnyProtocolRouteClassifier: ProtocolRouteClassifier, Sendable {
    func classify(_ route: ByteSlice) -> ProtocolRouteClassification {
        route.length == 0 ? .unrelated : .coaty
    }
}
