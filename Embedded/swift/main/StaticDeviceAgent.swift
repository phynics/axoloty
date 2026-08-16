// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyWire

enum StaticDeviceDispatchResult: Equatable {
    case advertise
    case deadvertise
    case discover
    case resolve
    case wrongCorrelation
    case duplicateResolve
    case malformed
    case unsupported
    case ioSourceAssociated
    case ioSourceDisassociated
    case ioActorAssociated
    case ioActorDisassociated
    case ioValueDelivered
}

/// The production static device-agent ingress for the embedded firmware.
///
/// This type owns an ``EmbeddedMessageRouter`` and routes every supported
/// non-correlated event family through it (issue #493): Discover and Associate
/// on the flat per-event-type tables, Advertise and Deadvertise on the
/// advertise family, and IoValue on the dedicated IoValue table. Dispatching a
/// ``BorrowedMessage`` therefore flows through the generic router's
/// ``StaticDispatchTable``/``StaticFamilyTable`` seam instead of a hand-rolled
/// per-event switch. The agent keeps the single-outstanding-Discover
/// correlation state machine greedy for Resolve because the generic router's
/// correlation-keyed response family cannot express rejecting a Resolve whose
/// correlation ID does not match (see ``dispatch(_:nowMS:)``).
///
/// The class is `@unchecked Sendable` and intentionally non-`Sendable` in the
/// strict sense of the router: it is a fixed-phase singleton owned by the
/// firmware and mutated only from one synchronous dispatch context. Router
/// handler closures capture it strongly for the lifetime of the firmware, which
/// forms a benign cycle with the owned router and requires no external retain.
final class StaticDeviceAgent: @unchecked Sendable {
    static let agentAId = UUID16(bytes: (
        0x32, 0x40, 0x00, 0x00, 0x00, 0x00, 0x40, 0x00,
        0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01
    ))
    static let objectAId = UUID16(bytes: (
        0x32, 0x40, 0x00, 0x00, 0x00, 0x00, 0x40, 0x00,
        0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02
    ))
    static let agentBId = UUID16(bytes: (
        0x32, 0x40, 0x00, 0x00, 0x00, 0x00, 0x40, 0x00,
        0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x0b
    ))
    static let objectBId = UUID16(bytes: (
        0x32, 0x40, 0x00, 0x00, 0x00, 0x00, 0x40, 0x00,
        0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x0c
    ))
    static let agentId = agentAId
    static let deviceObjectId = objectAId
    static let namespace: StaticString = "axoloty-embedded"

    // The firmware has a deliberately small, static endpoint profile. These
    // UUIDs are endpoint identities, not agent identities, and stay stable so
    // a host IoRouter can associate them without on-device discovery.
    static let sourceAId = UUID16(bytes: (
        0x32, 0x40, 0x00, 0x00, 0x00, 0x00, 0x40, 0x00,
        0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x21
    ))
    static let actorAId = UUID16(bytes: (
        0x32, 0x40, 0x00, 0x00, 0x00, 0x00, 0x40, 0x00,
        0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x22
    ))
    static let sourceBId = UUID16(bytes: (
        0x32, 0x40, 0x00, 0x00, 0x00, 0x00, 0x40, 0x00,
        0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x31
    ))
    static let actorBId = UUID16(bytes: (
        0x32, 0x40, 0x00, 0x00, 0x00, 0x00, 0x40, 0x00,
        0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x32
    ))

    let agentId: UUID16
    let deviceObjectId: UUID16
    private(set) var hasAdvertisedPeer = false
    private var pendingCorrelation: UUID16?
    private var pendingDeadlineMS: UInt32?
    private var resolvedCorrelation: UUID16?
    private var ioEndpoints: StaticIoEndpoints
    private let router: EmbeddedMessageRouter
    private var routedOutcome: StaticDeviceDispatchResult = .unsupported

    /// The object-type filter the device advertises with and discovers under.
    /// Matches the `ADV:<filter>` topic bytes after the `:` separator and the
    /// lookup filter used by ``dispatch(_:nowMS:)``.
    static let deviceFilter: StaticString = "coaty.test.Device"

    // A missing Resolve expires after five seconds; the C wait loop polls this
    // synchronous state while the MQTT client remains connected.
    private static let discoverTimeoutMS: UInt32 = 5_000

    init(agentId: UUID16 = StaticDeviceAgent.agentAId, deviceObjectId: UUID16 = StaticDeviceAgent.objectAId) {
        self.agentId = agentId
        self.deviceObjectId = deviceObjectId
        let isA = agentId == Self.agentAId
        // Endpoint counts are bounded startup constants; construction is
        // expected to succeed for the fixed firmware profile.
        self.ioEndpoints = try! StaticIoEndpoints(
            sources: [StaticIoEndpointDescriptor(
                id: isA ? Self.sourceAId : Self.sourceBId,
                valueType: "com.axoloty.embedded.StaticIoValue",
                mode: .json
            )],
            actors: [StaticIoEndpointDescriptor(
                id: isA ? Self.actorAId : Self.actorBId,
                valueType: "com.axoloty.embedded.StaticIoValue",
                mode: .json
            )],
            // Application firmware replaces this fixed synchronous callback
            // with its sensor/actuator action. It must not retain the borrow.
            actorHandlers: [{ _ in }]
        )
        self.router = try! EmbeddedMessageRouter()
        installIngressHandlers()
    }

    /// Registers the supported ingress event families on the owned generic
    /// router (issue #493) so dispatch flows through ``EmbeddedMessageRouter``.
    ///
    /// - Discover and Associate use the flat per-event-type tables.
    /// - Advertise and Deadvertise use the advertise family keyed by
    ///   ``deviceFilter``. A filterless publish and every Deadvertise fan out
    ///   through ``StaticFamilyTable``'s `dispatchAll`; a matching-filter
    ///   advertise routes through the byte-slice filter lookup.
    /// - IoValue uses the dedicated IoValue table.
    ///
    /// Each handler stores the outcome it selected into ``routedOutcome`` so
    /// ``dispatch(_:nowMS:)`` can report it back to the C ingress bridge while
    /// still pushing the routing decision through the generic seam.
    private func installIngressHandlers() {
        router.subscribe(.discover) { [self] message in
            guard let discover = try? DiscoverWireData(from: message.reader()) else {
                self.routedOutcome = .malformed
                return
            }
            let matchesObjectId = discover.objectId?.equals(
                "32400000-0000-4000-8000-000000000002"
            ) ?? false
            let matchesObjectType = discover.objectTypes?.equals(
                "[\"coaty.test.Device\"]"
            ) ?? false
            guard matchesObjectId || matchesObjectType else {
                self.routedOutcome = .unsupported
                return
            }
            self.routedOutcome = .discover
        }

        router.subscribe(.associate) { [self] message in
            guard let associate = try? AssociateWireData(from: message.reader()) else {
                self.routedOutcome = .malformed
                return
            }
            let localActorId = self.agentId == Self.agentAId ? Self.actorAId : Self.actorBId
            switch self.ioEndpoints.consumeAssociate(message) {
            case .associated:
                self.routedOutcome = associate.ioActorId == localActorId
                    ? .ioActorAssociated : .ioSourceAssociated
            case .disassociated:
                self.routedOutcome = associate.ioActorId == localActorId
                    ? .ioActorDisassociated : .ioSourceDisassociated
            default:
                self.routedOutcome = .malformed
            }
        }

        // The advertise family key is an owned ``String`` (required by
        // ``StaticFamilyTable``); it is allocated once at startup, not per
        // steady-state dispatch.
        router.subscribeAdvertise(filter: "coaty.test.Device") { [self] message in
            switch message.eventType {
            case .advertise:
                guard (try? AdvertiseWireData(from: message.reader())) != nil else {
                    self.routedOutcome = .malformed
                    return
                }
                self.hasAdvertisedPeer = true
                self.routedOutcome = .advertise
            case .deadvertise:
                guard (try? DeadvertiseWireData(from: message.reader())) != nil else {
                    self.routedOutcome = .malformed
                    return
                }
                self.hasAdvertisedPeer = false
                self.routedOutcome = .deadvertise
            default:
                self.routedOutcome = .unsupported
            }
        }

        router.subscribeIoValue { [self] message in
            self.routedOutcome = self.ioEndpoints.consumeIoValue(message) == .delivered
                ? .ioValueDelivered : .malformed
        }
    }

    /// Starts the one bounded outstanding Discover request.
    ///
    /// Returns `false` when a request is already awaiting a Resolve.
    func beginDiscover(correlationId: UUID16, nowMS: UInt32) -> Bool {
        guard pendingCorrelation == nil else { return false }
        pendingCorrelation = correlationId
        pendingDeadlineMS = nowMS &+ Self.discoverTimeoutMS
        resolvedCorrelation = nil
        return true
    }

    /// Expires the outstanding Discover once its deadline has passed.
    ///
    /// Time is supplied by the caller so this static router remains
    /// deterministic and does not need an asynchronous task.
    func expireDiscover(nowMS: UInt32) -> Bool {
        guard let deadlineMS = pendingDeadlineMS,
              Int32(bitPattern: nowMS &- deadlineMS) >= 0 else { return false }
        pendingCorrelation = nil
        pendingDeadlineMS = nil
        return true
    }

    func dispatch(_ message: BorrowedMessage, nowMS: UInt32) -> StaticDeviceDispatchResult {
        if expireDiscover(nowMS: nowMS), message.eventType == .resolve { return .wrongCorrelation }

        // Resolve is handled greedily and directly rather than through the
        // generic router. The router's response family routes only to a
        // subscriber registered for the exact correlation ID, so it cannot
        // deliver a wrong- or duplicate-correlation Resolve for rejection. The
        // device agent must observe every Resolve to enforce its bounded
        // single-outstanding-Discover invariant, so only this correlation
        // state machine handles it.
        if message.eventType == .resolve {
            guard (try? ResolveWireData(from: message.reader())) != nil else { return .malformed }
            guard let correlationId = message.topic.correlationIdLevel.flatMap(UUID16.init(parsing:)) else {
                return .wrongCorrelation
            }
            if correlationId == resolvedCorrelation { return .duplicateResolve }
            guard pendingCorrelation == correlationId else { return .wrongCorrelation }
            pendingCorrelation = nil
            pendingDeadlineMS = nil
            resolvedCorrelation = correlationId
            return .resolve
        }

        guard message.eventType != nil else { return .malformed }
        routedOutcome = .unsupported
        router.dispatch(message)
        return routedOutcome
    }

    func encode<T: WireEncodable>(
        _ value: T,
        eventType: WireEventType,
        correlationId: UUID16?,
        topicBuffer: UnsafeMutablePointer<UInt8>,
        topicCapacity: Int,
        payloadBuffer: UnsafeMutablePointer<UInt8>,
        payloadCapacity: Int
    ) throws(WireEncodeError) -> (topicLength: Int, payloadLength: Int) {
        var topic = TopicBuilder(buffer: topicBuffer, capacity: topicCapacity)
        try topic.writePrefix()
        try topic.writeNamespace(Self.namespace)
        let objectTypeFilter: StaticString = "coaty.test.Device"
        let filter = eventType == .advertise
            ? ByteSlice(bytes: objectTypeFilter.utf8Start, length: objectTypeFilter.utf8CodeUnitCount)
            : nil
        try topic.writeEventType(eventType, filter: filter)
        try topic.writeSourceId(agentId)
        if let correlationId { try topic.writeCorrelationId(correlationId) }

        var payload = WireWriter(buffer: payloadBuffer, capacity: payloadCapacity)
        try value.encode(to: &payload)
        return (topic.position, payload.position)
    }

    /// Copies the currently associated local actor route into fixed caller
    /// storage for ESP-MQTT subscribe/reconnect operations.
    func copyActorRoute(
        to output: UnsafeMutablePointer<UInt8>, capacity: Int
    ) -> Int? {
        let actorId = agentId == Self.agentAId ? Self.actorAId : Self.actorBId
        return ioEndpoints.copyActorRoute(actorId: actorId, to: output, capacity: capacity)
    }
}

private let phase4Correlation = UUID16(bytes: (
    0x32, 0x40, 0x00, 0x00, 0x00, 0x00, 0x40, 0x00,
    0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04
))

private let phase4AgentA = StaticDeviceAgent(
    agentId: StaticDeviceAgent.agentAId,
    deviceObjectId: StaticDeviceAgent.objectAId
)

private let phase4AgentB = StaticDeviceAgent(
    agentId: StaticDeviceAgent.agentBId,
    deviceObjectId: StaticDeviceAgent.objectBId
)

@inline(__always)
private func phase4NowMS() -> UInt32 {
    UInt32(truncatingIfNeeded: esp_timer_get_time() / 1_000)
}

@_cdecl("axoloty_static_agent_expire")
func axolotyStaticAgentExpire(_ role: Int32) -> Int32 {
    role == 2 && phase4AgentB.expireDiscover(nowMS: phase4NowMS()) ? 1 : 0
}

/// Copies the active actor route for the selected static endpoint profile.
/// The C MQTT adapter invokes this only to subscribe or re-subscribe; route
/// bytes never escape into asynchronous Swift state.
@_cdecl("axoloty_static_agent_copy_actor_route")
func axolotyStaticAgentCopyActorRoute(
    _ role: Int32, _ output: UnsafeMutablePointer<UInt8>, _ capacity: Int32
) -> Int32 {
    guard capacity > 0 else { return -1 }
    let length = role == 1
        ? phase4AgentA.copyActorRoute(to: output, capacity: Int(capacity))
        : phase4AgentB.copyActorRoute(to: output, capacity: Int(capacity))
    return Int32(length ?? -1)
}

@inline(__always)
private func preparePhase4Message(
    role: Int32,
    kind: Int32,
    responseCorrelationId: UUID16? = nil,
    topicBuffer: UnsafeMutablePointer<UInt8>,
    topicCapacity: Int32,
    payloadBuffer: UnsafeMutablePointer<UInt8>,
    payloadCapacity: Int32,
    topicLength: UnsafeMutablePointer<Int32>,
    payloadLength: UnsafeMutablePointer<Int32>
) -> Bool {
    let source: StaticString
    let eventType: WireEventType
    let correlationId: UUID16?
    switch (role, kind) {
    case (1, 1):
        source = "{\"object\":{\"coreType\":\"CoatyObject\",\"objectId\":\"32400000-0000-4000-8000-000000000002\",\"objectType\":\"coaty.test.Device\",\"name\":\"ESP32-C6 A\"}}"
        eventType = .advertise; correlationId = nil
    case (2, 2):
        source = "{\"objectTypes\":[\"coaty.test.Device\"]}"
        eventType = .discover; correlationId = phase4Correlation
    case (1, 3):
        source = "{\"object\":{\"coreType\":\"CoatyObject\",\"objectId\":\"32400000-0000-4000-8000-000000000002\",\"objectType\":\"coaty.test.Device\",\"name\":\"ESP32-C6 A\"}}"
        eventType = .resolve; correlationId = responseCorrelationId ?? phase4Correlation
    case (1, 4):
        source = "{\"objectIds\":[\"32400000-0000-4000-8000-000000000002\"]}"
        eventType = .deadvertise; correlationId = nil
    default:
        return false
    }

    let agent = role == 1 ? phase4AgentA : phase4AgentB
    let result: (topicLength: Int, payloadLength: Int)?
    let reader = WireReader(bytes: source.utf8Start, length: source.utf8CodeUnitCount)
    switch eventType {
    case .advertise:
        result = (try? AdvertiseWireData(from: reader)).flatMap {
            try? agent.encode($0, eventType: eventType, correlationId: correlationId,
                              topicBuffer: topicBuffer, topicCapacity: Int(topicCapacity),
                              payloadBuffer: payloadBuffer, payloadCapacity: Int(payloadCapacity))
        }
    case .deadvertise:
        result = (try? DeadvertiseWireData(from: reader)).flatMap {
            try? agent.encode($0, eventType: eventType, correlationId: correlationId,
                              topicBuffer: topicBuffer, topicCapacity: Int(topicCapacity),
                              payloadBuffer: payloadBuffer, payloadCapacity: Int(payloadCapacity))
        }
    case .discover:
        result = (try? DiscoverWireData(from: reader)).flatMap {
            try? agent.encode($0, eventType: eventType, correlationId: correlationId,
                              topicBuffer: topicBuffer, topicCapacity: Int(topicCapacity),
                              payloadBuffer: payloadBuffer, payloadCapacity: Int(payloadCapacity))
        }
    case .resolve:
        result = (try? ResolveWireData(from: reader)).flatMap {
            try? agent.encode($0, eventType: eventType, correlationId: correlationId,
                              topicBuffer: topicBuffer, topicCapacity: Int(topicCapacity),
                              payloadBuffer: payloadBuffer, payloadCapacity: Int(payloadCapacity))
        }
    default:
        result = nil
    }
    guard let result else { return false }
    topicLength.pointee = Int32(result.topicLength)
    payloadLength.pointee = Int32(result.payloadLength)
    return true
}

@_cdecl("axoloty_static_agent_prepare")
func axolotyStaticAgentPrepare(
    _ role: Int32,
    _ kind: Int32,
    _ topicBuffer: UnsafeMutablePointer<UInt8>,
    _ topicCapacity: Int32,
    _ payloadBuffer: UnsafeMutablePointer<UInt8>,
    _ payloadCapacity: Int32,
    _ topicLength: UnsafeMutablePointer<Int32>,
    _ payloadLength: UnsafeMutablePointer<Int32>
) -> Int32 {
    preparePhase4Message(
        role: role, kind: kind,
        topicBuffer: topicBuffer, topicCapacity: topicCapacity,
        payloadBuffer: payloadBuffer, payloadCapacity: payloadCapacity,
        topicLength: topicLength, payloadLength: payloadLength
    ) ? 1 : 0
}

@_cdecl("axoloty_static_agent_receive")
func axolotyStaticAgentReceive(
    _ role: Int32,
    _ topicBytes: UnsafePointer<UInt8>,
    _ topicLength: Int32,
    _ payloadBytes: UnsafePointer<UInt8>,
    _ payloadLength: Int32,
    _ outputTopic: UnsafeMutablePointer<UInt8>,
    _ outputTopicCapacity: Int32,
    _ outputPayload: UnsafeMutablePointer<UInt8>,
    _ outputPayloadCapacity: Int32,
    _ outputTopicLength: UnsafeMutablePointer<Int32>,
    _ outputPayloadLength: UnsafeMutablePointer<Int32>
) -> Int32 {
    guard let message = try? BorrowedMessage.validated(
        topicBytes: topicBytes, topicLength: Int(topicLength),
        payloadBytes: payloadBytes, payloadLength: Int(payloadLength)
    ) else { return -1 }

    let nowMS = phase4NowMS()
    if role == 1 && message.eventType == .discover {
        guard phase4AgentA.dispatch(message, nowMS: nowMS) == .discover else { return -1 }
        guard let correlationId = message.topic.correlationIdLevel.flatMap(UUID16.init(parsing:)) else { return -1 }
        return preparePhase4Message(
            role: role, kind: 3, responseCorrelationId: correlationId,
            topicBuffer: outputTopic, topicCapacity: outputTopicCapacity,
            payloadBuffer: outputPayload, payloadCapacity: outputPayloadCapacity,
            topicLength: outputTopicLength, payloadLength: outputPayloadLength
        ) ? 1 : -1
    }
    if role == 2 && message.eventType == .advertise {
        guard phase4AgentB.dispatch(message, nowMS: nowMS) == .advertise else { return -1 }
        let prepared = preparePhase4Message(
            role: role, kind: 2,
            topicBuffer: outputTopic, topicCapacity: outputTopicCapacity,
            payloadBuffer: outputPayload, payloadCapacity: outputPayloadCapacity,
            topicLength: outputTopicLength, payloadLength: outputPayloadLength
        )
        return prepared && phase4AgentB.beginDiscover(correlationId: phase4Correlation, nowMS: nowMS) ? 1 : -1
    }
    if role == 2 && message.eventType == .resolve {
        return phase4AgentB.dispatch(message, nowMS: nowMS) == .resolve ? 2 : -1
    }
    if role == 2 && message.eventType == .deadvertise {
        return phase4AgentB.dispatch(message, nowMS: nowMS) == .deadvertise ? 3 : -1
    }
    if message.eventType == .associate {
        let result = role == 1
            ? phase4AgentA.dispatch(message, nowMS: nowMS)
            : phase4AgentB.dispatch(message, nowMS: nowMS)
        switch result {
        case .ioActorAssociated: return 4
        case .ioActorDisassociated: return 5
        case .ioSourceAssociated, .ioSourceDisassociated: return 0
        default: return -1
        }
    }
    if message.eventType == .ioValue {
        let result = role == 1
            ? phase4AgentA.dispatch(message, nowMS: nowMS)
            : phase4AgentB.dispatch(message, nowMS: nowMS)
        return result == .ioValueDelivered ? 6 : -1
    }
    return 0
}