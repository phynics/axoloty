// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyObjectModel
@_spi(AxolotyRuntimeAdapter) import AxolotyProtocol
import AxolotyWire

/// Reasons a static definition cannot be constructed.
public enum StaticRuntimeDefinitionError: Error, Sendable {
    /// A capacity or limit is outside the fixed storage bounds.
    case capacity(ProtocolCapacityError)
    /// Presence was requested for a non-`axoloty/1` profile.
    case presence(ProtocolPresenceConfigurationError)
}

/// Fixed configuration consumed exactly once by a static runtime.
public struct StaticRuntimeDefinition<let payloadCapacity: Int>: ~Copyable {
    /// Opaque identity used to reject handles from another runtime registry.
    public let registryID: ObjectID
    /// Families enabled for this firmware image.
    public let capabilities: ProtocolCapabilities
    /// Optional maximum number of simultaneously advertised objects.
    ///
    /// When `nil`, the consuming runtime's storage capacity is used.
    public let maximumObjects: Int?
    /// Optional maximum number of outstanding request correlations.
    ///
    /// When `nil`, the consuming runtime's storage capacity is used.
    public let maximumPendingCorrelations: Int?
    /// The wire profile the consuming runtime reads and writes.
    ///
    /// The binding chooses exactly one profile at composition time; the static
    /// runtime selects it through the shared ``WireCodec`` seam and never
    /// branches on the format. The default keeps the sealed `coaty/3` JSON
    /// byte contract.
    public let wireCodec: WireCodec
    /// Opt-in soft-state presence policy.
    ///
    /// Presence requires `axoloty/1`; the default keeps legacy behavior.
    public let presencePolicy: ProtocolPresencePolicy
    /// Maximum accepted wire payload size, fixed by the type specialization.
    public var maximumPayloadBytes: Int { payloadCapacity }
    /// Maximum accepted wire payload size for this definition specialization.
    public static var maximumPayloadBytes: Int { payloadCapacity }

    /// Creates a bounded static definition.
    ///
    /// - Parameters:
    ///   - registryID: Opaque identity used to reject handles from another runtime registry.
    ///   - capabilities: Families accepted by this binding.
    ///   - maximumObjects: Optional maximum number of simultaneously advertised objects.
    ///   - maximumPendingCorrelations: Optional maximum number of outstanding request correlations.
    ///   - wireCodec: The wire profile this binding reads and writes. The
    ///     default is the sealed `coaty/3` JSON profile.
    /// - Throws: ``ProtocolCapacityError`` if the payload specialization is
    ///   outside the wire payload bound.
    public init(
        registryID: ObjectID,
        capabilities: ProtocolCapabilities = .coatyCore3,
        maximumObjects: Int? = nil,
        maximumPendingCorrelations: Int? = nil,
        wireCodec: WireCodec = WireCodec(profile: .coaty3JSON)
    ) throws(ProtocolCapacityError) {
        guard payloadCapacity >= 0 else {
            throw ProtocolCapacityError(.negativeCapacity, parameter: "payloadCapacity")
        }
        guard payloadCapacity <= WireBufferConfig.maxPayloadSize else {
            throw ProtocolCapacityError(.exceedsMaximum, parameter: "payloadCapacity")
        }
        self.registryID = registryID
        self.capabilities = capabilities
        self.maximumObjects = maximumObjects
        self.maximumPendingCorrelations = maximumPendingCorrelations
        self.wireCodec = wireCodec
        self.presencePolicy = .disabled
    }

    /// Creates a bounded static definition with an explicit presence policy.
    ///
    /// Presence requires `axoloty/1`; an invalid combination throws before the
    /// definition exists.
    ///
    /// - Parameters:
    ///   - registryID: Opaque identity used to reject handles from another runtime registry.
    ///   - capabilities: Families accepted by this binding.
    ///   - maximumObjects: Optional maximum number of simultaneously advertised objects.
    ///   - maximumPendingCorrelations: Optional maximum number of outstanding request correlations.
    ///   - wireCodec: The wire profile this binding reads and writes.
    ///   - presencePolicy: Opt-in soft-state presence.
    /// - Throws: ``StaticRuntimeDefinitionError`` when a capacity is outside
    ///   the payload bound or presence is requested for another profile.
    public init(
        registryID: ObjectID,
        capabilities: ProtocolCapabilities = .coatyCore3,
        maximumObjects: Int? = nil,
        maximumPendingCorrelations: Int? = nil,
        wireCodec: WireCodec = WireCodec(profile: .coaty3JSON),
        presencePolicy: ProtocolPresencePolicy
    ) throws(StaticRuntimeDefinitionError) {
        guard payloadCapacity >= 0 else {
            throw .capacity(ProtocolCapacityError(.negativeCapacity, parameter: "payloadCapacity"))
        }
        guard payloadCapacity <= WireBufferConfig.maxPayloadSize else {
            throw .capacity(ProtocolCapacityError(.exceedsMaximum, parameter: "payloadCapacity"))
        }
        if presencePolicy == .enabled, wireCodec.profile != .axoloty1CBOR {
            throw .presence(.unsupportedWireProfile)
        }
        self.registryID = registryID
        self.capabilities = capabilities
        self.maximumObjects = maximumObjects
        self.maximumPendingCorrelations = maximumPendingCorrelations
        self.wireCodec = wireCodec
        self.presencePolicy = presencePolicy
    }
}

/// A synchronous, fixed-storage runtime for Embedded Swift.
///
/// One runtime owns exactly one ``ProtocolProcessor`` and one inline action
/// owning action sink. Callers may return from frame or local-operation
/// processing before draining because the sink deep-copies every borrowed
/// byte. Drained views remain valid only during the synchronous visitor. No
/// task, actor, Foundation value, or heap-backed registry is part of this
/// runtime.
public struct StaticRuntime<let capacity: Int, let payloadCapacity: Int>: ~Copyable {
    let registryID: ObjectID
    var processor: ProtocolProcessor<capacity>
    var subscriptions: ProtocolSubscriptionRegistry<capacity>
    var sink: InlineOwnedProtocolActionSink<capacity, payloadCapacity>
    let routeClassifier: ExactProtocolRouteClassifier
    let presencePolicy: ProtocolPresencePolicy
    var ioRegistry: StaticIoEndpointRegistry<capacity, payloadCapacity>
    var receiveContext: StaticIoReceiveContext?

    /// Creates a runtime with a sealed capability profile and fixed limits.
    ///
    /// This initializer always disables presence; use a
    /// ``StaticRuntimeDefinition`` with an enabled presence policy to opt in.
    ///
    /// - Parameters:
    ///   - registryID: Opaque identity used to reject foreign object handles.
    ///   - capabilities: Families accepted by this binding.
    ///   - maximumObjects: Maximum simultaneous advertised objects.
    ///   - maximumPendingCorrelations: Maximum outstanding request correlations.
    ///   - wireCodec: The wire profile this binding reads and writes. The
    ///     default is the sealed `coaty/3` JSON profile.
    /// - Throws: ``ProtocolCapacityError`` if a caller-supplied limit is
    ///   negative or exceeds the runtime's fixed storage capacity.
    public init(
        registryID: ObjectID,
        capabilities: ProtocolCapabilities = .coatyCore3,
        maximumObjects: Int = capacity,
        maximumPendingCorrelations: Int = capacity,
        wireCodec: WireCodec = WireCodec(profile: .coaty3JSON)
    ) throws(ProtocolCapacityError) {
        guard payloadCapacity >= 0 else {
            throw ProtocolCapacityError(.negativeCapacity, parameter: "payloadCapacity")
        }
        guard payloadCapacity <= WireBufferConfig.maxPayloadSize else {
            throw ProtocolCapacityError(.exceedsMaximum, parameter: "payloadCapacity")
        }
        guard maximumObjects >= 0 else {
            throw ProtocolCapacityError(.negativeCapacity, parameter: "maximumObjects")
        }
        guard maximumObjects <= capacity else {
            throw ProtocolCapacityError(.exceedsMaximum, parameter: "maximumObjects")
        }
        guard maximumPendingCorrelations >= 0 else {
            throw ProtocolCapacityError(.negativeCapacity, parameter: "maximumPendingCorrelations")
        }
        guard maximumPendingCorrelations <= capacity else {
            throw ProtocolCapacityError(.exceedsMaximum, parameter: "maximumPendingCorrelations")
        }
        self.registryID = registryID
        self.routeClassifier = ExactProtocolRouteClassifier(
            externalRoute: "external/wire-compat-v1/io-external-1"
        )
        self.presencePolicy = .disabled
        self.processor = ProtocolProcessor<capacity>(
            capabilities: capabilities,
            wireCodec: wireCodec,
            maximumPayloadBytes: payloadCapacity,
            maximumObjects: maximumObjects,
            maximumPendingCorrelations: maximumPendingCorrelations
        )
        self.subscriptions = ProtocolSubscriptionRegistry<capacity>()
        self.sink = InlineOwnedProtocolActionSink<capacity, payloadCapacity>()
        self.ioRegistry = StaticIoEndpointRegistry()
        self.receiveContext = nil
    }

    /// Consumes fixed configuration and binds one exact route classifier.
    public init(
        definition: consuming StaticRuntimeDefinition<payloadCapacity>,
        routeClassifier: ExactProtocolRouteClassifier
    ) {
        let maximumObjects = definition.maximumObjects ?? capacity
        let maximumPendingCorrelations = definition.maximumPendingCorrelations ?? capacity
        precondition(maximumObjects >= 0 && maximumObjects <= capacity)
        precondition(maximumPendingCorrelations >= 0 && maximumPendingCorrelations <= capacity)
        self.registryID = definition.registryID
        self.routeClassifier = routeClassifier
        self.presencePolicy = definition.presencePolicy
        do {
            self.processor = try ProtocolProcessor<capacity>(
                capabilities: definition.capabilities,
                wireCodec: definition.wireCodec,
                maximumPayloadBytes: payloadCapacity,
                maximumObjects: maximumObjects,
                maximumPendingCorrelations: maximumPendingCorrelations,
                presencePolicy: definition.presencePolicy
            )
        } catch {
            // Unreachable: the definition's throwing initializer rejects
            // enabled presence on non-axoloty/1 before a definition exists.
            preconditionFailure("unreachable: invalid presence composition (\(error))")
        }
        self.subscriptions = ProtocolSubscriptionRegistry<capacity>()
        self.sink = InlineOwnedProtocolActionSink<capacity, payloadCapacity>()
        self.ioRegistry = StaticIoEndpointRegistry()
        self.receiveContext = nil
    }

    /// The processor's fixed-storage state observation.
    public var state: ProtocolStateSnapshot { processor.state }

    /// Copies the identity-bearing processor state into caller-owned storage.
    ///
    /// This projection is intended for bounded diagnostics and conformance
    /// traces. It does not expose the processor or retain any borrowed value.
    public func copyState(into projection: inout ProtocolFixedStateSnapshot<capacity>) {
        processor.copyState(into: &projection)
    }

    /// Maximum payload accepted by this runtime's fixed storage.
    public var maximumPayloadBytes: Int { payloadCapacity }
    /// Maximum payload accepted by this runtime specialization.
    public static var maximumPayloadBytes: Int { payloadCapacity }

    /// Registers a synchronous numeric-context handler.
    public mutating func register(
        selector: ProtocolSubscriptionSelector,
        key: ByteSlice? = nil,
        handler: ProtocolHandlerEntry
    ) throws(ProtocolError) -> ProtocolSubscriptionToken {
        try subscriptions.register(selector: selector, key: key, handler: handler)
    }

    /// Removes a previously registered handler.
    public mutating func unregister(_ token: ProtocolSubscriptionToken) -> ProtocolUnregisterOutcome {
        subscriptions.unregister(token)
    }

    /// Processes one local operation and retains its action until ``drain``.
    public mutating func send(
        _ operation: ProtocolLocalOperation,
        nowMS: UInt32 = 0
    ) -> ProtocolProcessOutcome {
        guard sink.count == 0 else { return .rejected(.capacityExceeded) }
        sink.removeAll()
        let outcome = processor.processOutbound(operation, nowMS: nowMS, classifier: routeClassifier, sink: &sink)
        if case .rejected = outcome { sink.removeAll() }
        return outcome
    }

    /// Processes one inbound frame and retains its action until ``drain``.
    public mutating func receive(
        _ frame: BorrowedProtocolFrame,
        nowMS: UInt32
    ) -> ProtocolProcessOutcome {
        guard sink.count == 0 else { return .rejected(.capacityExceeded) }
        sink.removeAll()
        let outcome = processor.processInbound(.profile(frame), nowMS: nowMS, classifier: routeClassifier, sink: &sink)
        if case .rejected = outcome { sink.removeAll() }
        if case .accepted = outcome {
            receiveContext = StaticIoReceiveContext(
                receivedAtMS: nowMS,
                associationGeneration: processor.state.generation
            )
        }
        return outcome
    }

    /// Parses one caller-owned topic and payload synchronously, then routes
    /// the borrowed frame through the shared processor. The input buffers are
    /// borrowed only for the duration of this call.
    public mutating func receive(
        topic: ByteSlice,
        payload: ByteSlice,
        nowMS: UInt32
    ) -> ProtocolProcessOutcome {
        var result: ProtocolProcessOutcome = .rejected(.malformedFrame)
        topic.withBytes { pointer, length in
            payload.withBytes { payloadPointer, payloadLength in
                let view = TopicView(topicBytes: pointer.assumingMemoryBound(to: UInt8.self), length: length)
                do throws(ProtocolError) {
                    let frame = try BorrowedProtocolFrame(
                        topic: view,
                        payload: ByteSlice(bytes: payloadPointer.assumingMemoryBound(to: UInt8.self), length: payloadLength)
                    )
                    result = self.receive(frame, nowMS: nowMS)
                } catch {
                    result = .rejected(error.code)
                }
            }
        }
        return result
    }

    /// Processes one inbound frame with a binding-owned route classifier.
    public mutating func receive<Classifier: ProtocolRouteClassifier>(
        _ frame: BorrowedProtocolFrame,
        nowMS: UInt32,
        classifier: Classifier
    ) -> ProtocolProcessOutcome {
        guard sink.count == 0 else { return .rejected(.capacityExceeded) }
        sink.removeAll()
        let outcome = processor.processInbound(.profile(frame), nowMS: nowMS, classifier: classifier, sink: &sink)
        if case .rejected = outcome { sink.removeAll() }
        if case .accepted = outcome {
            receiveContext = StaticIoReceiveContext(
                receivedAtMS: nowMS,
                associationGeneration: processor.state.generation
            )
        }
        return outcome
    }

    /// Processes one local operation with a binding-owned route classifier.
    public mutating func send<Classifier: ProtocolRouteClassifier>(
        _ operation: ProtocolLocalOperation,
        nowMS: UInt32 = 0,
        classifier: Classifier
    ) -> ProtocolProcessOutcome {
        guard sink.count == 0 else { return .rejected(.capacityExceeded) }
        sink.removeAll()
        let outcome = processor.processOutbound(operation, nowMS: nowMS, classifier: classifier, sink: &sink)
        if case .rejected = outcome { sink.removeAll() }
        return outcome
    }

    /// Expires all requests whose caller-supplied deadlines have elapsed.
    public mutating func expire(nowMS: UInt32) -> Bool {
        processor.expire(nowMS: nowMS)
    }

    /// Cancels one local request without emitting a wire operation.
    public mutating func cancel(correlationID: UUID16) -> Bool {
        processor.cancel(correlationID: correlationID)
    }

    /// Removes the first expired leased peer object.
    ///
    /// The caller loops until this returns `nil`; each call removes one object
    /// and keeps its Associate rows. It returns `nil` when presence is
    /// disabled or suspended.
    ///
    /// - Parameter nowMS: Caller-supplied monotonic time in milliseconds.
    /// - Returns: The removed source and object identities, or `nil`.
    public mutating func expirePresence(nowMS: UInt32) -> (sourceID: UUID16, objectID: UUID16)? {
        guard let expired = processor.expirePresence(nowMS: nowMS) else { return nil }
        if let slot = ioRegistry.sourceSlot(forID: ObjectID(uuid: expired.sourceID)) {
            ioRegistry.clearSourceTransportState(at: slot)
        }
        return expired
    }

    /// Suspends presence for an interrupted static transport.
    ///
    /// Leased peers survive; unleased peer entries are discarded like a hard
    /// reset. The retained action batch and transport-local IO state are
    /// released; drain before calling if the batch must be delivered. A
    /// presence-disabled runtime treats this as a no-op.
    public mutating func suspendPresence() {
        guard presencePolicy == .enabled else { return }
        processor.suspendPresence()
        sink.removeAll()
        ioRegistry.clearAllTransportState()
        receiveContext = nil
    }

    /// Re-bases retained peers after the static transport is usable again.
    ///
    /// Repeated calls on the resolved edge are idempotent, and a resume without
    /// a preceding suspend is a no-op. Peer expiry stays suppressed until this
    /// call. A presence-disabled runtime treats this as a no-op.
    ///
    /// - Parameter nowMS: Caller-supplied monotonic time in milliseconds.
    public mutating func resumePresence(nowMS: UInt32) {
        guard presencePolicy == .enabled else { return }
        processor.resumePresence(nowMS: nowMS)
    }

    /// Clears transport-local state so a reconnect can replay local state.
    public mutating func resetTransport() {
        processor.resetTransport()
        sink.removeAll()
        ioRegistry.clearAllTransportState()
        receiveContext = nil
    }

    /// Copies one active actor route into caller-owned transport storage.
    public func copyActorRoute(
        actorId: UUID16,
        to output: UnsafeMutablePointer<UInt8>,
        capacity outputCapacity: Int
    ) -> Int? {
        processor.copyActorRoute(actorId: actorId, to: output, capacity: outputCapacity)
    }

    /// Number of actions waiting for synchronous delivery.
    public var actionCount: Int { sink.count }

    /// Delivers and removes all retained actions through call-scoped borrows.
    ///
    /// Registered handlers are invoked synchronously in slot order. The body
    /// is never retained by the runtime.
    @discardableResult
    public mutating func drain(_ body: (BorrowedProtocolAction) -> Void) -> Int {
        let count = sink.count
        var cleanupSources = InlineArray<capacity, Bool>(repeating: false)
        for index in 0..<count {
            _ = sink.visit(at: index) { action in
                body(action)
                switch action {
                case .deliver(let delivery):
                    _ = subscriptions.dispatch(action)
                    dispatchStaticIoDelivery(
                        delivery,
                        registry: ioRegistry,
                        receiveContext: receiveContext
                    )
                case .associationChanged(let transition):
                    // A Deadvertise that removes an association endpoint also
                    // reports the released slots, but its delivery is that
                    // Deadvertise frame. Only a wire Associate frame is an
                    // Association event; dispatch the synthesized release to
                    // the source-state cleanup below, never a second time to
                    // Deadvertise subscribers.
                    if transition.delivery.routingKey.capability == .associate {
                        _ = subscriptions.dispatch(action)
                    }
                    let sourceID = transition.sourceID
                    if let slot = ioRegistry.sourceSlot(forID: ObjectID(uuid: sourceID)) {
                        cleanupSources[slot] = true
                    }
                case .publish, .externalRouteActivated, .externalRouteDeactivated:
                    break
                }
            }
        }
        for slot in 0..<capacity where cleanupSources[slot] {
            guard let record = ioRegistry.endpoint(at: slot),
                  !processor.ioAssociationState(forSource: record.id.uuid).hasAssociations else {
                continue
            }
            ioRegistry.clearSourceTransportState(at: slot)
        }
        sink.removeAll()
        ioRegistry.clearInFlight()
        receiveContext = nil
        return count
    }

}

/// The fixed profile used by the static device agent.
/// A one-slot saturation and atomicity preset.
public typealias StaticRuntimeTiny = StaticRuntime<1, 2048>

/// The fixed ESP32-C6 runtime preset.
public typealias StaticRuntimeESP32C6 = StaticRuntime<16, 2048>

/// A larger host-only static runtime test preset.
public typealias StaticRuntimeHostTest = StaticRuntime<64, 2048>

/// The default static device runtime.
public typealias AxolotyStaticRuntime = StaticRuntimeESP32C6
