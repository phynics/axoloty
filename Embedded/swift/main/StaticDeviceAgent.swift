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

struct StaticDeviceAgent {
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

    // A missing Resolve expires after five seconds; the C wait loop polls this
    // synchronous state while the MQTT client remains connected.
    private static let discoverTimeoutMS: UInt32 = 5_000

    init(agentId: UUID16 = Self.agentAId, deviceObjectId: UUID16 = Self.objectAId) {
        self.agentId = agentId
        self.deviceObjectId = deviceObjectId
        let isA = agentId == Self.agentAId
        self.ioEndpoints = StaticIoEndpoints(
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
    }

    /// Starts the one bounded outstanding Discover request.
    ///
    /// Returns `false` when a request is already awaiting a Resolve.
    mutating func beginDiscover(correlationId: UUID16, nowMS: UInt32) -> Bool {
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
    mutating func expireDiscover(nowMS: UInt32) -> Bool {
        guard let deadlineMS = pendingDeadlineMS,
              Int32(bitPattern: nowMS &- deadlineMS) >= 0 else { return false }
        pendingCorrelation = nil
        pendingDeadlineMS = nil
        return true
    }

    mutating func dispatch(_ message: BorrowedMessage, nowMS: UInt32) -> StaticDeviceDispatchResult {
        if expireDiscover(nowMS: nowMS), message.eventType == .resolve { return .wrongCorrelation }
        switch message.eventType {
        case .advertise:
            guard (try? AdvertiseWireData(from: message.reader())) != nil else { return .malformed }
            hasAdvertisedPeer = true
            return .advertise
        case .deadvertise:
            guard (try? DeadvertiseWireData(from: message.reader())) != nil else { return .malformed }
            hasAdvertisedPeer = false
            return .deadvertise
        case .discover:
            guard let discover = try? DiscoverWireData(from: message.reader()) else { return .malformed }
            let matchesObjectId = discover.objectId?.equals(
                "32400000-0000-4000-8000-000000000002"
            ) ?? false
            let matchesObjectType = discover.objectTypes?.equals(
                "[\"coaty.test.Device\"]"
            ) ?? false
            guard matchesObjectId || matchesObjectType else { return .unsupported }
            return .discover
        case .resolve:
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
        case .associate:
            guard let associate = try? AssociateWireData(from: message.reader()) else { return .malformed }
            let localActorId = agentId == Self.agentAId ? Self.actorAId : Self.actorBId
            switch ioEndpoints.consumeAssociate(message) {
            case .associated:
                return associate.ioActorId == localActorId ? .ioActorAssociated : .ioSourceAssociated
            case .disassociated:
                return associate.ioActorId == localActorId ? .ioActorDisassociated : .ioSourceDisassociated
            default: return .malformed
            }
        case .ioValue:
            return ioEndpoints.consumeIoValue(message) == .delivered ? .ioValueDelivered : .malformed
        case .none:
            return .malformed
        default:
            return .unsupported
        }
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
        let objectTypeFilter: StaticString = ":coaty.test.Device"
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

private var phase4AgentA = StaticDeviceAgent(
    agentId: StaticDeviceAgent.agentAId,
    deviceObjectId: StaticDeviceAgent.objectAId
)

private var phase4AgentB = StaticDeviceAgent(
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
