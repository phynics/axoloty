// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyWire

/// The encoding contract accepted by a static embedded IO endpoint.
public enum StaticIoValueMode: Sendable, Equatable {
    /// The endpoint exchanges arbitrary bare bytes.
    case raw
    /// The endpoint exchanges one complete, bare JSON value.
    case json
}

/// A fixed configuration entry for an embedded IO source or actor.
///
/// Descriptors are supplied during startup and cannot be registered or removed
/// at runtime. ``valueType`` is a peer/application contract; the bounded
/// runtime compares it only when both endpoints are local.
public struct StaticIoEndpointDescriptor: Sendable {
    /// Stable UUID16 identity used by Associate messages.
    public let id: UUID16
    /// Application-defined value type contract.
    public let valueType: StaticString
    /// Whether values are raw bytes or bare JSON values.
    public let mode: StaticIoValueMode
    /// Optional application-requested update rate in milliseconds.
    public let configuredUpdateRate: Int?

    /// Creates a fixed embedded endpoint descriptor.
    public init(
        id: UUID16,
        valueType: StaticString,
        mode: StaticIoValueMode,
        configuredUpdateRate: Int? = nil
    ) {
        self.id = id
        self.valueType = valueType
        self.mode = mode
        self.configuredUpdateRate = configuredUpdateRate
    }
}

/// A bounded view of an endpoint's current association state.
public struct StaticIoAssociationState: Sendable, Equatable {
    /// Whether at least one valid association is active.
    public let isAssociated: Bool
    /// The route length in bytes. The route itself remains internal so callers
    /// cannot retain a reference to mutable transport storage.
    public let routeLength: Int
    /// The update rate negotiated by the latest Associate, when supplied.
    public let negotiatedUpdateRate: Int?
}

/// The outcome of consuming a bounded embedded IO message.
public enum StaticIoDispatchResult: Sendable, Equatable {
    /// The message changed source or actor association state.
    case associated
    /// The message removed an association and any actor route subscription.
    case disassociated
    /// A value was synchronously delivered to an actor handler.
    case delivered
    /// The message is well formed but names no locally configured endpoint.
    case unknownEndpoint
    /// The message violates endpoint capacity, mode, type, route, or rate rules.
    case rejected
    /// The message is not part of the static IO endpoint profile.
    case ignored
}

/// Bounded static IO endpoint state for the Embedded Swift data plane.
///
/// This type deliberately provides no router, discovery, rule evaluation, or
/// dynamic registration APIs. Incoming MQTT bytes are borrowed and consumed
/// synchronously; actor handlers must not retain their `ByteSlice` argument.
/// The runtime validates JSON syntax but does not rate-limit source publishing:
/// applications apply the negotiated update rate according to their own sensor
/// scheduling policy.
public struct StaticIoEndpoints {
    private struct Route {
        var bytes: [UInt8] = Array(repeating: 0, count: ProtocolBufferConfig.maxTopicLength)
        var length = 0

        mutating func clear() { length = 0 }

        mutating func copy(from route: ByteSlice) -> Bool {
            guard route.length > 0, route.length <= bytes.count else { return false }
            for offset in 0..<route.length { bytes[offset] = route.byte(at: offset)! }
            length = route.length
            return true
        }

        func equals(_ route: ByteSlice) -> Bool {
            guard length == route.length else { return false }
            for offset in 0..<length where bytes[offset] != route.byte(at: offset)! { return false }
            return true
        }

        func copy(to output: UnsafeMutablePointer<UInt8>, capacity: Int) -> Int? {
            guard length > 0, length <= capacity else { return nil }
            for offset in 0..<length { output[offset] = bytes[offset] }
            return length
        }
    }

    private struct SourceState {
        var route = Route()
        // Fixed slots make repeated Associate messages idempotent and avoid an
        // unbounded actor set on a source. A source route is shared by all of
        // its host-router associations.
        var associatedActors: [UUID16?] = Array(
            repeating: nil, count: ProtocolBufferConfig.maxFamilySubscribers
        )
        var negotiatedUpdateRate: Int?

        var associationCount: Int {
            var count = 0
            for actor in associatedActors where actor != nil { count += 1 }
            return count
        }
    }

    private struct ActorState {
        var route = Route()
        var isAssociated = false
        var negotiatedUpdateRate: Int?
        var associatedSources: [UUID16?] = Array(
            repeating: nil, count: ProtocolBufferConfig.maxFamilySubscribers
        )
        var associatedRoutes: [Route] = Array(
            repeating: Route(), count: ProtocolBufferConfig.maxFamilySubscribers
        )

        var associationCount: Int {
            associatedSources.reduce(0) { $0 + ($1 == nil ? 0 : 1) }
        }
    }

    private var sources: [StaticIoEndpointDescriptor]
    private var actors: [StaticIoEndpointDescriptor]
    private var sourceStates: [SourceState]
    private var actorStates: [ActorState]
    private var handlers: [(@Sendable (ByteSlice) -> Void)?]

    /// Creates a static endpoint registry with fixed startup configuration.
    ///
    /// - Parameters:
    ///   - sources: Configured local sources; at most
    ///     ``WireBufferConfig/maxFamilyEntries`` entries are accepted.
    ///   - actors: Configured local actors; at most
    ///     ``WireBufferConfig/maxFamilyEntries`` entries are accepted.
    ///   - actorHandlers: Synchronous handlers, one per actor. A missing handler
    ///     means values are rejected rather than buffered.
    /// - Throws: ``WireCapacityError`` if the number of sources or actors exceeds
    ///   ``WireBufferConfig/maxFamilyEntries``, or if `actorHandlers` does not
    ///   contain exactly one entry per actor.
    public init(
        sources: [StaticIoEndpointDescriptor],
        actors: [StaticIoEndpointDescriptor],
        actorHandlers: [(@Sendable (ByteSlice) -> Void)?]
    ) throws(ProtocolCapacityError) {
        if sources.count > ProtocolBufferConfig.maxFamilyEntries {
            throw ProtocolCapacityError(
                .exceedsMaximum, parameter: "sources"
            )
        }
        if actors.count > ProtocolBufferConfig.maxFamilyEntries {
            throw ProtocolCapacityError(
                .exceedsMaximum, parameter: "actors"
            )
        }
        if actors.count != actorHandlers.count {
            throw ProtocolCapacityError(.countMismatch, parameter: "actorHandlers")
        }
        self.sources = sources
        self.actors = actors
        self.sourceStates = Array(repeating: SourceState(), count: sources.count)
        self.actorStates = Array(repeating: ActorState(), count: actors.count)
        self.handlers = actorHandlers
    }

    /// Returns the bounded association state for a local source.
    public func sourceState(id: UUID16) -> StaticIoAssociationState? {
        guard let index = sourceIndex(id) else { return nil }
        let state = sourceStates[index]
        return StaticIoAssociationState(isAssociated: state.associationCount > 0, routeLength: state.route.length, negotiatedUpdateRate: state.negotiatedUpdateRate)
    }

    /// Returns the bounded association state for a local actor.
    public func actorState(id: UUID16) -> StaticIoAssociationState? {
        guard let index = actorIndex(id) else { return nil }
        let state = actorStates[index]
        return StaticIoAssociationState(isAssociated: state.isAssociated, routeLength: state.route.length, negotiatedUpdateRate: state.negotiatedUpdateRate)
    }

    /// Copies an associated actor route into fixed caller-owned storage.
    ///
    /// This is intended for the embedded MQTT adapter's subscribe and
    /// reconnect path. It returns nil for an unknown or disassociated actor.
    public func copyActorRoute(
        actorId: UUID16, to output: UnsafeMutablePointer<UInt8>, capacity: Int
    ) -> Int? {
        guard let index = actorIndex(actorId), actorStates[index].isAssociated else { return nil }
        return actorStates[index].route.copy(to: output, capacity: capacity)
    }

    /// Consumes an Associate event for configured endpoints.
    public mutating func consumeAssociate(_ message: BorrowedMessage) -> StaticIoDispatchResult {
        guard message.eventType == .associate, let event = try? AssociateWireData(from: message.reader()) else { return .rejected }
        let source = sourceIndex(event.ioSourceId)
        let actor = actorIndex(event.ioActorId)
        guard source != nil || actor != nil else { return .unknownEndpoint }
        if let source, let actor, !compatible(sources[source], actors[actor]) { return .rejected }
        guard event.updateRate.map({ $0 >= 0 }) ?? true else { return .rejected }
        guard let route = event.associatingRoute else {
            if let source { removeSourceAssociation(source, actorId: event.ioActorId) }
            if let actor {
                removeActorAssociation(actor, sourceId: source.map { sources[$0].id })
            }
            return .disassociated
        }
        guard route.length > 0, route.length <= ProtocolBufferConfig.maxTopicLength else { return .rejected }

        // Validate both sides before changing either fixed-size state slot. The
        // source update can be valid while the actor update conflicts with an
        // existing route; applying the source first would leave a partial
        // association after returning `.rejected`.
        guard canCommitAssociation(source: source, actor: actor, sourceId: event.ioSourceId, actorId: event.ioActorId, route: route) else { return .rejected }
        applyAssociation(source: source, actor: actor, sourceId: event.ioSourceId, actorId: event.ioActorId, route: route, updateRate: event.updateRate)
        return .associated
    }

    /// Synchronously consumes a bare IoValue payload for an associated actor.
    public mutating func consumeIoValue(_ message: BorrowedMessage) -> StaticIoDispatchResult {
        guard message.eventType == .ioValue || message.isRawTopic else { return .ignored }
        for index in actors.indices where actorStates[index].isAssociated {
            let topic = message.topic.withBytes { bytes, length in
                ByteSlice(bytes: bytes.assumingMemoryBound(to: UInt8.self), length: length)
            }
            guard actorStates[index].associatedRoutes.contains(where: { $0.equals(topic) }) else { continue }
            guard let handler = handlers[index], valueIsCompatible(message.payload, mode: actors[index].mode) else { return .rejected }
            handler(message.payload)
            return .delivered
        }
        return .unknownEndpoint
    }

    /// Copies a source value and its assigned route into fixed caller storage.
    ///
    /// Returns nil unless the source is associated, the payload matches its
    /// mode, and both caller buffers are sufficient. This function never
    /// publishes itself; transport ownership remains with the embedded app.
    public func preparePublication(
        sourceId: UUID16,
        payload: ByteSlice,
        topic: UnsafeMutablePointer<UInt8>,
        topicCapacity: Int,
        outputPayload: UnsafeMutablePointer<UInt8>,
        payloadCapacity: Int = 0
    ) -> (topicLength: Int, payloadLength: Int)? {
        preparePublication(
            sourceId: sourceId,
            payload: payload,
            buffers: (
                topic: topic,
                topicCapacity: topicCapacity,
                outputPayload: outputPayload,
                payloadCapacity: payloadCapacity
            )
        )
    }

    private func preparePublication(
        sourceId: UUID16,
        payload: ByteSlice,
        buffers: (
            topic: UnsafeMutablePointer<UInt8>,
            topicCapacity: Int,
            outputPayload: UnsafeMutablePointer<UInt8>,
            payloadCapacity: Int
        )
    ) -> (topicLength: Int, payloadLength: Int)? {
        guard let index = sourceIndex(sourceId), sourceStates[index].associationCount > 0,
              valueIsCompatible(payload, mode: sources[index].mode), payload.length <= buffers.payloadCapacity,
              let topicLength = sourceStates[index].route.copy(to: buffers.topic, capacity: buffers.topicCapacity) else { return nil }
        for offset in 0..<payload.length { buffers.outputPayload[offset] = payload.byte(at: offset)! }
        return (topicLength, payload.length)
    }

    private func sourceIndex(_ id: UUID16) -> Int? { sources.firstIndex { $0.id == id } }
    private func actorIndex(_ id: UUID16) -> Int? { actors.firstIndex { $0.id == id } }
    private func compatible(_ source: StaticIoEndpointDescriptor, _ actor: StaticIoEndpointDescriptor) -> Bool {
        source.mode == actor.mode && ByteSlice(bytes: source.valueType.utf8Start, length: source.valueType.utf8CodeUnitCount).equals(actor.valueType)
    }
    private func valueIsCompatible(_ payload: ByteSlice, mode: StaticIoValueMode) -> Bool {
        switch mode { case .raw: true; case .json: WireReader.isValidJSONValue(payload) }
    }
    private func canAddSourceAssociation(_ index: Int, actorId: UUID16, route: ByteSlice) -> Bool {
        let state = sourceStates[index]
        guard state.associationCount == 0 || state.route.equals(route) else { return false }
        return state.associatedActors.contains(actorId) || state.associatedActors.contains(where: { $0 == nil })
    }
    private func canAddActorAssociation(_ index: Int, sourceId: UUID16, route: ByteSlice) -> Bool {
        let state = actorStates[index]
        if state.associatedSources.contains(sourceId) { return true }
        return state.associatedSources.contains(where: { $0 == nil })
    }
    private func canCommitAssociation(source: Int?, actor: Int?, sourceId: UUID16, actorId: UUID16, route: ByteSlice) -> Bool {
        if let source, !canAddSourceAssociation(source, actorId: actorId, route: route) { return false }
        if let actor, !canAddActorAssociation(actor, sourceId: sourceId, route: route) { return false }
        return true
    }
    private mutating func applyAssociation(source: Int?, actor: Int?, sourceId: UUID16, actorId: UUID16, route: ByteSlice, updateRate: Int?) {
        if let source { _ = addSourceAssociation(source, actorId: actorId, route: route, updateRate: updateRate) }
        if let actor {
            _ = addActorAssociation(actor, sourceId: sourceId, route: route, updateRate: updateRate)
        }
    }
    private mutating func addSourceAssociation(_ index: Int, actorId: UUID16, route: ByteSlice, updateRate: Int?) -> Bool {
        guard canAddSourceAssociation(index, actorId: actorId, route: route) else { return false }
        if sourceStates[index].associationCount == 0 && !sourceStates[index].route.copy(from: route) { return false }
        if !sourceStates[index].associatedActors.contains(actorId) {
            guard let slot = sourceStates[index].associatedActors.firstIndex(where: { $0 == nil }) else { return false }
            sourceStates[index].associatedActors[slot] = actorId
        }
        sourceStates[index].negotiatedUpdateRate = updateRate ?? sources[index].configuredUpdateRate
        return true
    }
    private mutating func removeSourceAssociation(_ index: Int, actorId: UUID16) {
        guard sourceStates[index].associationCount > 0 else { return }
        if let slot = sourceStates[index].associatedActors.firstIndex(where: { $0 == actorId }) {
            sourceStates[index].associatedActors[slot] = nil
        }
        if sourceStates[index].associationCount == 0 {
            sourceStates[index].route.clear()
            sourceStates[index].negotiatedUpdateRate = nil
        }
    }
    private mutating func addActorAssociation(_ index: Int, sourceId: UUID16, route: ByteSlice, updateRate: Int?) -> Bool {
        guard canAddActorAssociation(index, sourceId: sourceId, route: route) else { return false }
        if let existing = actorStates[index].associatedSources.firstIndex(where: { $0 == sourceId }) {
            guard actorStates[index].associatedRoutes[existing].equals(route) else { return false }
            actorStates[index].negotiatedUpdateRate = updateRate ?? actors[index].configuredUpdateRate
            return true
        }
        if let slot = actorStates[index].associatedSources.firstIndex(where: { $0 == nil }) {
            actorStates[index].associatedSources[slot] = sourceId
            guard actorStates[index].associatedRoutes[slot].copy(from: route) else {
                actorStates[index].associatedSources[slot] = nil
                return false
            }
        }
        _ = actorStates[index].route.copy(from: route)
        actorStates[index].isAssociated = true
        actorStates[index].negotiatedUpdateRate = updateRate ?? actors[index].configuredUpdateRate
        return true
    }
    private mutating func removeActorAssociation(_ index: Int, sourceId: UUID16?) {
        if let sourceId,
           let slot = actorStates[index].associatedSources.firstIndex(where: { $0 == sourceId }) {
            actorStates[index].associatedSources[slot] = nil
            actorStates[index].associatedRoutes[slot].clear()
        } else {
            for slot in actorStates[index].associatedSources.indices {
                actorStates[index].associatedSources[slot] = nil
                actorStates[index].associatedRoutes[slot].clear()
            }
        }
        if actorStates[index].associationCount == 0 {
            actorStates[index].isAssociated = false
            actorStates[index].route.clear()
            actorStates[index].negotiatedUpdateRate = nil
        } else {
            // Preserve the first remaining source route for the legacy state view;
            // dispatch still retains every route in the bounded parallel slots.
            if let slot = actorStates[index].associatedRoutes.firstIndex(where: { $0.length > 0 }) {
                _ = actorStates[index].route.copy(
                    from: ByteSlice(bytes: actorStates[index].associatedRoutes[slot].bytes,
                                    length: actorStates[index].associatedRoutes[slot].length)
                )
            }
        }
    }
}
