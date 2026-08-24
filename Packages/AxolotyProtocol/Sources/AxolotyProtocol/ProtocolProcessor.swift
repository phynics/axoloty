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

    fileprivate var hasValidTopicFilter: Bool {
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

/// The result of one atomic processor operation.
public enum ProtocolProcessOutcome: Sendable, Equatable {
    /// The operation was accepted and appended to the sink.
    case accepted
    /// The route is unrelated to this binding.
    case ignored
    /// The operation was rejected without state mutation.
    case rejected(ProtocolError.Code)
}

/// A closed borrowed input accepted by the protocol processor.
public enum BorrowedProtocolInput {
    /// A Coaty profile frame with a parsed routing key and borrowed payload.
    case profile(BorrowedProtocolFrame)
    /// An exact external IO route and its borrowed payload.
    case externalIo(route: ByteSlice, payload: ByteSlice)
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
    private enum StoredAssociationRouteKind: Equatable {
        case coaty
        case external

        var classification: ProtocolRouteClassification {
            switch self {
            case .coaty: return .coaty
            case .external: return .external
            }
        }
    }

    private enum ObjectRole {
        case other
        case ioSource
        case ioActor
    }

    private struct Association {
        var sourceID = UUID16.zero
        var actorID = UUID16.zero
        var active = false
        var routeLength = 0
        var route = InlineArray<128, UInt8>(repeating: 0)
        var routeKind: StoredAssociationRouteKind = .coaty
        var updateRateMS: UInt32?
    }

    private struct ObjectRecord {
        /// Identity of the advertised object, distinct from its source agent.
        var id = UUID16.zero
        var sourceID = UUID16.zero
        var active = false
        var local = false
        var announced = false
        var role: ObjectRole = .other
    }

    private struct PendingRecord {
        var id = UUID16.zero
        var deadlineMS: UInt32?
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
        case insert(Int, UUID16, UUID16, Bool, ObjectRole)
        case replay(Int)
        case remove(Int)
    }

    /// The shared fixed-inline object transition prepared before sink
    /// preflight. Both wire directions use this exact plan and commit path.
    private enum ObjectTransitionResult {
        case accepted(ObjectPlan, InlineArray<capacity, Bool>)
        case rejected(ProtocolError.Code)
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

    /// Returns the complete association projection for a local or remote source.
    public borrowing func ioAssociationState(forSource id: UUID16) -> IoAssociationState {
        associationState(matchingSource: id, actor: nil)
    }

    /// Returns the complete association projection for a local or remote actor.
    public borrowing func ioAssociationState(forActor id: UUID16) -> IoAssociationState {
        associationState(matchingSource: nil, actor: id)
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
                  let deadlineMS = pending[index].deadlineMS,
                  Self.reached(nowMS, deadlineMS) else { continue }
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

    /// Processes a closed borrowed inbound input.
    ///
    /// - Parameters:
    ///   - input: Profile frame or exact external IO input valid for this call.
    ///   - nowMS: Caller-supplied monotonic time in milliseconds.
    ///   - sink: Caller-owned action destination.
    /// - Returns: The atomic transition result.
    public mutating func processInbound<S: ~Copyable & ProtocolActionSink>(_ input: BorrowedProtocolInput, nowMS: UInt32, sink: inout S) -> ProtocolProcessOutcome {
        processInbound(input, nowMS: nowMS, classifier: AnyProtocolRouteClassifier(), sink: &sink)
    }

    /// Processes a closed inbound input with a binding-owned route classifier.
    ///
    /// - Parameters:
    ///   - input: Profile frame or exact external IO input valid for this call.
    ///   - nowMS: Caller-supplied monotonic time in milliseconds.
    ///   - classifier: Binding-owned association-route classifier.
    ///   - sink: Caller-owned action destination.
    /// - Returns: The atomic transition result.
    public mutating func processInbound<Classifier: ProtocolRouteClassifier, S: ~Copyable & ProtocolActionSink>(_ input: BorrowedProtocolInput, nowMS: UInt32, classifier: Classifier, sink: inout S) -> ProtocolProcessOutcome {
        switch input {
        case .profile(let frame):
            return processProfileInbound(frame, nowMS: nowMS, classifier: classifier, sink: &sink)
        case .externalIo(let route, let payload):
            return processExternalInbound(route: route, payload: payload, nowMS: nowMS, classifier: classifier, sink: &sink)
        }
    }

    private mutating func processProfileInbound<Classifier: ProtocolRouteClassifier, S: ~Copyable & ProtocolActionSink>(_ frame: BorrowedProtocolFrame, nowMS: UInt32, classifier: Classifier, sink: inout S) -> ProtocolProcessOutcome {
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
        var deadvertiseMask = InlineArray<capacity, Bool>(repeating: false)

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
                if let deadlineMS = pending[matchingIndex].deadlineMS,
                   Self.reached(nowMS, deadlineMS) {
                    return .rejected(.deadlineExpired)
                }
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
        let objectTransition = planObjectTransition(
            capability: frame.routingKey.capability,
            payload: frame.payload,
            sourceID: frame.routingKey.sourceID,
            local: false
        )
        let objectPlan: ObjectPlan
        switch objectTransition {
        case .accepted(let value, let mask):
            objectPlan = value
            deadvertiseMask = mask
        case .rejected(let code):
            return .rejected(code)
        }
        let associationLifecycleCount: Int
        if frame.routingKey.capability == .associate {
            associationLifecycleCount = lifecycleEffectCount(for: plan)
        } else {
            associationLifecycleCount = 0
        }
        let actionCount = frame.routingKey.capability == .associate
            ? 1 + associationLifecycleCount
            : max(1, ioActorActionCount)
        // Classification and all rejection-only validation precede sink
        // capacity so unrelated routes and contradictory flags retain their
        // semantic outcomes even when the caller's sink is full.
        guard sink.preflight(actionCount: actionCount) else { return .rejected(.capacityExceeded) }
        if ioActorActionCount > 0 {
            for index in 0..<capacity where associations[index].active && associations[index].sourceID == frame.routingKey.sourceID {
                let delivery = BorrowedProtocolDelivery(
                    routingKey: frame.routingKey,
                    deliveryKey: .ioActor(associations[index].actorID),
                    routeClassification: associations[index].routeKind.classification,
                    topic: frame.topic,
                    payload: frame.payload
                )
                let action = BorrowedProtocolAction.deliver(delivery)
                guard sink.append(action) else { return .rejected(.capacityExceeded) }
            }
        } else if frame.routingKey.capability == .associate {
            let reader = frame.payload.withBytes { pointer, length in
                WireReader(bytes: pointer.assumingMemoryBound(to: UInt8.self), length: length)
            }
            guard let event = try? AssociateWireData(from: reader) else { return .rejected(.malformedPayload) }
            let oldAssociation: Association?
            let proposedAssociation: Association?
            switch plan {
            case .remove(let index):
                oldAssociation = associations[index]
                proposedAssociation = nil
            case .upsert(let index, let association):
                oldAssociation = associations[index].active ? associations[index] : nil
                proposedAssociation = association
            case .none:
                oldAssociation = nil
                proposedAssociation = nil
            }
            let change: ProtocolIoAssociationChange
            switch plan {
            case .remove: change = .removed
            case .upsert(let index, _): change = associations[index].active ? .updated : .established
            case .none: change = .established
            }
            let transitionClassification = proposedAssociation?.routeKind.classification
                ?? oldAssociation?.routeKind.classification
                ?? routeClassification
            let delivery = BorrowedProtocolDelivery(
                routingKey: frame.routingKey,
                deliveryKey: deliveryKey(for: frame),
                routeClassification: transitionClassification,
                topic: frame.topic,
                payload: frame.payload
            )
            let transitionRoute: BorrowedProtocolRouteSnapshot?
            if let proposedAssociation {
                transitionRoute = associationRouteSnapshot(proposedAssociation)
            } else if let oldAssociation {
                transitionRoute = associationRouteSnapshot(oldAssociation)
            } else {
                transitionRoute = nil
            }

            let localActor = isLocalIoActor(event.ioActorId)
            if localActor,
               let oldAssociation,
               oldAssociation.routeKind == .external,
               (proposedAssociation == nil || proposedAssociation!.routeKind != .external || !Self.routeEquals(oldAssociation, proposedAssociation!)),
               let route = associationRouteSnapshot(oldAssociation) {
                guard sink.append(.externalRouteDeactivated(BorrowedExternalRouteTransition(
                    sourceID: oldAssociation.sourceID,
                    actorID: oldAssociation.actorID,
                    route: route
                ))) else { return .rejected(.capacityExceeded) }
            }
            let transition = BorrowedIoAssociationTransition(
                delivery: delivery,
                sourceID: event.ioSourceId,
                actorID: event.ioActorId,
                change: change,
                route: transitionRoute,
                routeClassification: transitionClassification
            )
            guard sink.append(.associationChanged(transition)) else { return .rejected(.capacityExceeded) }

            if localActor,
               let proposedAssociation,
               proposedAssociation.routeKind == .external,
               (oldAssociation == nil || oldAssociation!.routeKind != .external || !Self.routeEquals(oldAssociation!, proposedAssociation)),
               let route = associationRouteSnapshot(proposedAssociation) {
                guard sink.append(.externalRouteActivated(BorrowedExternalRouteTransition(
                    sourceID: proposedAssociation.sourceID,
                    actorID: proposedAssociation.actorID,
                    route: route
                ))) else { return .rejected(.capacityExceeded) }
            }
        } else {
            let action = BorrowedProtocolAction.deliver(BorrowedProtocolDelivery(
                routingKey: frame.routingKey,
                deliveryKey: deliveryKey(for: frame),
                routeClassification: routeClassification,
                topic: frame.topic,
                payload: frame.payload
            ))
            guard sink.append(action) else { return .rejected(.capacityExceeded) }
        }
        if let responsePlan {
            if Self.isTerminalResponse(frame.routingKey.capability) {
                pending[responsePlan.index].state = .resolved
            }
        }
        commitTransition(associationPlan: plan, objectPlan: objectPlan, deadvertiseMask: deadvertiseMask)
        return .accepted
    }

    private mutating func processExternalInbound<Classifier: ProtocolRouteClassifier, S: ~Copyable & ProtocolActionSink>(
        route: ByteSlice,
        payload: ByteSlice,
        nowMS: UInt32,
        classifier: Classifier,
        sink: inout S
    ) -> ProtocolProcessOutcome {
        guard route.length > 0, route.length <= 128,
              classifier.classify(route) == .external else { return .ignored }
        guard payload.length <= maximumPayloadBytes,
              validatePayload(payload, for: .ioValue) else { return .rejected(.malformedPayload) }

        var matching = 0
        for index in 0..<capacity {
            let association = associations[index]
            guard association.active,
                  association.routeKind == .external,
                  Self.routeEquals(association, route, kind: .external),
                  isLocalIoActor(association.actorID) else { continue }
            matching += 1
        }
        guard matching > 0 else { return .ignored }
        guard sink.preflight(actionCount: matching) else { return .rejected(.capacityExceeded) }

        for index in 0..<capacity {
            let association = associations[index]
            guard association.active,
                  association.routeKind == .external,
                  Self.routeEquals(association, route, kind: .external),
                  isLocalIoActor(association.actorID) else { continue }
            guard let routingKey = try? ProtocolRoutingKey(capability: .ioValue, sourceID: association.sourceID, correlationID: nil) else {
                return .rejected(.invalidCorrelation)
            }
            let delivery = BorrowedProtocolDelivery(
                routingKey: routingKey,
                deliveryKey: .ioActor(association.actorID),
                routeClassification: .external,
                topic: route,
                payload: payload
            )
            guard sink.append(.deliver(delivery)) else { return .rejected(.capacityExceeded) }
        }
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
        guard operation.hasValidTopicFilter else { return .rejected(.malformedFrame) }
        guard operation.payload.length <= maximumPayloadBytes else { return .rejected(.capacityExceeded) }
        let valid = validatePayload(operation.payload, for: operation.capability)
        guard valid else { return .rejected(.malformedPayload) }
        guard let key = try? ProtocolRoutingKey(capability: operation.capability, sourceID: operation.sourceID, correlationID: operation.correlationID) else { return .rejected(.invalidCorrelation) }
        var requestPlan: (index: Int, correlationID: UUID16, deadlineMS: UInt32?)?
        switch operation.capability {
        case .discover, .query, .update, .call:
            guard let correlation = operation.correlationID,
                  let index = pendingSlot(for: correlation) else {
                return .rejected(.capacityExceeded)
            }
            let deadlineMS: UInt32?
            if let timeout = operation.requestTimeoutMS {
                guard timeout > 0 else { return .rejected(.deadlineExpired) }
                deadlineMS = nowMS &+ timeout
            } else {
                deadlineMS = nil
            }
            requestPlan = (index, correlation, deadlineMS)
        default:
            break
        }
        let objectTransition = planObjectTransition(
            capability: operation.capability,
            payload: operation.payload,
            sourceID: operation.sourceID,
            local: true
        )
        let objectPlan: ObjectPlan
        var deadvertiseMask = InlineArray<capacity, Bool>(repeating: false)
        switch objectTransition {
        case .accepted(let value, let mask):
            objectPlan = value
            deadvertiseMask = mask
        case .rejected(let code):
            return .rejected(code)
        }
        let plan: AssociationPlan
        if operation.capability == .associate {
            let associateReader = operation.payload.withBytes { pointer, length in
                WireReader(bytes: pointer.assumingMemoryBound(to: UInt8.self), length: length)
            }
            if let associate = try? AssociateWireData(from: associateReader), associate.isExternalRoute != nil {
                return .rejected(.externalRouteMismatch)
            }
            switch planAssociation(operation.payload, classifier: classifier) {
            case .accepted(let value, _):
                plan = value
            case .ignored: return .ignored
            case .rejected(let code): return .rejected(code)
            }
        } else {
            plan = .none
        }
        if operation.capability == .ioValue {
            var routeIndices = InlineArray<capacity, Int>(repeating: -1)
            var routeCount = 0
            for index in 0..<capacity {
                let association = associations[index]
                guard association.active,
                      association.sourceID == operation.sourceID,
                      association.routeLength > 0 else { continue }
                var duplicate = false
                for routeIndex in 0..<routeCount {
                    if Self.routeEquals(association, associations[routeIndices[routeIndex]]) {
                        duplicate = true
                        break
                    }
                }
                guard !duplicate else { continue }
                routeIndices[routeCount] = index
                routeCount += 1
            }
            guard routeCount > 0 else { return .ignored }
            guard sink.preflight(actionCount: routeCount) else { return .rejected(.capacityExceeded) }
            for routeIndex in 0..<routeCount {
                let associationIndex = routeIndices[routeIndex]
                let association = associations[associationIndex]
                let appended = withUnsafeBytes(of: associations[associationIndex].route) { buffer in
                    let route = ByteSlice(
                        bytes: buffer.baseAddress!.assumingMemoryBound(to: UInt8.self),
                        length: association.routeLength
                    )
                    return sink.append(.publish(BorrowedProtocolPublication(
                        routingKey: key,
                        target: .associationRoute(route: route, kind: association.routeKind.classification),
                        payload: operation.payload,
                        isApplicationDelivery: routeIndex == 0
                    )))
                }
                guard appended else { return .rejected(.capacityExceeded) }
            }
        } else {
            let filters = outboundEventTypeFilters(for: operation)
            let actionCount = filters.secondary == nil ? 1 : 2
            guard sink.preflight(actionCount: actionCount) else { return .rejected(.capacityExceeded) }
            guard sink.append(.publish(BorrowedProtocolPublication(
                routingKey: key,
                target: .profile(
                    eventTypeFilter: filters.primary?.value,
                    filterKind: filters.primary?.kind ?? .direct
                ),
                payload: operation.payload,
                isApplicationDelivery: true
            ))) else { return .rejected(.capacityExceeded) }
            if let secondary = filters.secondary {
                guard sink.append(.publish(BorrowedProtocolPublication(
                    routingKey: key,
                    target: .profile(
                        eventTypeFilter: secondary.value,
                        filterKind: secondary.kind
                    ),
                    payload: operation.payload,
                    isApplicationDelivery: false
                ))) else { return .rejected(.capacityExceeded) }
            }
        }
        if let requestPlan {
            pending[requestPlan.index] = PendingRecord(
                id: requestPlan.correlationID,
                deadlineMS: requestPlan.deadlineMS,
                state: .active(Self.requestKind(for: operation.capability))
            )
        }
        commitTransition(associationPlan: plan, objectPlan: objectPlan, deadvertiseMask: deadvertiseMask)
        return .accepted
    }

    private func deliveryKey(for frame: BorrowedProtocolFrame) -> BorrowedProtocolDeliveryKey {
        switch frame.routingKey.capability {
        case .advertise:
            if let objectType = Self.advertisedObjectType(frame.payload) {
                return .advertiseFilter(objectType)
            }
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

    private func deliveryKey(for operation: ProtocolLocalOperation) -> BorrowedProtocolDeliveryKey {
        switch operation {
        case .advertise:
            if let objectType = Self.advertisedObjectType(operation.payload) {
                return .advertiseFilter(objectType)
            }
        case .resolve, .retrieve, .complete, .returnEvent:
            if let correlation = operation.correlationID {
                return .correlated(operation.capability, correlation)
            }
        default:
            break
        }
        return .capability(operation.capability)
    }

    private static func advertisedObjectType(_ payload: ByteSlice) -> ByteSlice? {
        advertisedObjectField("objectType", payload: payload)
    }

    private static func advertisedObjectRole(_ payload: ByteSlice) -> ObjectRole {
        guard let coreType = advertisedObjectField("coreType", payload: payload) else { return .other }
        if coreType.equals("IoSource") { return .ioSource }
        if coreType.equals("IoActor") { return .ioActor }
        return .other
    }

    private static func advertisedObjectField(_ field: StaticString, payload: ByteSlice) -> ByteSlice? {
        payload.withBytes { pointer, length in
            let reader = WireReader(bytes: pointer.assumingMemoryBound(to: UInt8.self), length: length)
            guard let object = reader.readRaw("object") else { return nil }
            return object.withBytes { objectPointer, objectLength in
                let objectReader = WireReader(
                    bytes: objectPointer.assumingMemoryBound(to: UInt8.self),
                    length: objectLength
                )
                return objectReader.readString(field)
            }
        }
    }

    private func outboundEventTypeFilters(
        for operation: ProtocolLocalOperation
    ) -> (
        primary: (value: ByteSlice, kind: ProtocolEventTypeFilterKind)?,
        secondary: (value: ByteSlice, kind: ProtocolEventTypeFilterKind)?
    ) {
        switch operation.capability {
        case .advertise:
            guard let coreType = Self.advertisedObjectField("coreType", payload: operation.payload) else {
                return (nil, nil)
            }
            guard Self.equals(coreType, "CoatyObject"),
                  let objectType = Self.advertisedObjectType(operation.payload) else {
                return ((coreType, .direct), nil)
            }
            return ((coreType, .direct), (objectType, .objectType))
        case .update:
            guard let coreType = Self.advertisedObjectField("coreType", payload: operation.payload) else {
                return (nil, nil)
            }
            return ((coreType, .direct), nil)
        case .channel, .call, .associate:
            return (operation.operationName.map { ($0, .direct) }, nil)
        default:
            return (nil, nil)
        }
    }

    private static func equals(_ slice: ByteSlice, _ value: StaticString) -> Bool {
        guard slice.length == value.utf8CodeUnitCount else { return false }
        for index in 0..<slice.length where slice.byte(at: index) != value.utf8Start[index] {
            return false
        }
        return true
    }

    private func planAssociation<Classifier: ProtocolRouteClassifier>(_ payload: ByteSlice, classifier: Classifier) -> AssociationResult {
        let reader = payload.withBytes { pointer, length in WireReader(bytes: pointer.assumingMemoryBound(to: UInt8.self), length: length) }
        guard let event = try? AssociateWireData(from: reader) else { return .rejected(.malformedPayload) }
        let updateRateMS: UInt32?
        if let rawRate = event.updateRate {
            guard rawRate >= 0, UInt64(rawRate) <= UInt64(UInt32.max) else { return .rejected(.malformedPayload) }
            updateRateMS = UInt32(rawRate)
        } else {
            updateRateMS = nil
        }
        guard let route = event.associatingRoute else {
            if event.isExternalRoute == true { return .rejected(.externalRouteMismatch) }
            for index in 0..<capacity where associations[index].active && associations[index].sourceID == event.ioSourceId && associations[index].actorID == event.ioActorId {
                return .accepted(.remove(index), associations[index].routeKind.classification)
            }
            return .ignored
        }
        guard route.length > 0, route.length <= 128 else { return .rejected(.capacityExceeded) }
        let classification = classifier.classify(route)
        if let explicit = event.isExternalRoute, explicit != (classification == .external) { return .rejected(.externalRouteMismatch) }
        if classification == .unrelated { return .ignored }
        let routeKind: StoredAssociationRouteKind = classification == .external ? .external : .coaty
        for index in 0..<capacity where associations[index].active && associations[index].sourceID == event.ioSourceId && associations[index].actorID == event.ioActorId {
            var association = associations[index]
            association.routeLength = route.length
            for offset in 0..<route.length { association.route[offset] = route.byte(at: offset) ?? 0 }
            association.routeKind = routeKind
            association.updateRateMS = updateRateMS
            guard !Self.routeEquals(associations[index], association) || associations[index].updateRateMS != updateRateMS else {
                return .ignored
            }
            return .accepted(.upsert(index, association), classification)
        }
        for index in 0..<capacity where !associations[index].active {
            var association = Association(
                sourceID: event.ioSourceId,
                actorID: event.ioActorId,
                active: true,
                routeLength: route.length,
                route: InlineArray(repeating: 0),
                routeKind: routeKind,
                updateRateMS: updateRateMS
            )
            for offset in 0..<route.length { association.route[offset] = route.byte(at: offset) ?? 0 }
            return .accepted(.upsert(index, association), classification)
        }
        return .rejected(.capacityExceeded)
    }

    private func planObjectTransition(
        capability: ProtocolCapability,
        payload: ByteSlice,
        sourceID: UUID16,
        local: Bool
    ) -> ObjectTransitionResult {
        var deadvertiseMask = InlineArray<capacity, Bool>(repeating: false)
        switch capability {
        case .advertise:
            let objectID = Self.advertisedObjectID(payload) ?? sourceID
            let role = Self.advertisedObjectRole(payload)
            var activeCount = 0
            var freeIndex: Int?
            var replayIndex: Int?
            for index in 0..<capacity {
                if objects[index].active {
                    activeCount += 1
                    guard objects[index].sourceID == sourceID, objects[index].id == objectID else { continue }
                    if local && objects[index].local && !objects[index].announced {
                        replayIndex = index
                    } else {
                        return .rejected(.duplicate)
                    }
                } else if freeIndex == nil {
                    freeIndex = index
                }
            }
            if let replayIndex {
                return .accepted(.replay(replayIndex), deadvertiseMask)
            }
            guard activeCount < maximumObjects, let freeIndex else {
                return .rejected(.capacityExceeded)
            }
            return .accepted(.insert(freeIndex, sourceID, objectID, local, role), deadvertiseMask)
        case .deadvertise:
            let result = markDeadvertisedObjects(payload, sourceID: sourceID, into: &deadvertiseMask)
            guard result.valid, result.matched > 0 else {
                return .rejected(.malformedFrame)
            }
            return .accepted(.none, deadvertiseMask)
        default:
            return .accepted(.none, deadvertiseMask)
        }
    }

    private mutating func commitTransition(
        associationPlan: AssociationPlan,
        objectPlan: ObjectPlan,
        deadvertiseMask: InlineArray<capacity, Bool>
    ) {
        apply(associationPlan)
        for index in 0..<capacity where deadvertiseMask[index] {
            objects[index] = ObjectRecord()
        }
        apply(objectPlan)
        generation &+= 1
    }

    private mutating func apply(_ plan: AssociationPlan) {
        switch plan {
        case .none: return
        case .remove(let index): associations[index].active = false; associations[index].routeLength = 0
        case .upsert(let index, let association): associations[index] = association
        }
    }

    private func associationRouteSnapshot(_ association: Association) -> BorrowedProtocolRouteSnapshot? {
        let length = association.routeLength
        guard length > 0 else { return nil }
        var storage = InlineArray<128, UInt8>(repeating: 0)
        for offset in 0..<length { storage[offset] = association.route[offset] }
        return BorrowedProtocolRouteSnapshot(length: length, storage: storage)
    }

    private mutating func apply(_ plan: ObjectPlan) {
        switch plan {
        case .none: return
        case .insert(let index, let sourceID, let objectID, let local, let role):
            objects[index] = ObjectRecord(id: objectID, sourceID: sourceID, active: true, local: local, announced: true, role: role)
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

    private borrowing func associationState(matchingSource source: UUID16?, actor: UUID16?) -> IoAssociationState {
        var count = 0
        var recommended: UInt32?
        for index in 0..<capacity {
            let association = associations[index]
            guard association.active else { continue }
            if let source, association.sourceID != source { continue }
            if let actor, association.actorID != actor { continue }
            count += 1
            if let rate = association.updateRateMS {
                recommended = max(recommended ?? 0, rate)
            }
        }
        return IoAssociationState(
            generation: generation,
            hasAssociations: count > 0,
            associationCount: count,
            recommendedUpdateRateMS: recommended
        )
    }

    private borrowing func isLocalIoActor(_ id: UUID16) -> Bool {
        for index in 0..<capacity {
            guard objects[index].active, objects[index].local,
                  objects[index].id == id else { continue }
            return objects[index].role == .ioActor
        }
        return false
    }

    private borrowing func lifecycleEffectCount(for plan: AssociationPlan) -> Int {
        switch plan {
        case .none:
            return 0
        case .remove(let index):
            guard associations[index].routeKind == .external,
                  isLocalIoActor(associations[index].actorID) else { return 0 }
            return 1
        case .upsert(let index, let proposed):
            guard isLocalIoActor(proposed.actorID) else { return 0 }
            let old = associations[index].active ? associations[index] : nil
            let oldExternal = old?.routeKind == .external
            let newExternal = proposed.routeKind == .external
            let routeChanged = old.map { !Self.routeEquals($0, proposed) } ?? true
            return (oldExternal && (!newExternal || routeChanged) ? 1 : 0)
                + (newExternal && (!oldExternal || routeChanged) ? 1 : 0)
        }
    }

    private static func routeEquals(
        _ association: Association,
        _ route: ByteSlice,
        kind: StoredAssociationRouteKind
    ) -> Bool {
        guard association.routeKind == kind, association.routeLength == route.length else { return false }
        for index in 0..<route.length {
            guard let byte = route.byte(at: index), association.route[index] == byte else { return false }
        }
        return true
    }

    private static func routeEquals(
        _ lhs: Association,
        _ rhs: Association
    ) -> Bool {
        guard lhs.routeKind == rhs.routeKind, lhs.routeLength == rhs.routeLength else { return false }
        for index in 0..<lhs.routeLength where lhs.route[index] != rhs.route[index] { return false }
        return true
    }

    private func markDeadvertisedObjects(
        _ payload: ByteSlice,
        sourceID: UUID16,
        into mask: inout InlineArray<capacity, Bool>
    ) -> (valid: Bool, matched: Int) {
        var valid = true
        var matched = 0
        payload.withBytes { pointer, length in
            let reader = WireReader(bytes: pointer.assumingMemoryBound(to: UInt8.self), length: length)
            guard let rawIDs = reader.readRaw("objectIds") else {
                valid = false
                return
            }
            do throws(WireDecodeError) {
                try rawIDs.withArrayElements { element in
                    guard element.wireValueKind == .string,
                          element.length >= 2,
                          let objectID = UUID16(parsing: element.subSlice(from: 1, length: element.length - 2)) else {
                        valid = false
                        return
                    }
                    for index in 0..<capacity where objects[index].active && !mask[index] {
                        guard objects[index].sourceID == sourceID, objects[index].id == objectID else { continue }
                        mask[index] = true
                        matched += 1
                    }
                }
            } catch {
                valid = false
            }
        }
        return (valid, matched)
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
