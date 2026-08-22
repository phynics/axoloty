// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyWire

/// A closed, borrowed local operation covering every Coaty Core family.
public enum ProtocolLocalOperation {
    /// Publishes an Advertise operation.
    case advertise(sourceID: UUID16, payload: ByteSlice)
    /// Publishes a Deadvertise operation.
    case deadvertise(sourceID: UUID16, payload: ByteSlice)
    /// Publishes a Channel operation.
    case channel(sourceID: UUID16, payload: ByteSlice)
    /// Publishes an Associate operation.
    case associate(sourceID: UUID16, payload: ByteSlice)
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
    case call(sourceID: UUID16, correlationID: UUID16, payload: ByteSlice, requestTimeoutMS: UInt32?)
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
    public init(capability: ProtocolCapability, sourceID: UUID16, correlationID: UUID16? = nil, payload: ByteSlice, requestTimeoutMS: UInt32? = nil) throws(ProtocolError) {
        _ = try ProtocolRoutingKey(capability: capability, sourceID: sourceID, correlationID: correlationID)
        switch capability {
        case .advertise: self = .advertise(sourceID: sourceID, payload: payload)
        case .deadvertise: self = .deadvertise(sourceID: sourceID, payload: payload)
        case .channel: self = .channel(sourceID: sourceID, payload: payload)
        case .associate: self = .associate(sourceID: sourceID, payload: payload)
        case .ioValue: self = .ioValue(sourceID: sourceID, payload: payload)
        case .discover: self = .discover(sourceID: sourceID, correlationID: try requireCorrelation(correlationID), payload: payload, requestTimeoutMS: requestTimeoutMS)
        case .resolve: self = .resolve(sourceID: sourceID, correlationID: try requireCorrelation(correlationID), payload: payload)
        case .query: self = .query(sourceID: sourceID, correlationID: try requireCorrelation(correlationID), payload: payload, requestTimeoutMS: requestTimeoutMS)
        case .retrieve: self = .retrieve(sourceID: sourceID, correlationID: try requireCorrelation(correlationID), payload: payload)
        case .update: self = .update(sourceID: sourceID, correlationID: try requireCorrelation(correlationID), payload: payload, requestTimeoutMS: requestTimeoutMS)
        case .complete: self = .complete(sourceID: sourceID, correlationID: try requireCorrelation(correlationID), payload: payload)
        case .call: self = .call(sourceID: sourceID, correlationID: try requireCorrelation(correlationID), payload: payload, requestTimeoutMS: requestTimeoutMS)
        case .returnEvent: self = .returnEvent(sourceID: sourceID, correlationID: try requireCorrelation(correlationID), payload: payload)
        }
    }

    /// The operation's closed capability.
    public var capability: ProtocolCapability {
        switch self { case .advertise: return .advertise; case .deadvertise: return .deadvertise; case .channel: return .channel; case .associate: return .associate; case .ioValue: return .ioValue; case .discover: return .discover; case .resolve: return .resolve; case .query: return .query; case .retrieve: return .retrieve; case .update: return .update; case .complete: return .complete; case .call: return .call; case .returnEvent: return .returnEvent }
    }
    /// The operation's source identity.
    public var sourceID: UUID16 {
        switch self { case let .advertise(id,_), let .deadvertise(id,_), let .channel(id,_), let .associate(id,_), let .ioValue(id,_), let .discover(id,_,_,_), let .resolve(id,_,_), let .query(id,_,_,_), let .retrieve(id,_,_), let .update(id,_,_,_), let .complete(id,_,_), let .call(id,_,_,_), let .returnEvent(id,_,_): return id }
    }
    /// The operation's optional correlation identity.
    public var correlationID: UUID16? {
        switch self { case .advertise, .deadvertise, .channel, .associate, .ioValue: return nil; case let .discover(_,id,_,_), let .resolve(_,id,_), let .query(_,id,_,_), let .retrieve(_,id,_), let .update(_,id,_,_), let .complete(_,id,_), let .call(_,id,_,_), let .returnEvent(_,id,_): return id }
    }
    /// The operation's borrowed payload.
    public var payload: ByteSlice {
        switch self { case let .advertise(_,p), let .deadvertise(_,p), let .channel(_,p), let .associate(_,p), let .ioValue(_,p), let .discover(_,_,p,_), let .resolve(_,_,p), let .query(_,_,p,_), let .retrieve(_,_,p), let .update(_,_,p,_), let .complete(_,_,p), let .call(_,_,p,_), let .returnEvent(_,_,p): return p }
    }
    /// The request timeout, when this operation opens a response ledger entry.
    public var requestTimeoutMS: UInt32? {
        switch self { case let .discover(_,_,_,t), let .query(_,_,_,t), let .update(_,_,_,t), let .call(_,_,_,t): return t; default: return nil }
    }
}

private func requireCorrelation(_ correlationID: UUID16?) throws(ProtocolError) -> UUID16 {
    guard let correlationID else { throw ProtocolError(.invalidCorrelation) }
    return correlationID
}

/// The result of one atomic processor operation.
public enum ProtocolProcessOutcome: Sendable, Equatable {
    /// The operation was accepted and appended to the sink.
    case accepted
    /// The route is unrelated to this binding.
    case ignored
    /// The operation was rejected without state mutation.
    case rejected(ProtocolError.Code)
}

/// A compact, fixed-storage state observation.
public struct ProtocolStateSnapshot: Sendable, Equatable {
    /// Number of active association records.
    public let activeRecords: Int
    /// Number of active association routes.
    public let activeAssociations: Int
    /// Reserved object count reported by future object adapters.
    public let activeObjects: Int
    /// Reserved pending count reported by future multi-request adapters.
    public let pendingCorrelations: Int
    /// Monotonic processor generation.
    public let generation: UInt32

    /// Creates a state snapshot.
    public init(
        activeRecords: Int,
        activeAssociations: Int,
        generation: UInt32,
        activeObjects: Int = 0,
        pendingCorrelations: Int = 0
    ) {
        self.activeRecords = activeRecords
        self.activeAssociations = activeAssociations
        self.activeObjects = activeObjects
        self.pendingCorrelations = pendingCorrelations
        self.generation = generation
    }
}

/// Caller-owned fixed-inline identity projection for diagnostics and replay.
///
/// The processor never allocates this projection. A caller supplies one when
/// it needs identities; steady-state processing uses only the count snapshot.
public struct ProtocolFixedStateSnapshot<let capacity: Int>: ~Copyable {
    /// Active advertised object identities.
    public private(set) var activeObjectIDs: InlineArray<capacity, UUID16?>
    /// Outstanding request correlations.
    public private(set) var pendingCorrelationIDs: InlineArray<capacity, UUID16?>
    /// Source identities for active association records.
    public private(set) var associationSourceIDs: InlineArray<capacity, UUID16?>
    /// Actor identities for active association records.
    public private(set) var associationActorIDs: InlineArray<capacity, UUID16?>
    /// Number of active object identities in ``activeObjectIDs``.
    public private(set) var activeObjectCount = 0
    /// Number of pending identities in ``pendingCorrelationIDs``.
    public private(set) var pendingCorrelationCount = 0
    /// Number of association records in the paired association buffers.
    public private(set) var associationCount = 0

    /// Creates an empty caller-owned projection.
    public init() {
        self.activeObjectIDs = InlineArray(repeating: nil)
        self.pendingCorrelationIDs = InlineArray(repeating: nil)
        self.associationSourceIDs = InlineArray(repeating: nil)
        self.associationActorIDs = InlineArray(repeating: nil)
    }

    mutating func reset() {
        for index in 0..<capacity {
            activeObjectIDs[index] = nil
            pendingCorrelationIDs[index] = nil
            associationSourceIDs[index] = nil
            associationActorIDs[index] = nil
        }
        activeObjectCount = 0
        pendingCorrelationCount = 0
        associationCount = 0
    }

    mutating func appendObject(_ id: UUID16) {
        guard activeObjectCount < capacity else { return }
        activeObjectIDs[activeObjectCount] = id
        activeObjectCount += 1
    }

    mutating func appendPending(_ id: UUID16) {
        guard pendingCorrelationCount < capacity else { return }
        pendingCorrelationIDs[pendingCorrelationCount] = id
        pendingCorrelationCount += 1
    }

    mutating func appendAssociation(source: UUID16, actor: UUID16) {
        guard associationCount < capacity else { return }
        associationSourceIDs[associationCount] = source
        associationActorIDs[associationCount] = actor
        associationCount += 1
    }
}

/// Shared fixed-inline protocol processor for host and Embedded bindings.
public struct ProtocolProcessor<let capacity: Int>: ~Copyable {
    private struct Association {
        var sourceID = UUID16.zero
        var actorID = UUID16.zero
        var active = false
        var routeLength = 0
        var route = InlineArray<128, UInt8>(repeating: 0)
        var external = false
    }

    private struct ObjectRecord {
        /// Identity of the advertised object, distinct from its source agent.
        var id = UUID16.zero
        var sourceID = UUID16.zero
        var active = false
        var local = false
        var announced = false
    }

    private struct PendingRecord {
        var id = UUID16.zero
        var deadlineMS: UInt32 = 0
        var state: PendingState = .free
    }

    private enum PendingState {
        case free
        case active(PendingRequestKind)
        case resolved
        case expired
        case cancelled
    }

    private enum PendingRequestKind {
        case discover
        case query
        case update
        case call
    }

    private enum AssociationPlan {
        case none
        case remove(Int)
        case upsert(Int, Association)

        var isRemoval: Bool {
            if case .remove = self { return true }
            return false
        }
    }
    private enum AssociationResult {
        case accepted(AssociationPlan, ProtocolRouteClassification)
        case ignored
        case rejected(ProtocolError.Code)
    }

    private enum ObjectPlan {
        case none
        case insert(Int, UUID16, UUID16, Bool)
        case replay(Int)
        case remove(Int)
    }

    private var associations: InlineArray<capacity, Association>
    private var objects: InlineArray<capacity, ObjectRecord>
    private var pending: InlineArray<capacity, PendingRecord>
    private var generation: UInt32 = 0
    private let capabilities: ProtocolCapabilities
    private let maximumPayloadBytes: Int
    private let maximumObjects: Int
    private let maximumPendingCorrelations: Int

    /// Creates a processor with caller-selected capabilities and fixed limits.
    ///
    /// - Parameters:
    ///   - capabilities: Families accepted by this binding.
    ///   - maximumPayloadBytes: Largest accepted borrowed payload.
    ///   - maximumObjects: Maximum simultaneous advertised objects.
    ///   - maximumPendingCorrelations: Maximum outstanding requests.
    public init(
        capabilities: ProtocolCapabilities = .coatyCore3,
        maximumPayloadBytes: Int = 512,
        maximumObjects: Int = capacity,
        maximumPendingCorrelations: Int = capacity
    ) {
        self.capabilities = capabilities
        self.maximumPayloadBytes = maximumPayloadBytes
        self.associations = InlineArray(repeating: Association())
        self.objects = InlineArray(repeating: ObjectRecord())
        self.pending = InlineArray(repeating: PendingRecord())
        self.maximumObjects = min(max(0, maximumObjects), capacity)
        self.maximumPendingCorrelations = min(max(0, maximumPendingCorrelations), capacity)
    }

    /// Returns the current fixed-storage state.
    public var state: ProtocolStateSnapshot {
        var associationCount = 0
        var objectCount = 0
        var pendingCount = 0
        for index in 0..<capacity where associations[index].active { associationCount += 1 }
        for index in 0..<capacity where objects[index].active { objectCount += 1 }
        for index in 0..<capacity {
            if case .active = pending[index].state { pendingCount += 1 }
        }
        return ProtocolStateSnapshot(
            activeRecords: associationCount,
            activeAssociations: associationCount,
            generation: generation,
            activeObjects: objectCount,
            pendingCorrelations: pendingCount
        )
    }

    /// Copies identities into a caller-owned fixed-inline projection.
    ///
    /// - Parameter projection: Caller-owned storage to clear and fill.
    public func copyState(into projection: inout ProtocolFixedStateSnapshot<capacity>) {
        projection.reset()
        for index in 0..<capacity where associations[index].active {
            projection.appendAssociation(source: associations[index].sourceID, actor: associations[index].actorID)
        }
        for index in 0..<capacity where objects[index].active { projection.appendObject(objects[index].id) }
        for index in 0..<capacity {
            if case .active = pending[index].state { projection.appendPending(pending[index].id) }
        }
    }

    /// Copies an active actor route into caller-owned transport storage.
    ///
    /// The copy is synchronous and never stores the caller's buffer.
    public func copyActorRoute(
        actorId: UUID16,
        to output: UnsafeMutablePointer<UInt8>,
        capacity outputCapacity: Int
    ) -> Int? {
        for index in 0..<capacity where associations[index].active && associations[index].actorID == actorId {
            let routeLength = associations[index].routeLength
            guard routeLength > 0, routeLength <= outputCapacity else { return nil }
            for offset in 0..<routeLength { output[offset] = associations[index].route[offset] }
            return routeLength
        }
        return nil
    }

    /// Expires the outstanding request using caller-supplied monotonic time.
    public mutating func expire(nowMS: UInt32) -> Bool {
        var expired = false
        for index in 0..<capacity {
            guard case .active = pending[index].state,
                  Self.reached(nowMS, pending[index].deadlineMS) else { continue }
            pending[index].state = .expired
            expired = true
        }
        return expired
    }

    /// Cancels one outstanding request without emitting a wire operation.
    ///
    /// Cancellation is local policy: the peer may still publish a response,
    /// but the processor rejects it as a duplicate rather than delivering it.
    /// The terminal slot remains reclaimable by a later request.
    public mutating func cancel(correlationID: UUID16) -> Bool {
        for index in 0..<capacity where pending[index].id == correlationID {
            guard case .active = pending[index].state else { return false }
            pending[index].state = .cancelled
            generation &+= 1
            return true
        }
        return false
    }

    /// Resets transport-local state while retaining the processor's static
    /// configuration. Local advertisement identities remain in the logical
    /// registry and become replayable; peer-only records are discarded.
    public mutating func resetTransport() {
        for index in 0..<capacity {
            associations[index] = Association()
            pending[index] = PendingRecord()
            if objects[index].active && objects[index].local {
                objects[index].announced = false
            } else {
                objects[index] = ObjectRecord()
            }
        }
        generation &+= 1
    }

    /// Processes a validated borrowed inbound frame.
    ///
    /// - Parameters:
    ///   - frame: Borrowed topic and payload views valid for this call.
    ///   - nowMS: Caller-supplied monotonic time in milliseconds.
    ///   - sink: Caller-owned action destination.
    /// - Returns: The atomic transition result.
    public mutating func processInbound<S: ~Copyable & ProtocolActionSink>(_ frame: BorrowedProtocolFrame, nowMS: UInt32, sink: inout S) -> ProtocolProcessOutcome {
        processInbound(frame, nowMS: nowMS, classifier: AnyProtocolRouteClassifier(), sink: &sink)
    }

    /// Processes a validated inbound frame with a binding-owned route classifier.
    ///
    /// - Parameters:
    ///   - frame: Borrowed topic and payload views valid for this call.
    ///   - nowMS: Caller-supplied monotonic time in milliseconds.
    ///   - classifier: Binding-owned association-route classifier.
    ///   - sink: Caller-owned action destination.
    /// - Returns: The atomic transition result.
    public mutating func processInbound<Classifier: ProtocolRouteClassifier, S: ~Copyable & ProtocolActionSink>(_ frame: BorrowedProtocolFrame, nowMS: UInt32, classifier: Classifier, sink: inout S) -> ProtocolProcessOutcome {
        guard capabilities.contains(frame.routingKey.capability) else { return .rejected(.unsupportedCapability) }
        guard frame.payload.length <= maximumPayloadBytes else { return .rejected(.capacityExceeded) }
        let valid = validatePayload(frame.payload, for: frame.routingKey.capability)
        guard valid else { return .rejected(.malformedPayload) }
        var ioActorActionCount = 0
        if frame.routingKey.capability == .ioValue {
            for index in 0..<capacity where associations[index].active && associations[index].sourceID == frame.routingKey.sourceID {
                ioActorActionCount += 1
            }
        }
        let actionCount = max(1, ioActorActionCount)

        var responsePlan: (index: Int, correlationID: UUID16)?
        switch frame.routingKey.capability {
        case .resolve, .retrieve, .complete, .returnEvent:
            guard let correlation = frame.routingKey.correlationID else { return .rejected(.correlationMismatch) }
            var matchingIndex: Int?
            for index in 0..<capacity {
                guard pending[index].id == correlation else { continue }
                if case .free = pending[index].state { continue }
                matchingIndex = index
                break
            }
            guard let matchingIndex else {
                return .rejected(.correlationMismatch)
            }
            switch pending[matchingIndex].state {
            case .resolved, .cancelled: return .rejected(.duplicate)
            case .expired: return .rejected(.deadlineExpired)
            case .free: return .rejected(.correlationMismatch)
            case .active(let requestKind):
                guard !Self.reached(nowMS, pending[matchingIndex].deadlineMS) else { return .rejected(.deadlineExpired) }
                guard Self.accepts(response: frame.routingKey.capability, for: requestKind) else {
                    return .rejected(.correlationMismatch)
                }
                responsePlan = (matchingIndex, correlation)
            }
        default:
            break
        }

        let plan: AssociationPlan
        var routeClassification: ProtocolRouteClassification = .coaty
        if frame.routingKey.capability == .associate {
            switch planAssociation(frame.payload, classifier: classifier) {
            case .accepted(let value, let classification):
                plan = value
                routeClassification = classification
            case .ignored: return .ignored
            case .rejected(let code): return .rejected(code)
            }
        } else {
            plan = .none
        }
        let objectPlan: ObjectPlan
        switch frame.routingKey.capability {
        case .advertise:
            let objectID = Self.advertisedObjectID(frame.payload) ?? frame.routingKey.sourceID
            var existing = false
            var activeCount = 0
            var freeIndex: Int?
            for index in 0..<capacity {
                if objects[index].active {
                    activeCount += 1
                    if objects[index].sourceID == frame.routingKey.sourceID && objects[index].id == objectID { existing = true }
                } else if freeIndex == nil {
                    freeIndex = index
                }
            }
            guard !existing else { return .rejected(.duplicate) }
            guard activeCount < maximumObjects, let freeIndex else { return .rejected(.capacityExceeded) }
            objectPlan = .insert(freeIndex, frame.routingKey.sourceID, objectID, false)
        case .deadvertise:
            var foundIndex: Int?
            for index in 0..<capacity where objects[index].active && objects[index].sourceID == frame.routingKey.sourceID {
                foundIndex = index
                break
            }
            guard let index = foundIndex else { return .rejected(.malformedFrame) }
            objectPlan = .remove(index)
        default:
            objectPlan = .none
        }
        // Classification and all rejection-only validation precede sink
        // capacity so unrelated routes and contradictory flags retain their
        // semantic outcomes even when the caller's sink is full.
        guard sink.preflight(actionCount: actionCount) else { return .rejected(.capacityExceeded) }
        let actionKind: ProtocolActionKind = plan.isRemoval ? .disassociate : (frame.routingKey.capability == .associate ? .associate : .deliver)
        if ioActorActionCount > 0 {
            for index in 0..<capacity where associations[index].active && associations[index].sourceID == frame.routingKey.sourceID {
                let action = BorrowedProtocolAction(
                    kind: actionKind,
                    routingKey: frame.routingKey,
                    payload: frame.payload,
                    deliveryKey: .ioActor(associations[index].actorID),
                    topic: frame.topic,
                    routeClassification: frame.routingKey.capability == .ioValue && associations[index].external
                        ? .external
                        : routeClassification
                )
                guard sink.append(action) else { return .rejected(.capacityExceeded) }
            }
        } else {
            let action = BorrowedProtocolAction(
                kind: actionKind,
                routingKey: frame.routingKey,
                payload: frame.payload,
                deliveryKey: deliveryKey(for: frame),
                topic: frame.topic,
                routeClassification: routeClassification
            )
            guard sink.append(action) else { return .rejected(.capacityExceeded) }
        }
        if let responsePlan {
            if Self.isTerminalResponse(frame.routingKey.capability) {
                pending[responsePlan.index].state = .resolved
            }
        }
        apply(plan)
        apply(objectPlan)
        generation &+= 1
        return .accepted
    }

    /// Processes a typed local operation into a publish action.
    ///
    /// - Parameters:
    ///   - operation: Closed local operation with borrowed payload data.
    ///   - nowMS: Caller-supplied monotonic time in milliseconds.
    ///   - sink: Caller-owned action destination.
    /// - Returns: The atomic transition result.
    public mutating func processOutbound<S: ~Copyable & ProtocolActionSink>(_ operation: ProtocolLocalOperation, nowMS: UInt32 = 0, sink: inout S) -> ProtocolProcessOutcome {
        processOutbound(operation, nowMS: nowMS, classifier: AnyProtocolRouteClassifier(), sink: &sink)
    }

    /// Processes a local operation with a binding-owned route classifier.
    ///
    /// - Parameters:
    ///   - operation: Closed local operation with borrowed payload data.
    ///   - nowMS: Caller-supplied monotonic time in milliseconds.
    ///   - classifier: Binding-owned association-route classifier.
    ///   - sink: Caller-owned action destination.
    /// - Returns: The atomic transition result.
    public mutating func processOutbound<Classifier: ProtocolRouteClassifier, S: ~Copyable & ProtocolActionSink>(_ operation: ProtocolLocalOperation, nowMS: UInt32 = 0, classifier: Classifier, sink: inout S) -> ProtocolProcessOutcome {
        guard capabilities.contains(operation.capability) else { return .rejected(.unsupportedCapability) }
        guard operation.payload.length <= maximumPayloadBytes else { return .rejected(.capacityExceeded) }
        let valid = validatePayload(operation.payload, for: operation.capability)
        guard valid else { return .rejected(.malformedPayload) }
        guard let key = try? ProtocolRoutingKey(capability: operation.capability, sourceID: operation.sourceID, correlationID: operation.correlationID) else { return .rejected(.invalidCorrelation) }
        var requestPlan: (index: Int, correlationID: UUID16, deadlineMS: UInt32)?
        if let timeout = operation.requestTimeoutMS {
            guard timeout > 0 else { return .rejected(.deadlineExpired) }
            guard let correlation = operation.correlationID,
                  let index = pendingSlot(for: correlation) else {
                return .rejected(.capacityExceeded)
            }
            requestPlan = (index, correlation, nowMS &+ timeout)
        }
        let objectPlan: ObjectPlan
        switch operation.capability {
        case .advertise:
            let objectID = Self.advertisedObjectID(operation.payload) ?? operation.sourceID
            var existing = false
            var activeCount = 0
            var freeIndex: Int?
            var replayIndex: Int?
            for index in 0..<capacity {
                if objects[index].active {
                    activeCount += 1
                    if objects[index].sourceID == operation.sourceID && objects[index].id == objectID {
                        existing = true
                        if objects[index].local && !objects[index].announced { replayIndex = index }
                    }
                } else if freeIndex == nil {
                    freeIndex = index
                }
            }
            if existing {
                guard let replayIndex else { return .rejected(.duplicate) }
                objectPlan = .replay(replayIndex)
            } else {
                guard activeCount < maximumObjects, let freeIndex else { return .rejected(.capacityExceeded) }
                objectPlan = .insert(freeIndex, operation.sourceID, objectID, true)
            }
        case .deadvertise:
            var foundIndex: Int?
            for index in 0..<capacity where objects[index].active && objects[index].sourceID == operation.sourceID {
                foundIndex = index
                break
            }
            guard let index = foundIndex else { return .rejected(.malformedFrame) }
            objectPlan = .remove(index)
        default:
            objectPlan = .none
        }
        let plan: AssociationPlan
        var routeClassification: ProtocolRouteClassification = .coaty
        if operation.capability == .associate {
            let associateReader = operation.payload.withBytes { pointer, length in
                WireReader(bytes: pointer.assumingMemoryBound(to: UInt8.self), length: length)
            }
            if let associate = try? AssociateWireData(from: associateReader), associate.isExternalRoute != nil {
                return .rejected(.externalRouteMismatch)
            }
            switch planAssociation(operation.payload, classifier: classifier) {
            case .accepted(let value, let classification):
                plan = value
                routeClassification = classification
            case .ignored: return .ignored
            case .rejected(let code): return .rejected(code)
            }
        } else {
            plan = .none
        }
        guard sink.preflight(actionCount: 1) else { return .rejected(.capacityExceeded) }
        guard sink.append(BorrowedProtocolAction(
            kind: .publish,
            routingKey: key,
            payload: operation.payload,
            deliveryKey: deliveryKey(for: operation),
            routeClassification: routeClassification
        )) else { return .rejected(.capacityExceeded) }
        if let requestPlan {
            pending[requestPlan.index] = PendingRecord(
                id: requestPlan.correlationID,
                deadlineMS: requestPlan.deadlineMS,
                state: .active(Self.requestKind(for: operation.capability))
            )
        }
        apply(plan)
        apply(objectPlan)
        generation &+= 1
        return .accepted
    }

    private func deliveryKey(for frame: BorrowedProtocolFrame) -> ProtocolDeliveryKey {
        switch frame.routingKey.capability {
        case .advertise:
            if let filter = frame.topicView.eventTypeFilter { return .advertiseFilter(filter) }
        case .channel:
            if let channel = frame.topicView.eventTypeFilter { return .channel(channel) }
        case .associate:
            let reader = frame.payload.withBytes { pointer, length in
                WireReader(bytes: pointer.assumingMemoryBound(to: UInt8.self), length: length)
            }
            if let associate = try? AssociateWireData(from: reader) {
                return .ioActor(associate.ioActorId)
            }
        case .ioValue:
            for index in 0..<capacity where associations[index].active && associations[index].sourceID == frame.routingKey.sourceID {
                return .ioActor(associations[index].actorID)
            }
        case .resolve, .retrieve, .complete, .returnEvent:
            if let correlation = frame.routingKey.correlationID {
                return .correlated(frame.routingKey.capability, correlation)
            }
        default: break
        }
        return .capability(frame.routingKey.capability)
    }

    private func deliveryKey(for operation: ProtocolLocalOperation) -> ProtocolDeliveryKey {
        switch operation {
        case .resolve, .retrieve, .complete, .returnEvent:
            if let correlation = operation.correlationID {
                return .correlated(operation.capability, correlation)
            }
        default:
            break
        }
        return .capability(operation.capability)
    }

    private func planAssociation<Classifier: ProtocolRouteClassifier>(_ payload: ByteSlice, classifier: Classifier) -> AssociationResult {
        let reader = payload.withBytes { pointer, length in WireReader(bytes: pointer.assumingMemoryBound(to: UInt8.self), length: length) }
        guard let event = try? AssociateWireData(from: reader) else { return .rejected(.malformedPayload) }
        guard let route = event.associatingRoute else {
            for index in 0..<capacity where associations[index].active && associations[index].sourceID == event.ioSourceId && associations[index].actorID == event.ioActorId { return .accepted(.remove(index), .coaty) }
            return .ignored
        }
        guard route.length > 0, route.length <= 128 else { return .rejected(.capacityExceeded) }
        let classification = classifier.classify(route)
        if let explicit = event.isExternalRoute, explicit != (classification == .external) { return .rejected(.externalRouteMismatch) }
        if classification == .unrelated { return .ignored }
        for index in 0..<capacity where associations[index].active && associations[index].sourceID == event.ioSourceId && associations[index].actorID == event.ioActorId {
            var association = associations[index]
            association.routeLength = route.length
            for offset in 0..<route.length { association.route[offset] = route.byte(at: offset) ?? 0 }
            association.external = classification == .external
            return .accepted(.upsert(index, association), classification)
        }
        for index in 0..<capacity where !associations[index].active {
            var association = Association(sourceID: event.ioSourceId, actorID: event.ioActorId, active: true, routeLength: route.length, route: InlineArray(repeating: 0), external: classification == .external)
            for offset in 0..<route.length { association.route[offset] = route.byte(at: offset) ?? 0 }
            return .accepted(.upsert(index, association), classification)
        }
        return .rejected(.capacityExceeded)
    }

    private mutating func apply(_ plan: AssociationPlan) {
        switch plan {
        case .none: return
        case .remove(let index): associations[index].active = false; associations[index].routeLength = 0
        case .upsert(let index, let association): associations[index] = association
        }
    }

    private mutating func apply(_ plan: ObjectPlan) {
        switch plan {
        case .none: return
        case .insert(let index, let sourceID, let objectID, let local):
            objects[index] = ObjectRecord(id: objectID, sourceID: sourceID, active: true, local: local, announced: true)
        case .replay(let index):
            objects[index].announced = true
        case .remove(let index):
            objects[index] = ObjectRecord()
        }
    }

    private static func advertisedObjectID(_ payload: ByteSlice) -> UUID16? {
        payload.withBytes { pointer, length in
            let reader = WireReader(bytes: pointer.assumingMemoryBound(to: UInt8.self), length: length)
            guard let object = reader.readRaw("object") else { return nil }
            return object.withBytes { objectPointer, objectLength in
                let objectReader = WireReader(
                    bytes: objectPointer.assumingMemoryBound(to: UInt8.self),
                    length: objectLength
                )
                return objectReader.readUUID("objectId")
            }
        }
    }

    private func pendingSlot(for correlationID: UUID16) -> Int? {
        for index in 0..<capacity {
            guard case .free = pending[index].state else {
                guard pending[index].id == correlationID else { continue }
                return nil
            }
            continue
        }
        var occupied = 0
        for index in 0..<capacity {
            if case .active = pending[index].state { occupied += 1 }
        }
        guard occupied < maximumPendingCorrelations else { return nil }
        for index in 0..<capacity {
            switch pending[index].state {
            case .free, .resolved, .expired, .cancelled: return index
            case .active: continue
            }
        }
        return nil
    }

    private static func requestKind(for capability: ProtocolCapability) -> PendingRequestKind {
        switch capability {
        case .discover: return .discover
        case .query: return .query
        case .update: return .update
        case .call: return .call
        default: return .discover
        }
    }

    private static func accepts(response: ProtocolCapability, for request: PendingRequestKind) -> Bool {
        switch (request, response) {
        case (.discover, .resolve), (.query, .retrieve), (.query, .complete),
             (.update, .complete), (.call, .returnEvent):
            return true
        default:
            return false
        }
    }

    private static func isTerminalResponse(_ response: ProtocolCapability) -> Bool {
        response == .complete || response == .returnEvent
    }

    private func validatePayload(_ payload: ByteSlice, for capability: ProtocolCapability) -> Bool {
        payload.withBytes { pointer, length in
            let reader = WireReader(bytes: pointer.assumingMemoryBound(to: UInt8.self), length: length)
            switch capability {
            case .advertise:
                return (try? AdvertiseWireData(from: reader)) != nil
            case .deadvertise:
                return (try? DeadvertiseWireData(from: reader)) != nil
            case .associate:
                return (try? AssociateWireData(from: reader)) != nil
            case .ioValue:
                // IoValue is the one profile family whose payload may be a
                // bare JSON value or arbitrary binary bytes. Validate
                // JSON-looking input, but never require UTF-8 for raw input.
                guard let first = payload.byte(at: 0) else { return true }
                switch first {
                case 0x22, 0x2D, 0x30...0x39, 0x5B, 0x66, 0x6E, 0x74, 0x7B:
                    return WireReader.isValidJSONValue(payload)
                default:
                    return true
                }
            case .channel:
                return (try? ChannelWireData(from: reader)) != nil
            case .discover:
                return (try? DiscoverWireData(from: reader)) != nil
            case .query:
                return (try? QueryWireData(from: reader)) != nil
            case .call:
                return (try? CallWireData(from: reader)) != nil
            case .resolve:
                return (try? ResolveWireData(from: reader)) != nil
            case .retrieve:
                return (try? RetrieveWireData(from: reader)) != nil
            case .update:
                return (try? UpdateWireData(from: reader)) != nil
            case .complete:
                return (try? CompleteWireData(from: reader)) != nil
            case .returnEvent:
                return (try? ReturnWireData(from: reader)) != nil
            }
        }
    }

    private static func reached(_ nowMS: UInt32, _ deadlineMS: UInt32) -> Bool {
        Int32(bitPattern: nowMS &- deadlineMS) >= 0
    }
}

private struct AnyProtocolRouteClassifier: ProtocolRouteClassifier, Sendable {
    func classify(_ route: ByteSlice) -> ProtocolRouteClassification { route.length == 0 ? .unrelated : .coaty }
}
