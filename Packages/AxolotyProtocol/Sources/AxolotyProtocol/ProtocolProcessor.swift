// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@_spi(AxolotyProtocol) import AxolotyWire

/// Opt-in soft-state presence handling for `axoloty/1` Advertise frames.
public enum ProtocolPresencePolicy: Sendable, Equatable {
    /// Presence is ignored; the processor behaves exactly as before.
    case disabled
    /// Leased Advertise frames renew, re-announce, and expire.
    case enabled
}

/// A presence policy that cannot be applied to the selected wire profile.
public enum ProtocolPresenceConfigurationError: Error, Sendable, Equatable {
    /// Presence is an `axoloty/1` feature; `coaty/3` stays sealed.
    case unsupportedWireProfile
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
        var route = ProtocolRouteStorage(repeating: 0)
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
        /// Declared presence lease in milliseconds; zero means no lease.
        var leaseMS: UInt32 = 0
        /// Caller-supplied time of the last announce or renew.
        var lastSeenMS: UInt32 = 0
        /// Owner incarnation; zero means no presence epoch.
        var ownerEpoch: UInt32 = 0
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

    private enum PresenceState {
        case disabled
        case active
        case suspended
    }

    private struct PresenceLease {
        var leaseMS: UInt32
        var ownerEpoch: UInt32
    }

    /// Packed association indices and exact action count for one re-announce.
    private struct AssociationReleasePlan {
        var indices = InlineArray<capacity, Int>(repeating: -1)
        var count = 0
        var actionCount = 0
    }

    private var associations: InlineArray<capacity, Association>
    private var objects: InlineArray<capacity, ObjectRecord>
    private var pending: InlineArray<capacity, PendingRecord>
    private var generation: UInt32 = 0
    private let capabilities: ProtocolCapabilities
    private let codec: WireCodec
    private let maximumPayloadBytes: Int
    private let maximumObjects: Int
    private let maximumPendingCorrelations: Int
    private var presenceState: PresenceState

    /// Creates a processor with caller-selected capabilities and fixed limits.
    ///
    /// The processor contains no encoding conditional: every payload decode
    /// and encode is forwarded to `wireCodec`, which selects the JSON or CBOR
    /// engine behind the format-neutral reader and writer.
    ///
    /// - Parameters:
    ///   - capabilities: Families accepted by this binding.
    ///   - wireCodec: The wire profile this binding selects at composition
    ///     time. Defaults to `coaty/3` JSON.
    ///   - maximumPayloadBytes: Largest accepted borrowed payload.
    ///   - maximumObjects: Maximum simultaneous advertised objects.
    ///   - maximumPendingCorrelations: Maximum outstanding requests.
    public init(
        capabilities: ProtocolCapabilities = .coatyCore3,
        wireCodec: WireCodec = WireCodec(profile: .coaty3JSON),
        maximumPayloadBytes: Int = WireBufferConfig.maxPayloadSize,
        maximumObjects: Int = capacity,
        maximumPendingCorrelations: Int = capacity
    ) {
        self.init(
            capabilities: capabilities,
            wireCodec: wireCodec,
            maximumPayloadBytes: maximumPayloadBytes,
            maximumObjects: maximumObjects,
            maximumPendingCorrelations: maximumPendingCorrelations,
            presenceState: .disabled
        )
    }

    /// Creates a processor with an explicit presence policy.
    ///
    /// Presence is an `axoloty/1` feature; enabling it with any other wire
    /// profile throws before any state is initialized.
    ///
    /// - Parameters:
    ///   - capabilities: Families accepted by this binding.
    ///   - wireCodec: The selected wire profile.
    ///   - maximumPayloadBytes: Largest accepted borrowed payload.
    ///   - maximumObjects: Maximum simultaneous advertised objects.
    ///   - maximumPendingCorrelations: Maximum outstanding requests.
    ///   - presencePolicy: Whether leased Advertise frames renew and expire.
    /// - Throws: ``ProtocolPresenceConfigurationError/unsupportedWireProfile``
    ///   when presence is enabled for a non-`axoloty/1` codec.
    public init(
        capabilities: ProtocolCapabilities = .coatyCore3,
        wireCodec: WireCodec,
        maximumPayloadBytes: Int = WireBufferConfig.maxPayloadSize,
        maximumObjects: Int = capacity,
        maximumPendingCorrelations: Int = capacity,
        presencePolicy: ProtocolPresencePolicy
    ) throws(ProtocolPresenceConfigurationError) {
        if presencePolicy == .enabled, wireCodec.profile != .axoloty1CBOR {
            throw .unsupportedWireProfile
        }
        self.init(
            capabilities: capabilities,
            wireCodec: wireCodec,
            maximumPayloadBytes: maximumPayloadBytes,
            maximumObjects: maximumObjects,
            maximumPendingCorrelations: maximumPendingCorrelations,
            presenceState: presencePolicy == .enabled ? .active : .disabled
        )
    }

    private init(
        capabilities: ProtocolCapabilities,
        wireCodec: WireCodec,
        maximumPayloadBytes: Int,
        maximumObjects: Int,
        maximumPendingCorrelations: Int,
        presenceState: PresenceState
    ) {
        self.capabilities = capabilities
        self.codec = wireCodec
        self.maximumPayloadBytes = maximumPayloadBytes
        self.associations = InlineArray(repeating: Association())
        self.objects = InlineArray(repeating: ObjectRecord())
        self.pending = InlineArray(repeating: PendingRecord())
        self.maximumObjects = min(max(0, maximumObjects), capacity)
        self.maximumPendingCorrelations = min(max(0, maximumPendingCorrelations), capacity)
        self.presenceState = presenceState
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

    /// Removes the first leased peer object whose lease has elapsed.
    ///
    /// This is the presence pass, separate from request `expire`. It removes
    /// only the object record; Associate rows stay until a wire signal or a
    /// reset releases them. The caller loops until it returns `nil`.
    ///
    /// - Parameter nowMS: Caller-supplied monotonic time in milliseconds.
    /// - Returns: The removed source and object identities, or `nil`.
    public mutating func expirePresence(nowMS: UInt32) -> (sourceID: UUID16, objectID: UUID16)? {
        guard presenceState == .active else { return nil }
        for index in 0..<capacity {
            let object = objects[index]
            guard object.active, !object.local, object.leaseMS > 0 else { continue }
            guard Self.reached(nowMS, object.lastSeenMS &+ object.leaseMS) else { continue }
            objects[index] = ObjectRecord()
            generation &+= 1
            return (object.sourceID, object.id)
        }
        return nil
    }

    /// Suspends peer expiry for an interrupted transport.
    ///
    /// Leased peer entries and local replayable entries survive; unleased peer
    /// entries are discarded like a hard reset. Like ``resetTransport()``, it
    /// also clears every association row and every pending request correlation;
    /// a re-announce after resume re-establishes routing. The first suspend on
    /// the active edge advances the generation even when no entry changes;
    /// repeated calls on the suspended edge are idempotent.
    public mutating func suspendPresence() {
        guard presenceState == .active else { return }
        for index in 0..<capacity {
            associations[index] = Association()
            pending[index] = PendingRecord()
            if objects[index].active && objects[index].local {
                objects[index].announced = false
            } else if objects[index].active && objects[index].leaseMS > 0 {
                continue
            } else {
                objects[index] = ObjectRecord()
            }
        }
        presenceState = .suspended
        generation &+= 1
    }

    /// Re-bases retained leased peers after the transport is usable again.
    ///
    /// The caller supplies the resume time; the processor never reads a clock.
    /// Only peer entries are re-based; local entries keep their own time.
    /// Repeated calls on the resolved edge are idempotent, and a resume without
    /// a preceding suspend is a no-op that neither re-bases nor advances the
    /// generation.
    ///
    /// - Parameter nowMS: Caller-supplied monotonic time in milliseconds.
    public mutating func resumePresence(nowMS: UInt32) {
        guard presenceState == .suspended else { return }
        for index in 0..<capacity where objects[index].active && !objects[index].local && objects[index].leaseMS > 0 {
            objects[index].lastSeenMS = nowMS
        }
        presenceState = .active
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
    ///
    /// With presence enabled this is a hard reset: it discards leased peers,
    /// clears any suspension, and returns the policy to active. Soft transport
    /// loss must use ``suspendPresence()`` and ``resumePresence(nowMS:)`` so a
    /// short reconnect inside the lease causes no departure.
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
        if presenceState != .disabled { presenceState = .active }
        generation &+= 1
    }

    /// Processes a closed borrowed inbound input.
    ///
    /// - Parameters:
    ///   - input: Profile frame or exact external IO input valid for this call.
    ///   - nowMS: Caller-supplied monotonic time in milliseconds.
    ///   - maximumTopicLength: Maximum profile topic length accepted by this
    ///     binding. The default is the bounded wire limit.
    ///   - sink: Caller-owned action destination.
    /// - Returns: The atomic transition result.
    public mutating func processInbound<S: ~Copyable & ProtocolActionSink>(
        _ input: BorrowedProtocolInput,
        nowMS: UInt32,
        maximumTopicLength: Int = WireBufferConfig.maxTopicLength,
        sink: inout S
    ) -> ProtocolProcessOutcome {
        processInbound(
            input,
            nowMS: nowMS,
            classifier: AnyProtocolRouteClassifier(),
            maximumTopicLength: maximumTopicLength,
            sink: &sink
        )
    }

    /// Processes a closed inbound input with a binding-owned route classifier.
    ///
    /// - Parameters:
    ///   - input: Profile frame or exact external IO input valid for this call.
    ///   - nowMS: Caller-supplied monotonic time in milliseconds.
    ///   - classifier: Binding-owned association-route classifier.
    ///   - maximumTopicLength: Maximum profile topic length accepted by this
    ///     binding. The default is the bounded wire limit.
    ///   - sink: Caller-owned action destination.
    /// - Returns: The atomic transition result.
    public mutating func processInbound<Classifier: ProtocolRouteClassifier, S: ~Copyable & ProtocolActionSink>(
        _ input: BorrowedProtocolInput,
        nowMS: UInt32,
        classifier: Classifier,
        maximumTopicLength: Int = WireBufferConfig.maxTopicLength,
        sink: inout S
    ) -> ProtocolProcessOutcome {
        switch input {
        case .profile(let frame):
            return processProfileInbound(
                frame,
                nowMS: nowMS,
                classifier: classifier,
                maximumTopicLength: maximumTopicLength,
                sink: &sink
            )
        case .externalIo(let route, let payload):
            return processExternalInbound(route: route, payload: payload, nowMS: nowMS, classifier: classifier, sink: &sink)
        }
    }

    private mutating func processProfileInbound<Classifier: ProtocolRouteClassifier, S: ~Copyable & ProtocolActionSink>(
        _ frame: BorrowedProtocolFrame,
        nowMS: UInt32,
        classifier: Classifier,
        maximumTopicLength: Int,
        sink: inout S
    ) -> ProtocolProcessOutcome {
        guard capabilities.contains(frame.routingKey.capability) else { return .rejected(.unsupportedCapability) }
        guard maximumTopicLength >= 0,
              frame.topic.length <= maximumTopicLength,
              frame.payload.length <= maximumPayloadBytes,
              frame.payload.length <= sink.maximumPayloadBytes else {
            return .rejected(.capacityExceeded)
        }
        let valid = validatePayload(frame.payload, for: frame.routingKey.capability)
        guard valid else { return .rejected(.malformedPayload) }
        if presenceState != .disabled, frame.routingKey.capability == .advertise {
            return processPresenceAdvertise(frame, nowMS: nowMS, sink: &sink)
        }
        var ioActorActionCount = 0
        if frame.routingKey.capability == .ioValue {
            for index in 0..<capacity where matchesIoValue(index, source: frame.routingKey.sourceID) {
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
        var releaseMask = InlineArray<capacity, Bool>(repeating: false)
        var releaseCount = 0
        var externalReleaseCount = 0
        if frame.routingKey.capability == .deadvertise {
            for objectIndex in 0..<capacity where deadvertiseMask[objectIndex] {
                let removedID = objects[objectIndex].id
                for index in 0..<capacity where !releaseMask[index]
                    && associations[index].active
                    && (associations[index].sourceID == removedID || associations[index].actorID == removedID) {
                    releaseMask[index] = true
                    releaseCount += 1
                    if associations[index].routeKind == .external { externalReleaseCount += 1 }
                }
            }
        }
        let associationLifecycleCount: Int
        if frame.routingKey.capability == .associate {
            associationLifecycleCount = lifecycleEffectCount(for: plan)
        } else {
            associationLifecycleCount = 0
        }
        let actionCount = frame.routingKey.capability == .associate
            ? 1 + associationLifecycleCount
            : max(1, ioActorActionCount) + releaseCount + externalReleaseCount
        let frameDeliveryKey = deliveryKey(for: frame)
        guard Self.deliveryKeyFits(frameDeliveryKey) else { return .rejected(.capacityExceeded) }
        // Classification and all rejection-only validation precede sink
        // capacity so unrelated routes and contradictory flags retain their
        // semantic outcomes even when the caller's sink is full.
        guard sink.preflight(actionCount: actionCount) else { return .rejected(.capacityExceeded) }
        if ioActorActionCount > 0 {
            if let rejection = emitIoValueDeliveries(
                frame: frame,
                sink: &sink
            ) {
                return rejection
            }
        } else if frame.routingKey.capability == .associate {
            if let rejection = emitAssociationChange(
                plan: plan,
                frame: frame,
                frameDeliveryKey: frameDeliveryKey,
                routeClassification: routeClassification,
                sink: &sink
            ) {
                return rejection
            }
        } else {
            if let rejection = emitDeliveryAndReleases(
                frame: frame,
                frameDeliveryKey: frameDeliveryKey,
                routeClassification: routeClassification,
                releaseMask: releaseMask,
                sink: &sink
            ) {
                return rejection
            }
        }
        if let responsePlan {
            if Self.isTerminalResponse(frame.routingKey.capability) {
                pending[responsePlan.index].state = .resolved
            }
        }
        commitTransition(
            associationPlan: plan,
            objectPlan: objectPlan,
            deadvertiseMask: deadvertiseMask,
            releaseMask: releaseMask
        )
        return .accepted
    }

    /// Emits the deliveries for one IoValue frame's matching associations.
    ///
    /// Kept separate so the fixed delivery and action temporaries do not
    /// inflate the generic inbound frame's stack slot. `@inline(never)` is
    /// load-bearing: inlining this back into `processProfileInbound` restores
    /// the merged frame this split removes.
    /// - Returns: `nil` on success, or the rejection to propagate.
    @inline(never)
    private func emitIoValueDeliveries<S: ~Copyable & ProtocolActionSink>(
        frame: borrowing BorrowedProtocolFrame,
        sink: inout S
    ) -> ProtocolProcessOutcome? {
        for index in 0..<capacity where matchesIoValue(index, source: frame.routingKey.sourceID) {
            let delivery = BorrowedProtocolDelivery(
                routingKey: frame.routingKey,
                deliveryKey: .ioActor(associations[index].actorID),
                routeClassification: associations[index].routeKind.classification,
                topic: frame.topic,
                payload: frame.payload
            )
            guard sink.append(.deliver(delivery)) else { return .rejected(.capacityExceeded) }
        }
        return nil
    }

    /// Emits the delivery for a one-way frame and the association releases that
    /// a Deadvertise triggered.
    ///
    /// Kept separate so the fixed delivery, route, and action temporaries do
    /// not inflate the generic inbound frame's stack slot. `@inline(never)` is
    /// load-bearing: inlining this back into `processProfileInbound` restores
    /// the merged frame this split removes.
    /// - Returns: `nil` on success, or the rejection to propagate.
    @inline(never)
    private func emitDeliveryAndReleases<S: ~Copyable & ProtocolActionSink>(
        frame: borrowing BorrowedProtocolFrame,
        frameDeliveryKey: BorrowedProtocolDeliveryKey,
        routeClassification: ProtocolRouteClassification,
        releaseMask: borrowing InlineArray<capacity, Bool>,
        sink: inout S
    ) -> ProtocolProcessOutcome? {
        let delivery = BorrowedProtocolDelivery(
            routingKey: frame.routingKey,
            deliveryKey: frameDeliveryKey,
            routeClassification: routeClassification,
            topic: frame.topic,
            payload: frame.payload
        )
        guard sink.append(.deliver(delivery)) else { return .rejected(.capacityExceeded) }
        // A Deadvertise removes the advertised identities the sender owns.
        // An association endpoint is one of those identities: a lost peer
        // must not hold its Associate slots forever. The release is
        // reported against the Deadvertise frame that caused it, never as a
        // forged Associate delivery, so runtimes must not dispatch these
        // transitions as wire Associate events.
        for index in 0..<capacity where releaseMask[index] {
            guard emitAssociationRelease(at: index, delivery: delivery, sink: &sink) else {
                return .rejected(.capacityExceeded)
            }
        }
        return nil
    }

    /// Emits the association lifecycle actions for one accepted Associate
    /// frame.
    ///
    /// This is a separate function so its fixed route and association
    /// temporaries do not inflate the generic inbound frame's stack slot.
    /// `@inline(never)` is load-bearing: inlining this back into
    /// `processProfileInbound` restores the merged frame this split removes.
    ///
    /// - Returns: `nil` on success, or the rejection to propagate.
    @inline(never)
    private func emitAssociationChange<S: ~Copyable & ProtocolActionSink>(
        plan: borrowing AssociationPlan,
        frame: borrowing BorrowedProtocolFrame,
        frameDeliveryKey: BorrowedProtocolDeliveryKey,
        routeClassification: ProtocolRouteClassification,
        sink: inout S
    ) -> ProtocolProcessOutcome? {
        // Capture the small codec value, not `self`, inside the borrowed
        // payload closure. An unoptimized build otherwise materializes the
        // whole fixed processor for the closure context.
        let codec = self.codec
        let reader = frame.payload.withBytes { pointer, length in
            codec.reader(bytes: pointer.assumingMemoryBound(to: UInt8.self), length: length)
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
            deliveryKey: frameDeliveryKey,
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
            guard emitExternalRouteDeactivated(
                sourceID: oldAssociation.sourceID,
                actorID: oldAssociation.actorID,
                route: route,
                sink: &sink
            ) else { return .rejected(.capacityExceeded) }
        }
        guard emitAssociationTransition(
            delivery: delivery,
            sourceID: event.ioSourceId,
            actorID: event.ioActorId,
            change: change,
            route: transitionRoute,
            routeClassification: transitionClassification,
            sink: &sink
        ) else { return .rejected(.capacityExceeded) }

        if localActor,
           let proposedAssociation,
           proposedAssociation.routeKind == .external,
           (oldAssociation == nil || oldAssociation!.routeKind != .external || !Self.routeEquals(oldAssociation!, proposedAssociation)),
           let route = associationRouteSnapshot(proposedAssociation) {
            guard emitExternalRouteActivated(
                sourceID: proposedAssociation.sourceID,
                actorID: proposedAssociation.actorID,
                route: route,
                sink: &sink
            ) else { return .rejected(.capacityExceeded) }
        }
        return nil
    }

    /// Appends one association transition action.
    private func emitAssociationTransition<S: ~Copyable & ProtocolActionSink>(
        delivery: borrowing BorrowedProtocolDelivery,
        sourceID: UUID16,
        actorID: UUID16,
        change: ProtocolIoAssociationChange,
        route: borrowing BorrowedProtocolRouteSnapshot?,
        routeClassification: ProtocolRouteClassification,
        sink: inout S
    ) -> Bool {
        let transition = BorrowedIoAssociationTransition(
            delivery: delivery,
            sourceID: sourceID,
            actorID: actorID,
            change: change,
            route: route,
            routeClassification: routeClassification
        )
        return sink.append(.associationChanged(transition))
    }

    /// Appends one external-route deactivation action.
    private func emitExternalRouteDeactivated<S: ~Copyable & ProtocolActionSink>(
        sourceID: UUID16,
        actorID: UUID16,
        route: borrowing BorrowedProtocolRouteSnapshot,
        sink: inout S
    ) -> Bool {
        sink.append(.externalRouteDeactivated(BorrowedExternalRouteTransition(
            sourceID: sourceID,
            actorID: actorID,
            route: route
        )))
    }

    /// Appends one external-route activation action.
    private func emitExternalRouteActivated<S: ~Copyable & ProtocolActionSink>(
        sourceID: UUID16,
        actorID: UUID16,
        route: borrowing BorrowedProtocolRouteSnapshot,
        sink: inout S
    ) -> Bool {
        sink.append(.externalRouteActivated(BorrowedExternalRouteTransition(
            sourceID: sourceID,
            actorID: actorID,
            route: route
        )))
    }

    private enum PresenceParseResult {
        case success(PresenceLease?)
        case rejected(ProtocolError.Code)
    }

    private borrowing func presenceLease(from payload: ByteSlice) -> PresenceParseResult {
        let codec = self.codec
        let reader = payload.withBytes { pointer, length in
            codec.reader(bytes: pointer.assumingMemoryBound(to: UInt8.self), length: length)
        }
        guard let advertised = try? AdvertiseWireData(from: reader) else {
            return .rejected(.malformedPayload)
        }
        let declaredLease = advertised.leaseMS
        let declaredEpoch = advertised.ownerEpoch
        guard (declaredLease == nil) == (declaredEpoch == nil) else {
            return .rejected(.malformedPayload)
        }
        guard let declaredLease, let declaredEpoch else { return .success(nil) }
        guard (1_000...3_600_000).contains(declaredLease),
              (1...2_147_483_647).contains(declaredEpoch) else {
            return .rejected(.malformedPayload)
        }
        return .success(PresenceLease(
            leaseMS: UInt32(declaredLease),
            ownerEpoch: UInt32(declaredEpoch)
        ))
    }

    /// Processes one `axoloty/1` Advertise with opt-in presence.
    ///
    /// Kept out of line so the presence planner and release batch do not
    /// inflate the common receive frame.
    @inline(never)
    private mutating func processPresenceAdvertise<S: ~Copyable & ProtocolActionSink>(
        _ frame: BorrowedProtocolFrame,
        nowMS: UInt32,
        sink: inout S
    ) -> ProtocolProcessOutcome {
        guard frameProfile(frame) == .axoloty1CBOR else { return .rejected(.malformedFrame) }
        let presence: PresenceLease?
        switch presenceLease(from: frame.payload) {
        case .success(let value): presence = value
        case .rejected(let code): return .rejected(code)
        }

        let sourceID = frame.routingKey.sourceID
        let objectID = advertisedObjectID(frame.payload) ?? sourceID
        let role = advertisedObjectRole(frame.payload)
        var heldIndex: Int?
        for index in 0..<capacity where objects[index].active {
            guard objects[index].sourceID == sourceID, objects[index].id == objectID else { continue }
            heldIndex = index
            break
        }
        if let index = heldIndex {
            if objects[index].local { return .rejected(.duplicate) }
            if let presence,
               objects[index].leaseMS > 0,
               objects[index].ownerEpoch == presence.ownerEpoch {
                objects[index].lastSeenMS = nowMS
                objects[index].leaseMS = presence.leaseMS
                return .accepted
            }
            if presence == nil, objects[index].leaseMS == 0 { return .rejected(.duplicate) }
            return reannouncePresence(
                index: index,
                objectID: objectID,
                role: role,
                presence: presence,
                frame: frame,
                nowMS: nowMS,
                sink: &sink
            )
        }

        let deliveryKey = deliveryKey(for: frame)
        guard Self.deliveryKeyFits(deliveryKey) else { return .rejected(.capacityExceeded) }
        var activeCount = 0
        var freeIndex: Int?
        for index in 0..<capacity {
            if objects[index].active {
                activeCount += 1
            } else if freeIndex == nil {
                freeIndex = index
            }
        }
        guard activeCount < maximumObjects, let freeIndex else {
            return .rejected(.capacityExceeded)
        }
        guard sink.preflight(actionCount: 1) else { return .rejected(.capacityExceeded) }
        let delivery = BorrowedProtocolDelivery(
            routingKey: frame.routingKey,
            deliveryKey: deliveryKey,
            routeClassification: .coaty,
            topic: frame.topic,
            payload: frame.payload
        )
        guard sink.append(.deliver(delivery)) else { return .rejected(.capacityExceeded) }
        objects[freeIndex] = ObjectRecord(
            id: objectID,
            sourceID: sourceID,
            active: true,
            local: false,
            announced: true,
            role: role,
            leaseMS: presence?.leaseMS ?? 0,
            lastSeenMS: presence != nil ? nowMS : 0,
            ownerEpoch: presence?.ownerEpoch ?? 0
        )
        generation &+= 1
        return .accepted
    }

    /// Emits a re-announcement after the sink admits every action.
    ///
    /// Kept out of line so its route, role, and release temporaries do not
    /// inflate the generic inbound frame.
    @inline(never)
    private mutating func reannouncePresence<S: ~Copyable & ProtocolActionSink>(
        index: Int,
        objectID: UUID16,
        role: ObjectRole,
        presence: PresenceLease?,
        frame: BorrowedProtocolFrame,
        nowMS: UInt32,
        sink: inout S
    ) -> ProtocolProcessOutcome {
        let deliveryKey = deliveryKey(for: frame)
        guard Self.deliveryKeyFits(deliveryKey) else { return .rejected(.capacityExceeded) }
        let releasePlan = planAssociationReleases(for: objectID)
        guard sink.preflight(actionCount: 1 + releasePlan.actionCount) else {
            return .rejected(.capacityExceeded)
        }
        let delivery = BorrowedProtocolDelivery(
            routingKey: frame.routingKey,
            deliveryKey: deliveryKey,
            routeClassification: .coaty,
            topic: frame.topic,
            payload: frame.payload
        )
        guard sink.append(.deliver(delivery)) else { return .rejected(.capacityExceeded) }
        guard emitAssociationReleases(releasePlan, delivery: delivery, sink: &sink) else {
            return .rejected(.capacityExceeded)
        }
        for offset in 0..<releasePlan.count {
            associations[releasePlan.indices[offset]] = Association()
        }
        objects[index].role = role
        objects[index].leaseMS = presence?.leaseMS ?? 0
        objects[index].lastSeenMS = presence != nil ? nowMS : 0
        objects[index].ownerEpoch = presence?.ownerEpoch ?? 0
        generation &+= 1
        return .accepted
    }

    /// The profile prefix carried by a borrowed frame's topic bytes.
    private borrowing func frameProfile(_ frame: BorrowedProtocolFrame) -> WireProfile? {
        frame.topic.withBytes { pointer, length in
            let view = TopicView(
                topicBytes: pointer.assumingMemoryBound(to: UInt8.self),
                length: length
            )
            return view.profile
        }
    }

    private borrowing func planAssociationReleases(for objectID: UUID16) -> AssociationReleasePlan {
        var plan = AssociationReleasePlan()
        for index in 0..<capacity where associations[index].active
            && (associations[index].sourceID == objectID || associations[index].actorID == objectID) {
            plan.indices[plan.count] = index
            plan.count += 1
            plan.actionCount += associationReleaseActionCount(at: index)
        }
        return plan
    }

    /// One release action plus an optional external-route deactivation.
    private borrowing func associationReleaseActionCount(at index: Int) -> Int {
        let association = associations[index]
        return 1 + (association.routeKind == .external && association.routeLength > 0 ? 1 : 0)
    }

    /// Emits the packed release batch after the caller admits its preflight.
    ///
    /// Kept out of line so the route snapshot and action temporaries do not
    /// inflate the inbound or re-announce frame.
    @inline(never)
    private func emitAssociationReleases<S: ~Copyable & ProtocolActionSink>(
        _ plan: borrowing AssociationReleasePlan,
        delivery: borrowing BorrowedProtocolDelivery,
        sink: inout S
    ) -> Bool {
        for offset in 0..<plan.count {
            guard emitAssociationRelease(at: plan.indices[offset], delivery: delivery, sink: &sink) else {
                return false
            }
        }
        return true
    }

    private func emitAssociationRelease<S: ~Copyable & ProtocolActionSink>(
        at index: Int,
        delivery: borrowing BorrowedProtocolDelivery,
        sink: inout S
    ) -> Bool {
        let association = associations[index]
        let route = associationRouteSnapshot(association)
        if association.routeKind == .external, let route {
            guard emitExternalRouteDeactivated(
                sourceID: association.sourceID,
                actorID: association.actorID,
                route: route,
                sink: &sink
            ) else { return false }
        }
        return emitAssociationTransition(
            delivery: delivery,
            sourceID: association.sourceID,
            actorID: association.actorID,
            change: .removed,
            route: route,
            routeClassification: association.routeKind.classification,
            sink: &sink
        )
    }

    /// Emits the profile publications for one local operation.
    ///
    /// Used by the legacy outbound path and the opt-in presence path so both
    /// keep the same filter order and preflight count.
    private func emitProfilePublications<S: ~Copyable & ProtocolActionSink>(
        _ operation: ProtocolLocalOperation,
        key: ProtocolRoutingKey,
        sink: inout S
    ) -> Bool {
        let filters = outboundEventTypeFilters(for: operation)
        guard Self.eventTypeFiltersFit(filters) else { return false }
        let actionCount = filters.secondary == nil ? 1 : 2
        guard sink.preflight(actionCount: actionCount) else { return false }
        guard sink.append(.publish(BorrowedProtocolPublication(
            routingKey: key,
            target: .profile(
                eventTypeFilter: filters.primary?.value,
                filterKind: filters.primary?.kind ?? .direct
            ),
            payload: operation.payload,
            isApplicationDelivery: true
        ))) else { return false }
        if let secondary = filters.secondary {
            guard sink.append(.publish(BorrowedProtocolPublication(
                routingKey: key,
                target: .profile(
                    eventTypeFilter: secondary.value,
                    filterKind: secondary.kind
                ),
                payload: operation.payload,
                isApplicationDelivery: false
            ))) else { return false }
        }
        return true
    }

    /// Processes one local `axoloty/1` Advertise with opt-in presence.
    ///
    /// Kept out of line so presence planning and eviction do not inflate the
    /// common outbound frame.
    @inline(never)
    private mutating func processPresenceOutboundAdvertise<S: ~Copyable & ProtocolActionSink>(
        _ operation: ProtocolLocalOperation,
        nowMS: UInt32,
        sink: inout S
    ) -> ProtocolProcessOutcome {
        let presence: PresenceLease?
        switch presenceLease(from: operation.payload) {
        case .success(let value): presence = value
        case .rejected(let code): return .rejected(code)
        }
        guard let key = try? ProtocolRoutingKey(
            capability: .advertise,
            sourceID: operation.sourceID,
            correlationID: nil
        ) else { return .rejected(.invalidCorrelation) }
        let objectID = advertisedObjectID(operation.payload) ?? operation.sourceID
        let role = advertisedObjectRole(operation.payload)

        var heldIndex: Int?
        for index in 0..<capacity where objects[index].active && objects[index].local {
            guard objects[index].sourceID == operation.sourceID, objects[index].id == objectID else { continue }
            heldIndex = index
            break
        }
        if let index = heldIndex {
            let isRenew = presence != nil
                && objects[index].leaseMS > 0
                && objects[index].ownerEpoch == presence?.ownerEpoch
            guard emitProfilePublications(operation, key: key, sink: &sink) else {
                return .rejected(.capacityExceeded)
            }
            objects[index].announced = true
            // A same-epoch renew keeps the stored role: refresh bytes are
            // stale content by contract, so a buggy owner cannot flap routing.
            if !isRenew {
                objects[index].role = role
                generation &+= 1
            }
            objects[index].leaseMS = presence?.leaseMS ?? 0
            objects[index].lastSeenMS = presence != nil ? nowMS : 0
            objects[index].ownerEpoch = presence?.ownerEpoch ?? 0
            return .accepted
        }

        var activeCount = 0
        var freeIndex: Int?
        for index in 0..<capacity {
            if objects[index].active {
                activeCount += 1
            } else if freeIndex == nil {
                freeIndex = index
            }
        }
        let slot: Int
        if let freeIndex, activeCount < maximumObjects {
            slot = freeIndex
        } else if presenceState == .suspended,
                  let victim = oldestSuspendedPeer(nowMS: nowMS) {
            slot = victim
        } else {
            return .rejected(.capacityExceeded)
        }
        guard emitProfilePublications(operation, key: key, sink: &sink) else {
            return .rejected(.capacityExceeded)
        }
        objects[slot] = ObjectRecord(
            id: objectID,
            sourceID: operation.sourceID,
            active: true,
            local: true,
            announced: true,
            role: role,
            leaseMS: presence?.leaseMS ?? 0,
            lastSeenMS: presence != nil ? nowMS : 0,
            ownerEpoch: presence?.ownerEpoch ?? 0
        )
        generation &+= 1
        return .accepted
    }

    /// The oldest suspended leased peer, with the lowest slot breaking ties.
    private borrowing func oldestSuspendedPeer(nowMS: UInt32) -> Int? {
        var victim: Int?
        var oldestAge: UInt32 = 0
        for index in 0..<capacity {
            let object = objects[index]
            guard object.active, !object.local, object.leaseMS > 0 else { continue }
            let age = nowMS &- object.lastSeenMS
            if victim == nil || age > oldestAge {
                victim = index
                oldestAge = age
            }
        }
        return victim
    }

    private mutating func processExternalInbound<Classifier: ProtocolRouteClassifier, S: ~Copyable & ProtocolActionSink>(
        route: ByteSlice,
        payload: ByteSlice,
        nowMS: UInt32,
        classifier: Classifier,
        sink: inout S
    ) -> ProtocolProcessOutcome {
        guard route.length > 0, route.length <= ProtocolBufferConfig.maxRouteBytes,
              classifier.classify(route) == .external else { return .ignored }
        guard payload.length <= maximumPayloadBytes,
              payload.length <= sink.maximumPayloadBytes else {
            return .rejected(.capacityExceeded)
        }
        guard validatePayload(payload, for: .ioValue) else { return .rejected(.malformedPayload) }

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
        guard operation.payload.length <= maximumPayloadBytes,
              operation.payload.length <= sink.maximumPayloadBytes else {
            return .rejected(.capacityExceeded)
        }
        let valid = validatePayload(operation.payload, for: operation.capability)
        guard valid else { return .rejected(.malformedPayload) }
        if presenceState != .disabled, operation.capability == .advertise {
            return processPresenceOutboundAdvertise(operation, nowMS: nowMS, sink: &sink)
        }
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
                codec.reader(bytes: pointer.assumingMemoryBound(to: UInt8.self), length: length)
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
                // The route is snapshotted into fixed inline storage rather
                // than borrowed as a `ByteSlice` pointer: `associations` is
                // internal processor state, and `InlineProtocolActionSink`
                // does not copy borrowed bytes, so a pointer obtained via a
                // scoped `withUnsafeBytes(of:)` closure would dangle the
                // moment that closure returns -- exactly the memory it must
                // remain valid past, since the sink is read by the caller
                // after `processOutbound` itself returns.
                guard let route = associationRouteSnapshot(association) else {
                    return .rejected(.malformedPayload)
                }
                let appended = sink.append(.publish(BorrowedProtocolPublication(
                    routingKey: key,
                    target: .associationRoute(route: route, kind: association.routeKind.classification),
                    payload: operation.payload,
                    isApplicationDelivery: routeIndex == 0
                )))
                guard appended else { return .rejected(.capacityExceeded) }
            }
        } else {
            guard emitProfilePublications(operation, key: key, sink: &sink) else {
                return .rejected(.capacityExceeded)
            }
        }
        if let requestPlan {
            pending[requestPlan.index] = PendingRecord(
                id: requestPlan.correlationID,
                deadlineMS: requestPlan.deadlineMS,
                state: .active(Self.requestKind(for: operation.capability))
            )
        }
        commitTransition(
            associationPlan: plan,
            objectPlan: objectPlan,
            deadvertiseMask: deadvertiseMask,
            releaseMask: InlineArray(repeating: false)
        )
        return .accepted
    }

    private func deliveryKey(for frame: BorrowedProtocolFrame) -> BorrowedProtocolDeliveryKey {
        switch frame.routingKey.capability {
        case .advertise:
            if let objectType = advertisedObjectType(frame.payload) {
                return .advertiseFilter(objectType)
            }
            if let filter = frame.eventTypeFilter { return .advertiseFilter(filter) }
        case .channel:
            if let channel = frame.eventTypeFilter { return .channel(channel) }
        case .associate:
            let reader = frame.payload.withBytes { pointer, length in
                codec.reader(bytes: pointer.assumingMemoryBound(to: UInt8.self), length: length)
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
            if let objectType = advertisedObjectType(operation.payload) {
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

    private static func deliveryKeyFits(_ key: BorrowedProtocolDeliveryKey) -> Bool {
        switch key {
        case .advertiseFilter(let value), .channel(let value):
            return value.length <= 128
        default:
            return true
        }
    }

    private static func eventTypeFiltersFit(
        _ filters: (
            primary: (value: ByteSlice, kind: ProtocolEventTypeFilterKind)?,
            secondary: (value: ByteSlice, kind: ProtocolEventTypeFilterKind)?
        )
    ) -> Bool {
        if let primary = filters.primary, primary.value.length > 128 { return false }
        if let secondary = filters.secondary, secondary.value.length > 128 { return false }
        return true
    }

    private func advertisedObjectType(_ payload: ByteSlice) -> ByteSlice? {
        advertisedObjectField("objectType", payload: payload)
    }

    private func advertisedObjectRole(_ payload: ByteSlice) -> ObjectRole {
        guard let coreType = advertisedObjectField("coreType", payload: payload) else { return .other }
        if coreType.equals("IoSource") { return .ioSource }
        if coreType.equals("IoActor") { return .ioActor }
        return .other
    }

    private func advertisedObjectField(_ field: StaticString, payload: ByteSlice) -> ByteSlice? {
        payload.withBytes { pointer, length in
            let reader = codec.reader(bytes: pointer.assumingMemoryBound(to: UInt8.self), length: length)
            guard let object = reader.readField("object") else { return nil }
            return object.withBytes { objectPointer, objectLength in
                let objectReader = codec.reader(
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
            guard let coreType = advertisedObjectField("coreType", payload: operation.payload) else {
                return (nil, nil)
            }
            guard Self.equals(coreType, "CoatyObject"),
                  let objectType = advertisedObjectType(operation.payload) else {
                return ((coreType, .direct), nil)
            }
            return ((coreType, .direct), (objectType, .objectType))
        case .update:
            guard let coreType = advertisedObjectField("coreType", payload: operation.payload) else {
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
        let reader = payload.withBytes { pointer, length in
            codec.reader(bytes: pointer.assumingMemoryBound(to: UInt8.self), length: length)
        }
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
        var semanticStorage = ProtocolRouteStorage(repeating: 0)
        let semanticLength: Int
        do {
            semanticLength = try codec.copyDecodedString(route, into: &semanticStorage)
        } catch {
            return .rejected(.malformedPayload)
        }
        guard semanticLength > 0,
              semanticLength <= ProtocolBufferConfig.maxRouteBytes else {
            return .rejected(.capacityExceeded)
        }
        return withUnsafeBytes(of: semanticStorage) { buffer in
            let semanticRoute = ByteSlice(
                bytes: buffer.baseAddress!.assumingMemoryBound(to: UInt8.self),
                length: semanticLength
            )
            let classification = classifier.classify(semanticRoute)
            if let explicit = event.isExternalRoute, explicit != (classification == .external) {
                return .rejected(.externalRouteMismatch)
            }
            if classification == .unrelated { return .ignored }
            let routeKind: StoredAssociationRouteKind = classification == .external ? .external : .coaty
            for index in 0..<capacity where associations[index].active && associations[index].sourceID == event.ioSourceId && associations[index].actorID == event.ioActorId {
                var association = associations[index]
                association.routeLength = semanticLength
                for offset in 0..<semanticLength { association.route[offset] = semanticRoute.byte(at: offset) ?? 0 }
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
                    routeLength: semanticLength,
                    route: InlineArray(repeating: 0),
                    routeKind: routeKind,
                    updateRateMS: updateRateMS
                )
                for offset in 0..<semanticLength { association.route[offset] = semanticRoute.byte(at: offset) ?? 0 }
                return .accepted(.upsert(index, association), classification)
            }
            return .rejected(.capacityExceeded)
        }
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
            let objectID = advertisedObjectID(payload) ?? sourceID
            let role = advertisedObjectRole(payload)
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
            guard markDeadvertisedObjects(payload, sourceID: sourceID, local: local, into: &deadvertiseMask) else {
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
        deadvertiseMask: InlineArray<capacity, Bool>,
        releaseMask: InlineArray<capacity, Bool>
    ) {
        apply(associationPlan)
        for index in 0..<capacity where deadvertiseMask[index] {
            objects[index] = ObjectRecord()
        }
        for index in 0..<capacity where releaseMask[index] {
            associations[index] = Association()
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
        var storage = ProtocolRouteStorage(repeating: 0)
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

    private func advertisedObjectID(_ payload: ByteSlice) -> UUID16? {
        payload.withBytes { pointer, length in
            let reader = codec.reader(bytes: pointer.assumingMemoryBound(to: UInt8.self), length: length)
            guard let object = reader.readField("object") else { return nil }
            return object.withBytes { objectPointer, objectLength in
                let objectReader = codec.reader(
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

    /// One predicate for the preflight count and the IoValue fan-out so the
    /// two cannot drift.
    private borrowing func matchesIoValue(_ index: Int, source: UUID16) -> Bool {
        associations[index].active && associations[index].sourceID == source
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

    /// Marks the objects an inbound or local Deadvertise removes and reports
    /// whether the payload is acceptable.
    ///
    /// An inbound Deadvertise is acceptable when `objectIds` is an array of
    /// non-empty strings, as CoatyJS `DeadvertiseEventData` validates it
    /// (`CoreTypes.isStringArray`). CoatyJS keeps no object table, so it
    /// delivers an empty array, an unknown identifier, or a string that is not a
    /// UUID. This processor delivers them too and creates or removes nothing for
    /// them, because a consumer that joined after the peer advertised, or a
    /// broker last will, has no entry. A source removes only entries it owns,
    /// whatever the payload names. A local Deadvertise stays strict: it must be
    /// an array of UUIDs and name at least one active local entry.
    private func markDeadvertisedObjects(
        _ payload: ByteSlice,
        sourceID: UUID16,
        local: Bool,
        into mask: inout InlineArray<capacity, Bool>
    ) -> Bool {
        var valid = true
        var matched = 0
        payload.withBytes { pointer, length in
            let reader = codec.reader(bytes: pointer.assumingMemoryBound(to: UInt8.self), length: length)
            do throws(WireDecodeError) {
                try reader.readIdentifierElements("objectIds") { objectID in
                    guard let objectID else {
                        if local { valid = false }
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
        return valid && (!local || matched > 0)
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
        if capability == .ioValue {
            // IoValue is the one profile family whose payload may be a bare
            // value or arbitrary binary bytes. The codec owns the profile's
            // bare-value gate; raw external input never requires UTF-8.
            return codec.isValidBareValue(payload)
        }
        return payload.withBytes { pointer, length in
            let reader = codec.reader(bytes: pointer.assumingMemoryBound(to: UInt8.self), length: length)
            switch capability {
            case .advertise:
                return (try? AdvertiseWireData(from: reader)) != nil
            case .deadvertise:
                return (try? DeadvertiseWireData(from: reader)) != nil
            case .associate:
                return (try? AssociateWireData(from: reader)) != nil
            case .ioValue:
                return true
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
